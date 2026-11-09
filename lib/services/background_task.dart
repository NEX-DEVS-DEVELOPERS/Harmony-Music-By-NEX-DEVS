import 'dart:core';
import 'dart:isolate';
import 'package:flutter/services.dart';
import 'package:harmonymusic/services/stream_service.dart';

//Not in use for now
// Future<List<String>?> getSongUrlFromPiped(String songId,
//     {String defaultUrl = "https://pipedapi.kavin.rocks"}) async {
//   try {
//     if (songId.substring(0, 4) == "MPED") {
//       songId = songId.substring(4);
//     }
//     final response = await Dio().get("$defaultUrl/streams/$songId");
//     if (response.statusCode == 200) {
//       final audioStream = response.data["audioStreams"] as List;
//       final x =
//           audioStream.firstWhere((item) => (item['itag'].toString() == "251"));

//       final y =
//           audioStream.firstWhere((item) => (item['itag'].toString() == "251"));

//       return [y['url'], x['url']];
//     } else {
//       return null;
//     }
//   } catch (e) {
//     return null;
//   }
// }

Future<Map<String, dynamic>> getStreamInfo(String songId, dynamic token,
    [SendPort? statusPort]) async {
  try {
    if (songId.length > 4 && songId.substring(0, 4) == "MPED") {
      songId = songId.substring(4);
    }
    BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    final playerResponse = await StreamProvider.fetch(songId,
        onStatus: (m) => statusPort?.send(m));
    return playerResponse.hmStreamingData;
  } catch (e) {
    return {
      "playable": false,
      "statusMSG": "Could not get audio (lookup failed: $e)",
    };
  }
}

/// Runs the stream lookup in a background isolate and reports progress over
/// [statusPort].
///
/// IMPORTANT: this is a separate function on purpose. `Isolate.run` copies
/// everything its closure captures; if the closure were created next to the
/// `ReceivePort` (as it used to be inside `checkNGetUrl`) it would capture the
/// ReceivePort too, which cannot be sent to another isolate
/// ("object is unsendable") and made every song lookup fail instantly.
Future<Map<String, dynamic>> runStreamLookup(
    String songId, dynamic token, SendPort statusPort) {
  return Isolate.run(() => getStreamInfo(songId, token, statusPort));
}
