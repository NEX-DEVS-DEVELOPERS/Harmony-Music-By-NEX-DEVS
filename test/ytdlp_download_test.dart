import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonymusic/services/stream_service.dart';
import 'package:harmonymusic/services/stream_sources.dart';

/// Writes a fake "yt-dlp" shell script (test double, not the real tool).
Future<String> _fakeYtDlp(Directory dir, String body) async {
  final f = File('${dir.path}/fake-yt-dlp.sh');
  await f.writeAsString('''#!/bin/sh
out=""
while [ \$# -gt 0 ]; do
  if [ "\$1" = "-o" ]; then out="\$2"; fi
  shift
done
$body
''');
  await Process.run('chmod', ['+x', f.path]);
  return f.path;
}

void main() {
  const writeWebm = r'''
path=$(echo "$out" | sed 's/%(ext)s/webm/')
printf '\032\105\337\243' > "$path"
head -c 30000 /dev/zero >> "$path"
echo run >> "$(dirname "$path")/runs.log"
''';

  test('yt-dlp download -> local audio file Audio, and reuse on second call',
      () async {
    final tmp = await Directory.systemTemp.createTemp('hm_ytdlp');
    final bin = await _fakeYtDlp(tmp, writeWebm);
    final out = Directory('${tmp.path}/out');
    final errors = <String>[];
    final audios =
        await YtDlpSource.downloadAudio('abc123', errors, binary: bin, outDir: out);
    expect(errors, isEmpty);
    expect(audios, isNotNull);
    final a = audios!.single;
    expect(a.url, endsWith('abc123.webm'));
    expect(a.audioCodec, Codec.opus);
    expect(a.size, 30004);
    expect(File(a.url).existsSync(), isTrue);

    // second call reuses the file: the fake binary is not run again
    final again =
        await YtDlpSource.downloadAudio('abc123', errors, binary: bin, outDir: out);
    expect(again!.single.url, a.url);
    expect(File('${out.path}/runs.log').readAsLinesSync().length, 1);
    await tmp.delete(recursive: true);
  });

  test('yt-dlp failure is reported with its own message', () async {
    final tmp = await Directory.systemTemp.createTemp('hm_ytdlp');
    final bin = await _fakeYtDlp(
        tmp, 'echo "ERROR: Sign in to confirm you are not a bot" >&2\nexit 1');
    final errors = <String>[];
    final r = await YtDlpSource.downloadAudio('abc123', errors,
        binary: bin, outDir: Directory('${tmp.path}/out'));
    expect(r, isNull);
    expect(errors.single, contains('Sign in to confirm'));
    await tmp.delete(recursive: true);
  });

  test('a non-audio file from yt-dlp is rejected, not played', () async {
    final tmp = await Directory.systemTemp.createTemp('hm_ytdlp');
    final bin = await _fakeYtDlp(tmp, r'''
path=$(echo "$out" | sed 's/%(ext)s/webm/')
i=0; while [ $i -lt 1000 ]; do printf '<html>blocked page</html>' >> "$path"; i=$((i+1)); done
''');
    final errors = <String>[];
    final r = await YtDlpSource.downloadAudio('abc123', errors,
        binary: bin, outDir: Directory('${tmp.path}/out'));
    expect(r, isNull);
    expect(errors.single, contains('not audio'));
    expect(Directory('${tmp.path}/out').listSync().whereType<File>().where((f) => f.path.endsWith('.webm')), isEmpty);
    await tmp.delete(recursive: true);
  });
}
