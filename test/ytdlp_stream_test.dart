import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonymusic/services/stream_sources.dart';

Future<String> _fake(Directory dir, String body) async {
  final f = File('${dir.path}/fake-yt-dlp.sh');
  await f.writeAsString('#!/bin/sh\n$body\n');
  await Process.run('chmod', ['+x', f.path]);
  return f.path;
}

Future<Uint8List> _get(String url, {String? range, void Function(int)? onFirst}) async {
  final c = HttpClient();
  final req = await c.getUrl(Uri.parse(url));
  if (range != null) req.headers.set('range', range);
  final res = await req.close();
  final b = BytesBuilder();
  var first = true;
  await for (final d in res) {
    if (first) {
      first = false;
      onFirst?.call(b.length + d.length);
    }
    b.add(d);
  }
  c.close();
  return b.takeBytes();
}

void main() {
  // webm signature + 20000 zero bytes, a 2s pause, then 20000 more zero bytes
  const slow = r'''
echo run >> "$1"
printf '\032\105\337\243'
head -c 20000 /dev/zero
sleep 2
head -c 20000 /dev/zero
''';

  test('audio is playable before yt-dlp has finished; copy kept for replays',
      () async {
    final tmp = await Directory.systemTemp.createTemp('hm_stream');
    final bin = await _fake(tmp, slow);
    final out = Directory('${tmp.path}/out');
    final log = '${tmp.path}/runs.log';
    final errors = <String>[];

    final sw = Stopwatch()..start();
    final url = await YtDlpSource.playableLocation('vid1', errors,
        binary: bin, outDir: out, streamArgs: [log]);
    expect(errors, isEmpty);
    expect(url, startsWith('http://127.0.0.1:'));
    // ready after the first bytes, long before the 2s "download" ends
    expect(sw.elapsedMilliseconds, lessThan(1800));

    var firstAt = -1;
    final data = await _get(url!, onFirst: (_) => firstAt = sw.elapsedMilliseconds);
    expect(firstAt, lessThan(1800)); // first audio bytes arrive early
    expect(data.length, 40004);
    expect(data.sublist(0, 4), [0x1A, 0x45, 0xDF, 0xA3]);
    expect(sw.elapsedMilliseconds, greaterThan(1900)); // full file took ~2s

    // a second (simultaneous-style) request is served from memory: no 2nd run
    final again = await _get(url);
    expect(again.length, 40004);
    expect(File(log).readAsLinesSync().length, 1);

    // seeking after completion works (206 + exact bytes)
    final tail = await _get(url, range: 'bytes=39000-');
    expect(tail.length, 40004 - 39000);

    // finished copy is kept, next play is a local file, instant, no process
    await Future.delayed(const Duration(milliseconds: 300));
    final replay = await YtDlpSource.playableLocation('vid1', errors,
        binary: bin, outDir: out, streamArgs: [log]);
    expect(replay, endsWith('vid1.webm'));
    expect(File(replay!).lengthSync(), 40004);
    expect(File(log).readAsLinesSync().length, 1);
    await tmp.delete(recursive: true);
  });

  test('yt-dlp failure is reported, not hung', () async {
    final tmp = await Directory.systemTemp.createTemp('hm_stream');
    final bin = await _fake(
        tmp, 'echo "ERROR: Video unavailable" >&2\nexit 1');
    final errors = <String>[];
    final url = await YtDlpSource.playableLocation('vid2', errors,
        binary: bin, outDir: Directory('${tmp.path}/out'), streamArgs: []);
    expect(url, isNull);
    expect(errors.single, contains('Video unavailable'));
    await tmp.delete(recursive: true);
  });
}
