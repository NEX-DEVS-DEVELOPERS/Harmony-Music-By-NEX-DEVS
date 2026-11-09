import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../utils/helper.dart';
import 'stream_proxy.dart';

/// One running `yt-dlp -o -` process whose output is kept in memory so any
/// number of player requests (and seeks within what has arrived) can be
/// served while it is still downloading.
class YtDlpStreamJob {
  YtDlpStreamJob(this.videoId, this.binary, this.cacheDir, {List<String>? args})
      : _args = args;

  final String videoId;
  final String binary;
  final Directory cacheDir;
  final List<String>? _args;

  Uint8List _buf = Uint8List(1 << 20);
  int length = 0;
  bool done = false;
  String? error;
  Process? _process;
  final _stderrTail = <String>[];
  final StreamController<void> _tick = StreamController<void>.broadcast();
  final Completer<void> _firstBytes = Completer<void>();
  IOSink? _fileSink;
  File? _partFile;
  String? finalPath;

  bool get failed => error != null;

  Future<void> start() async {
    await cacheDir.create(recursive: true);
    _partFile = File('${cacheDir.path}/$videoId.webm.stream.part');
    _fileSink = _partFile!.openWrite();
    final args = _args ??
        [
          '-f', 'bestaudio[ext=webm]/bestaudio',
          '--no-playlist',
          '--no-warnings',
          '--quiet',
          '--no-progress',
          '--socket-timeout', '20',
          '--retries', '3',
          '-o', '-',
          'https://www.youtube.com/watch?v=$videoId',
        ];
    try {
      _process = await Process.start(binary, args);
    } catch (e) {
      _fail('could not start yt-dlp: $e');
      return;
    }
    _process!.stderr.transform(const SystemEncoding().decoder).listen((s) {
      for (final line in s.split('\n')) {
        if (line.trim().isNotEmpty) _stderrTail.add(line.trim());
      }
      if (_stderrTail.length > 5) {
        _stderrTail.removeRange(0, _stderrTail.length - 5);
      }
    });
    _process!.stdout.listen(_onData, onDone: _onDone, onError: (e) {
      _fail('stream error: $e');
    });
    // no data at all for a minute -> give up
    Timer(const Duration(seconds: 60), () {
      if (!_firstBytes.isCompleted) {
        _fail('yt-dlp produced no audio within 60s');
        _process?.kill();
      }
    });
  }

  void _onData(List<int> data) {
    if (length + data.length > _buf.length) {
      var cap = _buf.length * 2;
      while (cap < length + data.length) {
        cap *= 2;
      }
      final nb = Uint8List(cap)..setRange(0, length, _buf);
      _buf = nb;
    }
    _buf.setRange(length, length + data.length, data);
    length += data.length;
    _fileSink?.add(data);
    if (!_firstBytes.isCompleted) _firstBytes.complete();
    _tick.add(null);
  }

  Future<void> _onDone() async {
    final code = await _process!.exitCode;
    await _fileSink?.close();
    _fileSink = null;
    if (code != 0 && length < 10 * 1024) {
      _fail(_stderrTail.isEmpty ? 'yt-dlp exited with code $code' : _stderrTail.last);
      return;
    }
    // keep a copy for instant replays (only if it is real, complete audio)
    final bad = StreamProxy.notAudioReason(_buf.sublist(0, length < 64 ? length : 64));
    if (code == 0 && bad == null && length > 10 * 1024) {
      try {
        final fin = '${cacheDir.path}/$videoId.webm';
        if (await File(fin).exists()) await File(fin).delete();
        await _partFile!.rename(fin);
        finalPath = fin;
      } catch (e) {
        printERROR('could not keep stream copy: $e');
      }
    } else {
      try {
        await _partFile?.delete();
      } catch (_) {}
    }
    done = true;
    if (!_firstBytes.isCompleted) _firstBytes.complete();
    _tick.add(null);
  }

  void _fail(String message) {
    error ??= message;
    done = true;
    if (!_firstBytes.isCompleted) _firstBytes.completeError(message);
    _tick.add(null);
  }

