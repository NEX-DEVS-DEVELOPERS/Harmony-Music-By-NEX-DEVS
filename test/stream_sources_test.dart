import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonymusic/services/stream_proxy.dart';
import 'package:harmonymusic/services/stream_service.dart';
import 'package:harmonymusic/services/stream_sources.dart';

void main() {
  test('Piped response -> candidates -> Audio list (low..high)', () {
    final json = {
      'audioStreams': [
        {'url': 'https://pp.example/a?x=1', 'format': 'M4A', 'mimeType': 'audio/mp4; codecs="mp4a.40.2"', 'bitrate': 129000, 'contentLength': 3000000},
        {'url': 'https://pp.example/b?x=2', 'format': 'WEBM', 'mimeType': 'audio/webm; codecs="opus"', 'bitrate': 70000, 'contentLength': 1500000},
        {'url': 'https://pp.example/c?x=3', 'format': 'WEBM', 'mimeType': 'audio/webm; codecs="opus"', 'bitrate': 140000, 'contentLength': 3200000},
        {'url': 'https://pp.example/dub?x=4', 'format': 'M4A', 'mimeType': 'audio/mp4; codecs="mp4a.40.2"', 'bitrate': 999999, 'audioTrackType': 'DUBBED'},
      ],
    };
    final c = parsePipedStreams(json);
    expect(c.length, 3); // dubbed track skipped
    final audios = candidatesToAudios(c);
    final best = audios.lastWhere((a) => a.itag == 251 || a.itag == 140);
    expect(best.itag, 140); // aac group is last in the list
    final opusBest = audios.firstWhere((a) => a.itag == 251);
    expect(opusBest.url, 'https://pp.example/c?x=3');
    expect(opusBest.bitrate, 140000);
    expect(audios.firstWhere((a) => a.itag == 249).bitrate, 70000);
    expect(opusBest.audioCodec, Codec.opus);
  });

  test('Invidious response parsed, relative urls made absolute', () {
    final json = {
      'adaptiveFormats': [
        {'type': 'video/mp4; codecs="avc1"', 'url': '/videoplayback?v=1', 'bitrate': '999'},
        {'type': 'audio/webm; codecs="opus"', 'url': '/videoplayback?itag=251', 'bitrate': '131072', 'clen': '3300000'},
        {'type': 'audio/mp4; codecs="mp4a.40.2"', 'url': 'https://inv.example/videoplayback?itag=140', 'bitrate': '129000', 'clen': '3000000'},
      ],
    };
    final c = parseInvidiousFormats(json, 'https://inv.example');
    expect(c.length, 2);
    expect(c.first.url, 'https://inv.example/videoplayback?itag=251');
    expect(c.first.isOpus, isTrue);
    expect(c.first.size, 3300000);
  });

  test('yt-dlp json: audio-only http formats with headers', () {
    final json = {
      'formats': [
        {'url': 'https://v.example/1', 'vcodec': 'avc1', 'acodec': 'none'},
        {'url': 'https://v.example/2', 'vcodec': 'none', 'acodec': 'opus', 'abr': 130.5, 'filesize': 3100000, 'protocol': 'https', 'http_headers': {'User-Agent': 'UA'}},
        {'url': 'https://v.example/3.m3u8', 'vcodec': 'none', 'acodec': 'aac', 'protocol': 'm3u8_native'},
      ],
    };
    final c = parseYtDlpJson(json);
    expect(c.length, 1);
    expect(c.first.bitrate, 130500);
    expect(c.first.headers!['User-Agent'], 'UA');
  });

  test('firstSuccess returns first non-null, null if all fail', () async {
    final r = await firstSuccess<int>([
      Future.delayed(const Duration(milliseconds: 80), () => 1),
      Future.delayed(const Duration(milliseconds: 10), () => null),
      Future.delayed(const Duration(milliseconds: 30), () => throw 'boom'),
      Future.delayed(const Duration(milliseconds: 40), () => 2),
    ]);
    expect(r, 2);
    expect(await firstSuccess<int>([Future.value(null), Future.error('x')]), isNull);
    expect(await firstSuccess<int>([]), isNull);
  });

  test('validate: OK for a working url, reason for 403/empty', () async {
    final data = Uint8List(5000)..setRange(0, 4, [0x1A, 0x45, 0xDF, 0xA3]);
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    s.listen((req) async {
      switch (req.uri.path) {
        case '/ok':
          req.response.statusCode = 206;
          req.response.add(data.sublist(0, 2048));
        case '/forbidden':
          req.response.statusCode = 403;
        case '/empty':
          req.response.statusCode = 200;
      }
      await req.response.close();
    });
    final base = 'http://127.0.0.1:${s.port}';
    expect(await StreamProxy.instance.validate('$base/ok'), isNull);
    expect(await StreamProxy.instance.validate('$base/forbidden'), startsWith('HTTP 403'));
    expect(await StreamProxy.instance.validate('$base/empty'), 'empty response');
    await s.close(force: true);
  });
}
