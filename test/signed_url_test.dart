import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonymusic/services/stream_proxy.dart';

/// Mimics a Piped / Invidious proxy: the URL is signed, so ANY change to the
/// query string (e.g. an added `range=`) gives 403. Only a Range header works.
Future<HttpServer> _signedServer(Uint8List data,
    {int? forbidMiddleFrom}) async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((req) async {
    final expectedQuery = 'expire=99&sig=abc%3D%3D&clen=${data.length}';
    if (req.uri.query != expectedQuery) {
      req.response.statusCode = 403; // URL was modified -> signature mismatch
      await req.response.close();
      return;
    }
    final h = req.headers.value('range');
    var from = 0, to = data.length - 1;
    if (h != null) {
      final p = h.replaceFirst('bytes=', '').split('-');
      from = int.parse(p[0]);
      if (p[1].isNotEmpty) to = int.parse(p[1]);
    }
    if (forbidMiddleFrom != null && from >= forbidMiddleFrom) {
      req.response.statusCode = 403;
      await req.response.close();
      return;
    }
    req.response.statusCode = 206;
    req.response.add(data.sublist(from, to + 1));
    await req.response.close();
  });
  return s;
}

void main() {
  final data = Uint8List.fromList(
      List.generate(5 * 1024 * 1024 + 11, (i) => (i * 31 + i ~/ 53) & 0xFF))
    ..setRange(0, 4, [0x1A, 0x45, 0xDF, 0xA3]);

  test('signed (Piped/Invidious-style) URL downloads fine: URL left untouched',
      () async {
    final up = await _signedServer(data);
    final url =
        'http://127.0.0.1:${up.port}/videoplayback?expire=99&sig=abc%3D%3D&clen=${data.length}';
    final dir = await Directory.systemTemp.createTemp('hm_sig');
    expect(await StreamProxy.instance.validate(url), isNull);
    final f = await StreamProxy.instance
        .downloadToFile(url, '${dir.path}/s.audio');
    expect(await f.readAsBytes(), data);
    await up.close(force: true);
    await dir.delete(recursive: true);
  });

  test('a source that fails only in the middle of the file is rejected by validate',
      () async {
    final up = await _signedServer(data, forbidMiddleFrom: 1024 * 1024);
    final url =
        'http://127.0.0.1:${up.port}/videoplayback?expire=99&sig=abc%3D%3D&clen=${data.length}';
    expect(await StreamProxy.instance.validate(url), 'HTTP 403');
    await up.close(force: true);
  });
}
