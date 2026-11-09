import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

class RecognizedSong {
  RecognizedSong({
    required this.title,
    required this.artist,
    required this.positionInSong,
    required this.sampleStartedAt,
  });

  final String title;
  final String artist;

  /// Where in the song the recorded sample started.
  final Duration positionInSong;

  /// Wall-clock time the sample recording started at, used to work out how far
  /// into the song the music is *now* (so playback can jump to that part).
  final DateTime sampleStartedAt;

  Duration get currentPosition =>
      positionInSong + DateTime.now().difference(sampleStartedAt);
}

class RecognitionException implements Exception {
  RecognitionException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// "Shazam"-style song recognition: records a few seconds from the
/// microphone and asks the AudD service (https://audd.io) what it is.
/// The user's AudD API token is stored locally in the app preferences.
class SongRecognitionService {
  static const _tokenKey = 'auddApiToken';
  final AudioRecorder _recorder = AudioRecorder();

  /// Loudest level (dBFS, 0 = max, about -160 = silence) heard during the last
  /// recording. Used to tell "microphone heard nothing" from "song not found".
  double lastMaxLevelDb = -160;

  /// What happened on the last attempt (shown when no song was matched).
  String lastDiagnostic = '';

  /// Below this the microphone basically recorded silence.
  static const silenceThresholdDb = -50.0;
  final Dio _dio = Dio();

  static String? get apiToken {
    final t = Hive.box('AppPrefs').get(_tokenKey) as String?;
    return (t == null || t.trim().isEmpty) ? null : t.trim();
  }

  static Future<void> saveApiToken(String token) =>
      Hive.box('AppPrefs').put(_tokenKey, token.trim());

  /// Parses AudD timecodes such as "01:23" or "1:02:03".
  static Duration parseTimecode(String? tc) {
    if (tc == null || tc.isEmpty) return Duration.zero;
    final parts = tc.split(':').map((e) => int.tryParse(e) ?? 0).toList();
    if (parts.length == 3) {
      return Duration(hours: parts[0], minutes: parts[1], seconds: parts[2]);
    }
    if (parts.length == 2) {
      return Duration(minutes: parts[0], seconds: parts[1]);
    }
    return Duration(seconds: parts.first);
  }

  /// Records [listenFor] of audio and identifies it. Returns `null` when the
  /// song could not be recognised.
  Future<RecognizedSong?> listenAndIdentify({
    Duration listenFor = const Duration(seconds: 12),
    void Function()? onListeningDone,
  }) async {
    final token = apiToken;
    if (token == null) {
      throw RecognitionException('No AudD API token set');
    }
    if (!await _recorder.hasPermission()) {
      throw RecognitionException('Microphone permission denied');
    }

    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/harmony_listen_${DateTime.now().millisecondsSinceEpoch}.wav';
    await _recorder.start(
      // 44.1 kHz keeps the detail the fingerprint needs (16 kHz lost too much)
      const RecordConfig(
          encoder: AudioEncoder.wav, sampleRate: 44100, numChannels: 1),
      path: path,
    );
    final startedAt = DateTime.now();
    lastMaxLevelDb = -160;
    while (DateTime.now().difference(startedAt) < listenFor) {
      await Future.delayed(const Duration(milliseconds: 250));
      try {
        final amp = await _recorder.getAmplitude();
        if (amp.current > lastMaxLevelDb) lastMaxLevelDb = amp.current;
      } catch (_) {}
    }
    final recorded = await _recorder.stop();
    onListeningDone?.call();
    if (recorded == null) {
      throw RecognitionException('Could not record audio');
    }
    if (lastMaxLevelDb < silenceThresholdDb) {
      throw RecognitionException(
          'The microphone heard almost no sound. On Windows open Settings > '
          'Privacy & security > Microphone and allow desktop apps, and check '
          'the right input device is selected. Then play the music near the '
          'microphone and try again.');
    }

    // Some recorders leave the WAV length fields empty; make them correct so
    // the service can read the whole clip.
    await fixWavHeader(File(recorded));
    final sizeKb = (await File(recorded).length()) ~/ 1024;
    lastDiagnostic =
        'sent ${listenFor.inSeconds}s of audio ($sizeKb KB), level ${lastMaxLevelDb.toStringAsFixed(0)} dB';

    try {
      final form = FormData.fromMap({
        'api_token': token,
        'file': await MultipartFile.fromFile(recorded, filename: 'sample.wav'),
      });
      final res = await _dio.post('https://api.audd.io/',
          data: form,
          options: Options(
              sendTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 20)));
      final data = res.data;
      if (data is Map && data['status'] == 'error') {
        throw RecognitionException(
            data['error']?['error_message']?.toString() ?? 'AudD error');
      }
      final result = (data is Map) ? data['result'] : null;
      if (result == null) {
        lastDiagnostic = '$lastDiagnostic; AudD found no match';
        return null;
      }
      return RecognizedSong(
        title: result['title']?.toString() ?? '',
        artist: result['artist']?.toString() ?? '',
        positionInSong: parseTimecode(result['timecode']?.toString()),
        sampleStartedAt: startedAt,
      );
    } on DioException catch (e) {
      throw RecognitionException('Network error: ${e.message}');
    }
  }

  /// Makes the RIFF/data length fields of a WAV file match its real size
  /// (they are 0 / 0xFFFFFFFF in some streamed recordings). No-op for other
  /// files or when the fields are already right.
  static Future<void> fixWavHeader(File file) async {
    final raf = await file.open(mode: FileMode.append);
    try {
      final total = await raf.length();
      if (total < 44) return;
      await raf.setPosition(0);
      final head = await raf.read(total < 4096 ? total : 4096);
      String tag(int at) => String.fromCharCodes(head.sublist(at, at + 4));
      if (tag(0) != 'RIFF' || tag(8) != 'WAVE') return;
      // walk the chunks to find "data"
      var pos = 12;
      int? dataHeaderAt;
      while (pos + 8 <= head.length) {
        final size =
            head[pos + 4] | head[pos + 5] << 8 | head[pos + 6] << 16 | head[pos + 7] << 24;
        if (tag(pos) == 'data') {
          dataHeaderAt = pos;
          break;
        }
        pos += 8 + size + (size & 1);
      }
      if (dataHeaderAt == null) return;
      void put32(Uint8List b, int v) {
        b[0] = v & 0xFF;
        b[1] = (v >> 8) & 0xFF;
        b[2] = (v >> 16) & 0xFF;
        b[3] = (v >> 24) & 0xFF;
      }

      final riff = Uint8List(4), data = Uint8List(4);
      put32(riff, total - 8);
      put32(data, total - (dataHeaderAt + 8));
      await raf.setPosition(4);
      await raf.writeFrom(riff);
      await raf.setPosition(dataHeaderAt + 4);
      await raf.writeFrom(data);
    } finally {
      await raf.close();
    }
  }

  Future<void> cancel() async {
    if (await _recorder.isRecording()) await _recorder.stop();
  }

  Future<void> dispose() async {
    await cancel();
    await _recorder.dispose();
  }
}
