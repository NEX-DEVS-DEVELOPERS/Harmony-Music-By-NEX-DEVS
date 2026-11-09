import 'dart:math';

/// Spotify-style "smart" shuffle.
///
/// * Uniformly random order (Fisher-Yates with a securely seeded [Random]),
///   so every song has the same chance to come anywhere in the queue.
/// * Every song plays once before anything repeats (it returns a full
///   permutation that the player walks through).
/// * Songs by the same artist are spread apart where the list allows it,
///   instead of clustering back to back.
/// * [first] (e.g. the song you just clicked) is pinned to the front.
/// * [avoidFirst] (e.g. the song that just finished in the previous cycle) is
///   never used as the first song of the new order, so a new cycle never
///   starts by repeating what you just heard.
List<T> smartShuffle<T>(
  Iterable<T> items, {
  required String Function(T item) artistOf,
  T? first,
  T? avoidFirst,
  Random? random,
}) {
  final rnd = random ?? Random.secure();
  final pool = items.toList();

  T? pinned;
  if (first != null) {
    final i = pool.indexOf(first);
    if (i != -1) pinned = pool.removeAt(i);
  }

  // Fisher-Yates
  for (var i = pool.length - 1; i > 0; i--) {
    final j = rnd.nextInt(i + 1);
    final tmp = pool[i];
    pool[i] = pool[j];
    pool[j] = tmp;
  }

  // Never start a new cycle with the song that just played.
  if (pinned == null &&
      avoidFirst != null &&
      pool.length > 1 &&
      pool.first == avoidFirst) {
    final swapWith = 1 + rnd.nextInt(pool.length - 1);
    final tmp = pool[0];
    pool[0] = pool[swapWith];
    pool[swapWith] = tmp;
  }

  // Spread same-artist songs. Pick each next song at random, but
  //  * never the same artist as the previous song (when avoidable),
  //  * weighted by how many songs each artist has left, and
  //  * if one artist has so many left that it could no longer be separated,
  //    take it now (classic "rearrange so no two neighbours match" rule).
  final result = <T>[];
  if (pinned != null) result.add(pinned);
  String? lastArtist = pinned != null ? artistOf(pinned) : null;
  final remaining = List<T>.of(pool);
  final counts = <String, int>{};
  for (final e in remaining) {
    counts[artistOf(e)] = (counts[artistOf(e)] ?? 0) + 1;
  }

  while (remaining.isNotEmpty) {
    final n = remaining.length;
    // candidate artists (different from the previous one when possible)
    var candidates = counts.entries
        .where((e) => e.value > 0 && e.key != lastArtist)
        .toList();
    if (candidates.isEmpty) {
      candidates = counts.entries.where((e) => e.value > 0).toList();
    }
    // forced pick: an artist whose remaining songs need every other slot
    String? chosenArtist;
    for (final c in candidates) {
      if (c.value * 2 > n) {
        chosenArtist = c.key;
        break;
      }
    }
    if (chosenArtist == null) {
      // weighted random by remaining count
      final total = candidates.fold<int>(0, (a, c) => a + c.value);
      var roll = rnd.nextInt(total);
      for (final c in candidates) {
        if (roll < c.value) {
          chosenArtist = c.key;
          break;
        }
        roll -= c.value;
      }
    }
    // first song of that artist in the (already shuffled) order
    var pick = remaining.indexWhere((e) => artistOf(e) == chosenArtist);
    if (pick == -1) pick = 0;

    // Honour avoidFirst for the very first slot.
    if (result.isEmpty && avoidFirst != null && remaining.length > 1) {
      if (remaining[pick] == avoidFirst) {
        final k = remaining.indexWhere((e) => e != avoidFirst);
        if (k != -1) pick = k;
      }
    }

    final item = remaining.removeAt(pick);
    counts[artistOf(item)] = counts[artistOf(item)]! - 1;
    result.add(item);
    lastArtist = artistOf(item);
  }
  return result;
}
