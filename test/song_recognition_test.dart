import 'package:flutter_test/flutter_test.dart';
import 'package:harmonymusic/services/song_recognition_service.dart';

void main() {
  test('parses AudD timecodes', () {
    expect(SongRecognitionService.parseTimecode('01:23'),
        const Duration(minutes: 1, seconds: 23));
    expect(SongRecognitionService.parseTimecode('1:02:03'),
        const Duration(hours: 1, minutes: 2, seconds: 3));
    expect(SongRecognitionService.parseTimecode(null), Duration.zero);
    expect(SongRecognitionService.parseTimecode('45'),
        const Duration(seconds: 45));
  });

  test('current position advances with time since the sample started', () {
    final song = RecognizedSong(
        title: 't',
        artist: 'a',
        positionInSong: const Duration(seconds: 30),
        sampleStartedAt: DateTime.now().subtract(const Duration(seconds: 12)));
    expect(song.currentPosition.inSeconds, inInclusiveRange(42, 43));
  });
}
