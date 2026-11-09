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
}
