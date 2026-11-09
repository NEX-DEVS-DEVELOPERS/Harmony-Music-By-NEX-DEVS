import 'dart:io';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harmonymusic/models/artist.dart';
import 'package:harmonymusic/services/music_service.dart';

/// Serves a recorded YouTube Music response instead of hitting the network.
class _Fixture implements HttpClientAdapter {
  _Fixture(this.path);
  final String path;
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? s,
          Future<void>? c) async =>
      ResponseBody.fromString(File(path).readAsStringSync(), 200,
          headers: {
            Headers.contentTypeHeader: ['application/json']
          });
  @override
  void close({bool force = false}) {}
}

MusicServices _serviceWith(String fixture) =>
    MusicServices()..dio.httpClientAdapter = _Fixture('test/fixtures/$fixture');

void main() {
  test('mixed results (Videos/Artists/Profiles/Podcasts/Episodes) parse', () async {
    final r = await _serviceWith('search_mixed.json').search('ncs');
    expect(r['Artists'], isNotEmpty);
    expect(r['Artists'].first, isA<Artist>());
    expect(r['Videos'], isNotEmpty);
    expect(r['Videos'].first, isA<MediaItem>());
    // Profiles / podcasts / episodes used to be mis-parsed as bogus "Albums".
    expect(r.containsKey('Albums'), isFalse);
    expect((r['searchEndpoint'] as Map).containsKey('Videos'), isTrue);
  });

  test('"No results" message (no flexColumns) no longer throws', () async {
    final r = await _serviceWith('search_no_results.json')
        .search('x', filter: 'songs', filterParams: 'EgWKAQIIAWoMEA4QChADEAQQCRAF');
    expect(r.values.whereType<List>().every((l) => l.isEmpty), isTrue);
  });
}
