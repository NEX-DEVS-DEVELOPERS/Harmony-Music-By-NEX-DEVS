import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import '../utils/helper.dart';

/// Tiny localhost HTTP proxy that lets the audio player (mpv / ExoPlayer) play
/// YouTube audio URLs reliably.
///
/// YouTube's audio servers often reject (403) or throttle a single request for
/// the whole file, which is what players send. `youtube_explode_dart` itself
/// downloads these streams in ~10 MB ranges with a browser user agent, so this
/// proxy does exactly that: the player talks plain, seekable HTTP to
/// 127.0.0.1 and we fetch the real bytes from YouTube chunk by chunk.
class StreamProxy {
  StreamProxy._();
  static final StreamProxy instance = StreamProxy._();

  /// Browser user agent (the same one youtube_explode_dart uses for downloads).
  static const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/96.0.4664.18 Safari/537.36';

  /// Size of each upstream range request.
  static const chunkSize = 10 * 1024 * 1024;

  /// Extra info about specific upstream URLs (set by the stream resolvers).
  final Map<String, Map<String, String>> _headersFor = {};
  final Map<String, int> _sizeFor = {};

  void rememberHeaders(String url, Map<String, String> headers) =>
      _headersFor[url] = headers;
  void rememberSize(String url, int size) {
    if (size > 0) _sizeFor[url] = size;
  }

  HttpServer? _server;
  Future<HttpServer>? _starting;
  final HttpClient _client = HttpClient()
    ..userAgent = userAgent
    ..connectionTimeout = const Duration(seconds: 15)
    ..autoUncompress = false;

  /// Only YouTube media servers get proxied; everything else (local files,
  /// other hosts) is returned untouched.
  static bool shouldProxy(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.endsWith('googlevideo.com');
  }

  /// Returns a localhost URL that plays [upstreamUrl] through the proxy.
  Future<String> proxify(String upstreamUrl) async {
    if (!shouldProxy(upstreamUrl)) return upstreamUrl;
    return urlFor(upstreamUrl);
  }

  /// Same as [proxify] but without the host check (used by tests).
  Future<String> urlFor(String upstreamUrl) async {
    final server = await _ensureStarted();
    final u = base64Url.encode(utf8.encode(upstreamUrl));
    return 'http://127.0.0.1:${server.port}/s?u=$u';
  }

