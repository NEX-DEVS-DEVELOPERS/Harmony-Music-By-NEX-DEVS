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
    Duration listenFor = const Duration(seconds: 10),
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
      const RecordConfig(
          encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1),
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
      if (result == null) return null;
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

  Future<void> cancel() async {
    if (await _recorder.isRecording()) await _recorder.stop();
  }

  Future<void> dispose() async {
    await cancel();
    await _recorder.dispose();
  }
}
