import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonymusic/services/stream_proxy.dart';

/// Fake "googlevideo": serves a known byte pattern, honours Range header or
/// `range` query param, and REJECTS (403) requests for more than 11 MB at once,
/// like YouTube does for whole-file requests.
Future<HttpServer> _fakeUpstream(Uint8List data, List<String> log) async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((req) async {
    int from = 0, to = data.length - 1;
    final q = req.uri.queryParameters['range'];
    final h = req.headers.value('range');
    final src = q ?? h?.replaceFirst('bytes=', '');
    if (src != null) {
      final p = src.split('-');
      from = int.parse(p[0]);
      if (p.length > 1 && p[1].isNotEmpty) to = int.parse(p[1]);
    }
    log.add('${req.uri.queryParameters['c']}:$from-$to');
    if (to - from + 1 > 11 * 1024 * 1024) {
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
      List.generate(25 * 1024 * 1024 + 123, (i) => (i * 7 + i ~/ 251) & 0xFF));

  for (final client in ['ANDROID', 'WEB']) {
    test('plays a whole 25MB file in chunks (client=$client)', () async {
      final log = <String>[];
      final up = await _fakeUpstream(data, log);
      final url = await StreamProxy.instance.urlFor(
          'http://127.0.0.1:${up.port}/videoplayback?c=$client&clen=${data.length}&mime=audio%2Fwebm');

      final c = HttpClient();
      final r = await (await c.getUrl(Uri.parse(url))).close();
      expect(r.statusCode, 200);
      expect(r.headers.value('content-type'), 'audio/webm');
      expect(r.headers.value('accept-ranges'), 'bytes');
      final got = BytesBuilder();
      await for (final d in r) {
        got.add(d);
      }
      expect(got.length, data.length);
      expect(got.takeBytes(), data);
      // never asked upstream for more than one chunk at a time
      expect(log.length, greaterThanOrEqualTo(3));
      await up.close(force: true);
    });
  }

  test('supports seeking (Range requests) and HEAD', () async {
    final log = <String>[];
    final up = await _fakeUpstream(data, log);
    final url = await StreamProxy.instance.urlFor(
        'http://127.0.0.1:${up.port}/videoplayback?c=ANDROID&clen=${data.length}&mime=audio%2Fmp4');
    final c = HttpClient();

    final head = await (await c.headUrl(Uri.parse(url))).close();
    expect(head.headers.value('content-length'), '${data.length}');

    final req = await c.getUrl(Uri.parse(url));
    req.headers.set('range', 'bytes=12000000-12000999');
    final r = await req.close();
    expect(r.statusCode, 206);
    expect(r.headers.value('content-range'),
        'bytes 12000000-12000999/${data.length}');
    final b = BytesBuilder();
    await for (final d in r) {
      b.add(d);
    }
    expect(b.takeBytes(), data.sublist(12000000, 12001000));

    // open-ended range from the middle (what players send after a seek)
    final req2 = await c.getUrl(Uri.parse(url));
    req2.headers.set('range', 'bytes=${data.length - 500}-');
    final r2 = await req2.close();
    final b2 = BytesBuilder();
    await for (final d in r2) {
      b2.add(d);
    }
    expect(b2.takeBytes(), data.sublist(data.length - 500));
    await up.close(force: true);
  });

  test('only googlevideo hosts are proxied', () {
    expect(StreamProxy.shouldProxy('https://rr1---sn-abc.googlevideo.com/x'),
        isTrue);
    expect(StreamProxy.shouldProxy('C:/music/song.opus'), isFalse);
    expect(StreamProxy.shouldProxy('https://example.com/a.mp3'), isFalse);
  });
}
