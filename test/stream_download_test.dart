import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonymusic/services/stream_proxy.dart';

Future<HttpServer> _server(Uint8List data, {bool alwaysForbidden = false}) async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((req) async {
    if (alwaysForbidden) {
      req.response.statusCode = 403;
      await req.response.close();
      return;
    }
    int from = 0, to = data.length - 1;
    final src = req.uri.queryParameters['range'] ??
        req.headers.value('range')?.replaceFirst('bytes=', '');
    if (src != null) {
      final p = src.split('-');
      from = int.parse(p[0]);
      if (p.length > 1 && p[1].isNotEmpty) to = int.parse(p[1]);
    }
    if (to - from + 1 > 2 * 1024 * 1024) {
      req.response.statusCode = 403; // YouTube-like: big ranges refused
    } else {
      req.response.statusCode = 206;
      req.response.add(data.sublist(from, to + 1));
    }
    await req.response.close();
  });
  return s;
}

void main() {
  final data = Uint8List.fromList(
      List.generate(4 * 1024 * 1024 + 777, (i) => (i * 13 + i ~/ 97) & 0xFF));
  data.setRange(0, 4, [0x1A, 0x45, 0xDF, 0xA3]); // WebM signature

  for (final c in ['ANDROID', 'WEB']) {
    test('downloadToFile gets the exact bytes in small ranges (c=$c)', () async {
      final up = await _server(data);
      final dir = await Directory.systemTemp.createTemp('hm_dl');
      final progress = <int>[];
      final f = await StreamProxy.instance.downloadToFile(
          'http://127.0.0.1:${up.port}/v?c=$c&clen=${data.length}',
          '${dir.path}/song.audio',
          onProgress: (r, t) => progress.add(r));
      expect(await f.length(), data.length);
      expect(await f.readAsBytes(), data);
      expect(progress.last, data.length);
      expect(File('${dir.path}/song.audio.part').existsSync(), isFalse);
      await up.close(force: true);
      await dir.delete(recursive: true);
    });
  }

  test('failure reports the real reason and leaves no partial file', () async {
    final up = await _server(data, alwaysForbidden: true);
    final dir = await Directory.systemTemp.createTemp('hm_dl');
    await expectLater(
        StreamProxy.instance.downloadToFile(
            'http://127.0.0.1:${up.port}/v?c=WEB&clen=${data.length}',
            '${dir.path}/x.audio'),
        throwsA(predicate((e) => e.toString().contains('403'))));
    expect(dir.listSync(), isEmpty);
    await up.close(force: true);
    await dir.delete(recursive: true);
  });

  test('refuses to save a non-audio response (e.g. an HTML error page)', () async {
    final html = Uint8List.fromList(
        ('<html><body>Sign in to confirm you are not a bot</body></html>' * 100)
            .codeUnits);
    final up = await _server(html);
    final dir = await Directory.systemTemp.createTemp('hm_dl');
    await expectLater(
        StreamProxy.instance.downloadToFile(
            'http://127.0.0.1:${up.port}/v?c=WEB&clen=${html.length}',
            '${dir.path}/x.audio'),
        throwsA(predicate(
            (e) => e.toString().contains('not audio') && e.toString().contains('<html>'))));
    expect(dir.listSync(), isEmpty);
    await up.close(force: true);
    await dir.delete(recursive: true);
  });

  test('notAudioReason recognises common containers', () {
    expect(StreamProxy.notAudioReason([0x1A, 0x45, 0xDF, 0xA3, 0]), isNull);
    expect(StreamProxy.notAudioReason([0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70]), isNull);
    expect(StreamProxy.notAudioReason('OggS....'.codeUnits), isNull);
    expect(StreamProxy.notAudioReason([0xFF, 0xF1, 0x50, 0x80]), isNull);
    expect(StreamProxy.notAudioReason('{"error":1}'.codeUnits), contains('not audio'));
  });
}
