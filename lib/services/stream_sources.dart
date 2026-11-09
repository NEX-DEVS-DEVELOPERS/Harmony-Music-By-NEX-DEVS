import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/helper.dart';
import 'stream_proxy.dart';
import 'stream_service.dart';

/// One playable audio stream found by a source, before it is turned into an
/// [Audio] used by the player.
class AudioCandidate {
  AudioCandidate({
    required this.url,
    required this.isOpus,
    required this.bitrate,
    this.size = 0,
    this.headers,
  });
  final String url;
  final bool isOpus;
  final int bitrate;
  final int size;
  final Map<String, String>? headers;
}

/// Converts candidates into the [Audio] list the player expects: per codec
/// the best stream gets itag 251 (opus) / 140 (aac) and the lowest bitrate one
/// 249 / 139, ordered low -> high like youtube_explode_dart does.
List<Audio> candidatesToAudios(List<AudioCandidate> candidates) {
  final result = <Audio>[];
  for (final opus in [true, false]) {
    final group = candidates.where((c) => c.isOpus == opus).toList()
      ..sort((a, b) => a.bitrate.compareTo(b.bitrate));
    if (group.isEmpty) continue;
    Audio toAudio(AudioCandidate c, int itag) {
      final proxy = StreamProxy.instance;
      if (c.headers != null) proxy.rememberHeaders(c.url, c.headers!);
      proxy.rememberSize(c.url, c.size);
      return Audio(
        itag: itag,
        audioCodec: opus ? Codec.opus : Codec.mp4a,
        bitrate: c.bitrate,
        duration: 0,
        loudnessDb: -5.0,
        url: c.url,
        size: c.size,
        headers: c.headers,
      );
    }

    if (group.length > 1) {
      result.add(toAudio(group.first, opus ? 249 : 139));
    }
    result.add(toAudio(group.last, opus ? 251 : 140));
  }
  return result;
}

int _toInt(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

/// Parses a Piped `/streams/<id>` response.
List<AudioCandidate> parsePipedStreams(Map json) {
  final list = (json['audioStreams'] as List?) ?? const [];
  final out = <AudioCandidate>[];
  for (final s in list) {
    if (s is! Map || s['url'] == null) continue;
    final trackType = s['audioTrackType'];
    if (trackType != null && trackType != 'ORIGINAL') continue; // dubbed audio
    final mime = '${s['mimeType'] ?? ''} ${s['codec'] ?? ''} ${s['format'] ?? ''}'
        .toLowerCase();
    out.add(AudioCandidate(
      url: s['url'].toString(),
      isOpus: mime.contains('opus') || mime.contains('webm'),
      bitrate: _toInt(s['bitrate']),
      size: _toInt(s['contentLength']),
    ));
  }
  return out;
}

/// Parses an Invidious `/api/v1/videos/<id>?local=true` response.
List<AudioCandidate> parseInvidiousFormats(Map json, String baseUrl) {
  final list = (json['adaptiveFormats'] as List?) ?? const [];
  final out = <AudioCandidate>[];
  for (final f in list) {
    if (f is! Map || f['url'] == null) continue;
    final type = '${f['type'] ?? ''}'.toLowerCase();
    if (!type.startsWith('audio/')) continue;
    var url = f['url'].toString();
    if (url.startsWith('/')) url = '$baseUrl$url';
    out.add(AudioCandidate(
      url: url,
      isOpus: type.contains('opus') || type.contains('webm'),
      bitrate: _toInt(f['bitrate']),
      size: _toInt(f['clen']),
    ));
  }
  return out;
}

/// Parses `yt-dlp -j` output (audio-only formats).
List<AudioCandidate> parseYtDlpJson(Map json) {
  final formats = (json['formats'] as List?) ?? const [];
  final out = <AudioCandidate>[];
  for (final f in formats) {
    if (f is! Map || f['url'] == null) continue;
    if (f['vcodec'] != null && f['vcodec'] != 'none') continue; // has video
    final acodec = '${f['acodec'] ?? ''}'.toLowerCase();
    if (acodec == 'none' || acodec.isEmpty) continue;
    final protocol = '${f['protocol'] ?? 'https'}';
    if (!protocol.startsWith('http') || protocol.contains('m3u8')) continue;
    final headers = (f['http_headers'] as Map?)
        ?.map((k, v) => MapEntry(k.toString(), v.toString()));
    out.add(AudioCandidate(
      url: f['url'].toString(),
      isOpus: acodec.contains('opus'),
      bitrate: ((f['abr'] is num ? f['abr'] as num : 0) * 1000).toInt(),
      size: _toInt(f['filesize'] ?? f['filesize_approx']),
      headers: headers,
    ));
  }
  return out;
}

/// Completes with the first non-null result, or null once all are done.
Future<T?> firstSuccess<T>(Iterable<Future<T?>> futures) {
  final completer = Completer<T?>();
  var pending = futures.length;
  if (pending == 0) return Future.value(null);
  for (final f in futures) {
    f.then((v) {
      if (v != null && !completer.isCompleted) completer.complete(v);
    }).catchError((_) {}).whenComplete(() {
      pending--;
      if (pending == 0 && !completer.isCompleted) completer.complete(null);
    });
  }
  return completer.future;
}

/// Public Piped / Invidious servers: they fetch the audio from YouTube
/// themselves and serve it to us, so they work even when YouTube blocks direct
/// requests from this machine.
class FrontendSources {
  static final _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 8),
      headers: {'User-Agent': StreamProxy.userAgent}));

  static const _pipedFallback = [
    'https://pipedapi.kavin.rocks',
    'https://pipedapi.adminforge.de',
    'https://api.piped.private.coffee',
    'https://pipedapi.leptons.xyz',
  ];
  static const _invidiousFallback = [
    'https://inv.nadeko.net',
    'https://yewtu.be',
    'https://invidious.nerdvpn.de',
    'https://invidious.privacyredirect.com',
  ];

  static Future<List<String>> _pipedInstances() async {
    try {
      final r = await _dio.get('https://piped-instances.kavin.rocks/');
      final data = r.data is String ? jsonDecode(r.data) : r.data;
      final urls = (data as List)
          .map((e) => e['api_url']?.toString())
          .whereType<String>()
          .toList()
        ..shuffle();
      if (urls.isNotEmpty) return [...urls.take(4), ..._pipedFallback];
    } catch (_) {}
    return _pipedFallback;
  }

  static Future<List<String>> _invidiousInstances() async {
    try {
      final r = await _dio
          .get('https://api.invidious.io/instances.json?sort_by=type,health');
      final data = r.data is String ? jsonDecode(r.data) : r.data;
      final urls = <String>[];
      for (final e in (data as List)) {
        final info = e[1];
        if (info is Map && info['api'] == true && info['type'] == 'https') {
          urls.add(info['uri'].toString());
        }
      }
      if (urls.isNotEmpty) return [...urls.take(4), ..._invidiousFallback];
    } catch (_) {}
    return _invidiousFallback;
  }

  static Future<List<Audio>?> _tryInstance(
      String name,
      Future<List<AudioCandidate>> Function() load,
      List<String> errors) async {
    try {
      final candidates = await load();
      if (candidates.isEmpty) {
        errors.add('$name: no audio');
        return null;
      }
      final audios = candidatesToAudios(candidates);
      final best = audios.last;
      final problem = await StreamProxy.instance.validate(best.url);
      if (problem != null) {
        errors.add('$name: $problem');
        return null;
      }
      return audios;
    } catch (e) {
      errors.add('$name: ${e is DioException ? (e.message ?? e.type.name) : e}');
      return null;
    }
  }

  static Future<List<Audio>?> piped(String videoId, List<String> errors) async {
    final instances = await _pipedInstances();
    return firstSuccess(instances.take(6).map((base) => _tryInstance(
        'Piped ${Uri.parse(base).host}', () async {
      final r = await _dio.get('$base/streams/$videoId');
      final data = r.data is String ? jsonDecode(r.data) : r.data;
      return parsePipedStreams(data as Map);
    }, errors)));
  }

  static Future<List<Audio>?> invidious(
      String videoId, List<String> errors) async {
    final instances = await _invidiousInstances();
    return firstSuccess(instances.take(6).map((base) => _tryInstance(
        'Invidious ${Uri.parse(base).host}', () async {
      final r = await _dio.get('$base/api/v1/videos/$videoId',
          queryParameters: {'local': 'true'});
      final data = r.data is String ? jsonDecode(r.data) : r.data;
      return parseInvidiousFormats(data as Map, base);
    }, errors)));
  }
}