  Future<HttpServer> _ensureStarted() {
    if (_server != null) return Future.value(_server!);
    return _starting ??= HttpServer.bind(InternetAddress.loopbackIPv4, 0)
        .then((s) {
      _server = s;
      s.listen(_handle, onError: (e) => printERROR('StreamProxy: $e'));
      return s;
    });
  }

  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
    _starting = null;
  }

  // ---------------------------------------------------------------------------

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final encoded = req.uri.queryParameters['u'];
      if (encoded == null) {
        res.statusCode = HttpStatus.badRequest;
        await res.close();
        return;
      }
      final upstream = Uri.parse(utf8.decode(base64Url.decode(encoded)));
      final total = int.tryParse(upstream.queryParameters['clen'] ?? '') ??
          _sizeFor[upstream.toString()] ??
          await _probeLength(upstream);
      if (total == null || total <= 0) {
        res.statusCode = HttpStatus.badGateway;
        res.write('Could not determine stream length');
        await res.close();
        return;
      }

      // --- parse the player's Range header -------------------------------
      var start = 0;
      var end = total - 1;
      var partial = false;
      final range = req.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        final m = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
        if (m != null) {
          final a = m.group(1)!, b = m.group(2)!;
          if (a.isNotEmpty) {
            start = int.parse(a);
            if (b.isNotEmpty) end = int.parse(b).clamp(start, total - 1);
          } else if (b.isNotEmpty) {
            // suffix range: last N bytes
            start = (total - int.parse(b)).clamp(0, total - 1);
          }
          partial = true;
        }
      }
      if (start >= total) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        await res.close();
        return;
      }

      res.statusCode = partial ? HttpStatus.partialContent : HttpStatus.ok;
      res.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(HttpHeaders.contentTypeHeader,
            upstream.queryParameters['mime'] ?? 'audio/mp4')
        ..set(HttpHeaders.contentLengthHeader, end - start + 1);
      if (partial) {
        res.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
      }
      if (req.method == 'HEAD') {
        await res.close();
        return;
      }

      // --- stream the bytes chunk by chunk --------------------------------
      var pos = start;
      var clientGone = false;
      res.done.catchError((_) => clientGone = true).then((_) {
        clientGone = true;
      });
      while (pos <= end && !clientGone) {
        final to = (pos + chunkSize - 1).clamp(pos, end);
        final bytes = await _fetchChunk(upstream, pos, to);
        if (clientGone) break;
        res.add(bytes);
        pos += bytes.length;
        if (bytes.isEmpty) break;
      }
      await res.close();
    } catch (e) {
      printERROR('StreamProxy error: $e');
      try {
        await res.close();
      } catch (_) {}
    }
  }

  /// Fetches bytes [from]..[to] (inclusive) with retries.
  Future<List<int>> _fetchChunk(Uri upstream, int from, int to) async {
    Object? lastError;
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        // For c=ANDROID URLs YouTube wants a Range header; for the others the
        // `range` query parameter (same rule as youtube_explode_dart).
        final isAndroid = upstream.queryParameters['c'] == 'ANDROID';
        final uri = isAndroid
            ? upstream
            : upstream.replace(queryParameters: {
                ...upstream.queryParameters,
                'range': '$from-$to',
              });
        final request = await _client.getUrl(uri);
        _headersFor[upstream.toString()]
            ?.forEach((k, v) => request.headers.set(k, v));
        if (isAndroid) {
          request.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-$to');
        }
        final response = await request.close();
        if (response.statusCode >= 400) {
          await response.drain();
          throw HttpException('upstream HTTP ${response.statusCode}');
        }
        final builder = BytesBuilder(copy: false);
        await for (final data in response) {
          builder.add(data);
        }
        final bytes = builder.takeBytes();
        // Servers that ignore the range and send the whole file: slice it.
        if (response.statusCode == 200 && from > 0) {
          return bytes.sublist(from, (to + 1).clamp(0, bytes.length));
        }
        return bytes;
      } catch (e) {
        lastError = e;
        await Future.delayed(Duration(milliseconds: 300 * (attempt + 1)));
      }
    }
    throw lastError ?? const HttpException('chunk fetch failed');
  }

  Future<int?> _probeLength(Uri upstream) async {
    try {
      final request = await _client.getUrl(upstream);
      _headersFor[upstream.toString()]
          ?.forEach((k, v) => request.headers.set(k, v));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final response = await request.close();
      await response.drain();
      final cr = response.headers.value(HttpHeaders.contentRangeHeader);
      final m = RegExp(r'/(\d+)$').firstMatch(cr ?? '');
      return m == null ? null : int.parse(m.group(1)!);
    } catch (_) {
      return null;
    }
  }

  /// Checks that [url] really delivers audio bytes. Returns `null` when OK,
  /// otherwise a short human-readable reason (used for diagnostics).
  Future<String?> validate(String url) async {
    try {
      if (shouldProxy(url)) {
        final bytes = await _fetchChunk(Uri.parse(url), 0, 2047);
        return bytes.isEmpty ? 'empty response' : null;
      }
      final request = await _client.getUrl(Uri.parse(url));
      _headersFor[url]?.forEach((k, v) => request.headers.set(k, v));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-2047');
      final response =
          await request.close().timeout(const Duration(seconds: 10));
      final code = response.statusCode;
      var got = 0;
      await for (final d in response) {
        got += d.length;
        if (got > 0) break;
      }
      if (code >= 400) return 'HTTP $code';
      return got == 0 ? 'empty response' : null;
    } catch (e) {
      return e.toString().replaceAll('\n', ' ');
    }
  }

  /// Downloads the whole stream to [path] (in [chunk]-sized range requests) and
  /// returns the file. Throws with the real reason (e.g. "upstream HTTP 403")
  /// if it fails, so the UI can show it.
  Future<File> downloadToFile(String url, String path,
      {int chunk = 1024 * 1024,
      void Function(int received, int total)? onProgress}) async {
    final upstream = Uri.parse(url);
    final total = int.tryParse(upstream.queryParameters['clen'] ?? '') ??
        _sizeFor[url] ??
        await _probeLength(upstream);
    if (total == null || total <= 0) {
      throw const HttpException('could not determine the audio size');
    }
    final file = File(path);
    await file.parent.create(recursive: true);
    final tmp = File('$path.part');
    final sink = tmp.openWrite();
    try {
      var pos = 0;
      while (pos < total) {
        final to = (pos + chunk - 1).clamp(pos, total - 1);
        final bytes = await _fetchChunk(upstream, pos, to);
        if (bytes.isEmpty) {
          throw const HttpException('server returned no data');
        }
        sink.add(bytes);
        pos += bytes.length;
        onProgress?.call(pos, total);
      }
      await sink.close();
      if (await file.exists()) await file.delete();
      return await tmp.rename(path).then((f) => File(f.path));
    } catch (e) {
      try {
        await sink.close();
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
  }
}
