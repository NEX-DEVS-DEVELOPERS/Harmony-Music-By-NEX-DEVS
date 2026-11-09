import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonymusic/utils/smart_shuffle.dart';

class _S {
  _S(this.id, this.artist);
  final String id, artist;
}

void main() {
  final songs = [
    for (var i = 0; i < 40; i++) _S('s$i', 'artist${i % 8}'),
  ];
  String artistOf(_S s) => s.artist;

  test('is a full permutation (every song once, none dropped)', () {
    final out = smartShuffle(songs, artistOf: artistOf, random: Random(1));
    expect(out.length, songs.length);
    expect(out.toSet().length, songs.length);
  });

  test('pins the chosen first song', () {
    final out = smartShuffle(songs,
        artistOf: artistOf, first: songs[17], random: Random(2));
    expect(out.first, songs[17]);
  });

  test('never starts a new cycle with the song that just played', () {
    for (var seed = 0; seed < 300; seed++) {
      final out = smartShuffle(songs,
          artistOf: artistOf, avoidFirst: songs[3], random: Random(seed));
      expect(out.first, isNot(songs[3]));
    }
  });

  test('spreads same-artist songs apart when possible', () {
    for (var seed = 0; seed < 100; seed++) {
      final out = smartShuffle(songs, artistOf: artistOf, random: Random(seed));
      for (var i = 1; i < out.length; i++) {
        expect(out[i].artist == out[i - 1].artist, isFalse,
            reason: 'seed $seed idx $i');
      }
    }
  });

  test('actually random: different seeds give different orders', () {
    final a = smartShuffle(songs, artistOf: artistOf, random: Random(10));
    final b = smartShuffle(songs, artistOf: artistOf, random: Random(11));
    expect(a.map((e) => e.id).join(), isNot(b.map((e) => e.id).join()));
  });

  test('handles tiny / single-artist lists', () {
    expect(smartShuffle<_S>([], artistOf: artistOf), isEmpty);
    final one = [_S('a', 'x')];
    expect(smartShuffle(one, artistOf: artistOf, avoidFirst: one.first), one);
    final same = [for (var i = 0; i < 5; i++) _S('s$i', 'same')];
    expect(smartShuffle(same, artistOf: artistOf).length, 5);
  });

  test('scrambled: songs that were neighbours stay apart', () {
    for (var seed = 0; seed < 200; seed++) {
      final out = smartShuffle(songs, artistOf: artistOf, random: Random(seed));
      for (var i = 1; i < out.length; i++) {
        final a = songs.indexOf(out[i - 1]), b = songs.indexOf(out[i]);
        expect((a - b).abs(), isNot(1), reason: 'seed $seed idx $i');
      }
    }
  });

  test('scrambling keeps the full permutation and the pinned first song', () {
    final out = smartShuffle(songs,
        artistOf: artistOf, first: songs[5], random: Random(3));
    expect(out.first, songs[5]);
    expect(out.toSet().length, songs.length);
  });

  test('orderByIds / restoreOriginalOrder', () {
    final shuffled = smartShuffle(songs, artistOf: artistOf, random: Random(9));
    final ids = shuffled.map((e) => e.id).toList();
    final reordered = orderByIds(songs, ids, (e) => e.id);
    expect(reordered.map((e) => e.id).toList(), ids);

    // new song added while shuffled, one removed
    final extra = _S('new', 'x');
    final current = [...shuffled.where((e) => e.id != 's3'), extra];
    final restored = restoreOriginalOrder(current, songs, (e) => e.id);
    expect(restored.last, extra);
    expect(restored.where((e) => e.id == 's3'), isEmpty);
    final origIds = songs.map((e) => e.id).where((i) => i != 's3').toList();
    expect(restored.take(origIds.length).map((e) => e.id).toList(), origIds);
  });
}