/// Desktop-only last resort: the `yt-dlp` program, which is updated very
/// often and copes with YouTube changes. Downloaded once from the official
/// yt-dlp GitHub releases into the app's data folder if not already present.
class YtDlpSource {
  static Future<String?> _binary(List<String> errors) async {
    if (!(Platform.isWindows || Platform.isLinux)) return null;
    // already on PATH?
    try {
      final r = await Process.run('yt-dlp', ['--version']);
      if (r.exitCode == 0) return 'yt-dlp';
    } catch (_) {}

    final dir = Directory('${(await getApplicationSupportDirectory()).path}/bin');
    await dir.create(recursive: true);
    final file = File('${dir.path}/${Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp'}');
    if (await file.exists() && await file.length() > 1000000) return file.path;

    try {
      printINFO('Downloading yt-dlp (one time)...');
      final asset = Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp_linux';
      final tmp = '${file.path}.part';
      await Dio().download(
          'https://github.com/yt-dlp/yt-dlp/releases/latest/download/$asset',
          tmp,
          options: Options(receiveTimeout: const Duration(minutes: 3)));
      await File(tmp).rename(file.path);
      if (Platform.isLinux) await Process.run('chmod', ['+x', file.path]);
      return file.path;
    } catch (e) {
      errors.add('yt-dlp download: $e');
      return null;
    }
  }

  static Future<List<Audio>?> resolve(
      String videoId, List<String> errors) async {
    final bin = await _binary(errors);
    if (bin == null) return null;
    Future<ProcessResult> run() => Process.run(
            bin,
            [
              '-f', 'bestaudio/best',
              '--no-playlist',
              '--no-warnings',
              '-j',
              'https://www.youtube.com/watch?v=$videoId',
            ],
            stdoutEncoding: utf8,
            stderrEncoding: utf8)
        .timeout(const Duration(seconds: 60));
    try {
      var result = await run();
      if (result.exitCode != 0 && bin != 'yt-dlp') {
        // outdated binary is the usual reason: self-update once and retry
        await Process.run(bin, ['-U']).timeout(const Duration(seconds: 90));
        result = await run();
      }
      if (result.exitCode != 0) {
        errors.add('yt-dlp: ${'${result.stderr}'.trim().split('\n').last}');
        return null;
      }
      final candidates =
          parseYtDlpJson(jsonDecode('${result.stdout}'.trim().split('\n').first));
      if (candidates.isEmpty) {
        errors.add('yt-dlp: no audio');
        return null;
      }
      final audios = candidatesToAudios(candidates);
      final problem = await StreamProxy.instance.validate(audios.last.url);
      if (problem != null) {
        errors.add('yt-dlp: $problem');
        return null;
      }
      return audios;
    } catch (e) {
      errors.add('yt-dlp: $e');
      return null;
    }
  }
}