  /// Completes when the first audio bytes have arrived (or throws why not).
  Future<void> get firstBytes => _firstBytes.future;

  /// Waits for more data (or the end). Returns false on timeout.
  Future<bool> waitForChange({Duration timeout = const Duration(seconds: 45)}) async {
    try {
      await _tick.stream.first.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  Uint8List slice(int from, int to) => Uint8List.sublistView(_buf, from, to);

  void kill() {
    _process?.kill();
  }
}

/// Localhost HTTP server that plays a [YtDlpStreamJob] to the audio player.
class YtDlpStreamer {
  YtDlpStreamer._();
  static final YtDlpStreamer instance = YtDlpStreamer._();

  HttpServer? _server;
  final Map<String, YtDlpStreamJob> _jobs = {};

  /// Starts (or reuses) the stream for [videoId] and returns the URL to play
  /// once the first bytes are available. Throws if yt-dlp fails.
  Future<String> start(String videoId, String binary, Directory cacheDir,
      {List<String>? args}) async {
    var job = _jobs[videoId];
    if (job == null || job.failed) {
      job = YtDlpStreamJob(videoId, binary, cacheDir, args: args);
      _jobs[videoId] = job;
      await job.start();
      // keep memory bounded: only the 3 newest songs stay in memory
      while (_jobs.length > 4) {
        final finished = _jobs.entries.where((e) => e.value.done).toList();
        if (finished.isEmpty) break; // never cut a song that is still loading
        _jobs.remove(finished.first.key);
      }
    }
    await job.firstBytes;
    final server = await _ensureServer();
    return 'http://127.0.0.1:${server.port}/y/$videoId.webm';
  }

  Future<HttpServer> _ensureServer() async {
    return _server ??= await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
      ..listen(_handle, onError: (e) => printERROR('YtDlpStreamer: $e'));
  }

  Future<void> close() async {
    for (final j in _jobs.values) {
      j.kill();
    }
    _jobs.clear();
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final m = RegExp(r'^/y/([^/.]+)\.webm$').firstMatch(req.uri.path);
      final job = m == null ? null : _jobs[m.group(1)!];
      if (job == null) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      var start = 0;
      var partial = false;
      final range = req.headers.value(HttpHeaders.rangeHeader);
      final rm = range == null ? null : RegExp(r'bytes=(\d+)-').firstMatch(range);
      if (rm != null) {
        start = int.parse(rm.group(1)!);
        partial = true;
      }
      res.headers
        ..set(HttpHeaders.contentTypeHeader, 'audio/webm')
        ..set(HttpHeaders.acceptRangesHeader, 'bytes');
      if (job.done && !job.failed) {
        // everything is here: a normal, fully seekable answer
        if (start >= job.length) {
          res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */${job.length}');
          await res.close();
          return;
        }
        res.statusCode = partial ? HttpStatus.partialContent : HttpStatus.ok;
        res.headers.set(HttpHeaders.contentLengthHeader, job.length - start);
        if (partial) {
          res.headers.set(HttpHeaders.contentRangeHeader,
              'bytes $start-${job.length - 1}/${job.length}');
        }
      } else {
        // still downloading: length unknown, send as it arrives
        res.statusCode = partial ? HttpStatus.partialContent : HttpStatus.ok;
        if (partial) {
          res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-*/*');
        }
        res.headers.chunkedTransferEncoding = true;
      }
      if (req.method == 'HEAD') {
        await res.close();
        return;
      }

      var pos = start;
      var clientGone = false;
      res.done.then((_) => clientGone = true, onError: (_) => clientGone = true);
      while (!clientGone) {
        if (pos < job.length) {
          final end = job.length;
          res.add(job.slice(pos, end));
          pos = end;
          await res.flush();
        } else if (job.done) {
          break;
        } else if (!await job.waitForChange()) {
          break; // nothing arrived for 45s
        }
      }
      await res.close();
    } catch (e) {
      try {
        await res.close();
      } catch (_) {}
    }
  }
}
