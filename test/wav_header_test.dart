import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonymusic/services/song_recognition_service.dart';

Uint8List _wav({required int riffSize, required int dataSize, int pcmBytes = 1000}) {
  final b = BytesBuilder();
  void s(String t) => b.add(t.codeUnits);
  void u32(int v) => b.add([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]);
  s('RIFF'); u32(riffSize); s('WAVE');
  s('fmt '); u32(16); b.add([1, 0, 1, 0]); u32(44100); u32(88200); b.add([2, 0, 16, 0]);
  s('data'); u32(dataSize);
  b.add(Uint8List(pcmBytes));
  return b.takeBytes();
}

int _u32(Uint8List b, int at) => b[at] | b[at + 1] << 8 | b[at + 2] << 16 | b[at + 3] << 24;

void main() {
  test('WAV with empty/streamed length fields gets correct sizes', () async {
    final dir = await Directory.systemTemp.createTemp('hm_wav');
    final f = File('${dir.path}/a.wav')
      ..writeAsBytesSync(_wav(riffSize: 0, dataSize: 0xFFFFFFFF));
    await SongRecognitionService.fixWavHeader(f);
    final b = f.readAsBytesSync();
    expect(_u32(b, 4), b.length - 8);
    expect(_u32(b, 40), 1000); // data chunk size
    expect(b.length, 44 + 1000);
    await dir.delete(recursive: true);
  });

  test('a correct WAV and non-WAV files are left alone', () async {
    final dir = await Directory.systemTemp.createTemp('hm_wav');
    final good = _wav(riffSize: 36 + 1000, dataSize: 1000);
    final f = File('${dir.path}/b.wav')..writeAsBytesSync(good);
    await SongRecognitionService.fixWavHeader(f);
    expect(f.readAsBytesSync(), good);
    final other = File('${dir.path}/c.bin')..writeAsBytesSync(List.filled(200, 7));
    await SongRecognitionService.fixWavHeader(other);
    expect(other.readAsBytesSync(), List.filled(200, 7));
    await dir.delete(recursive: true);
  });
}
