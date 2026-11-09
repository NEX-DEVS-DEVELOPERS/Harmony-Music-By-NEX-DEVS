import 'dart:io';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../utils/helper.dart';
import 'stream_proxy.dart';
import 'stream_sources.dart';

class StreamProvider {
  final bool playable;
  final List<Audio>? audioFormats;
  final String statusMSG;
  StreamProvider(
      {required this.playable, this.audioFormats, this.statusMSG = ""});

  /// Finds a playable audio stream for [videoId], trying several sources in
  /// order and only accepting one that really delivers audio bytes:
  ///  1. YouTube directly (youtube_explode_dart)
  ///  2. public Piped servers   3. public Invidious servers
  ///  4. yt-dlp (desktop only; downloaded once on first need)
  ///
  /// [lazyYtDlp]: for playback on desktop, don't wait for yt-dlp to download
  /// the whole song; return a `ytdlp-stream://<id>` marker that the player
  /// turns into a live stream. Downloads pass false and get a real file.
  /// [skipYtDlp]: used as a fallback when the yt-dlp stream failed.
  static Future<StreamProvider> fetch(String videoId,
      {void Function(String status)? onStatus,
      bool lazyYtDlp = false,
      bool skipYtDlp = false}) async {
    try {
      return await _fetchChain(videoId, onStatus, lazyYtDlp, skipYtDlp);
    } catch (e) {
      // never let an unexpected error escape silently
      printERROR('Stream lookup crashed for $videoId: $e');
      return StreamProvider(
          playable: false, statusMSG: 'Could not get audio (unexpected error: $e)');
    }
  }

  static Future<StreamProvider> _fetchChain(String videoId,
      void Function(String status)? onStatus, bool lazyYtDlp, bool skipYtDlp) async {
    final errors = <String>[];
    void status(String m) => onStatus?.call(m);

    // 0. Desktop: yt-dlp first. YouTube's servers changed in Aug 2026 and the
    // library's default client now gets HTTP 403 on audio; yt-dlp is updated
    // within days of such changes, so it is the most dependable source.
    final desktop = Platform.isWindows || Platform.isLinux;
    if (desktop && !skipYtDlp && lazyYtDlp) {
      // the player starts a live yt-dlp stream when it opens this marker
      return StreamProvider(
          playable: true,
          statusMSG: "OK",
          audioFormats: [YtDlpSource.markerAudio(videoId)]);
    }
    if (desktop && !skipYtDlp) {
      status('Finding the song (first time downloads a ~18 MB helper)...');
      final ytdlp = await YtDlpSource.downloadAudio(videoId, errors).timeout(
          const Duration(seconds: 200), onTimeout: () {
        errors.add('yt-dlp: timed out');
        return null;
      });
      if (ytdlp != null) {
        printINFO('Stream for $videoId from yt-dlp');
        return StreamProvider(
            playable: true, statusMSG: "OK", audioFormats: ytdlp);
      }
      status('That didn\'t work - trying other sources...');
    }

    // 1. YouTube directly
    if (!desktop) status('Finding the song on YouTube...');
    final direct = await _fetchDirect(videoId).timeout(
        const Duration(seconds: 25),
        onTimeout: () => StreamProvider(
            playable: false, statusMSG: 'timed out after 25s'));
    if (direct.playable) {
      final problem = await StreamProxy.instance
          .validate(direct.highestQualityAudio!.url)
          .timeout(const Duration(seconds: 20),
              onTimeout: () => 'stream check timed out');
      if (problem == null) return direct;
      errors.add('YouTube: $problem');
    } else {
      errors.add('YouTube: ${direct.statusMSG}');
    }

    // 2 + 3. public frontends (run at the same time, first working one wins)
    status('YouTube didn\'t work - switching to another source...');
    final frontend = await firstSuccess<List<Audio>>([
      FrontendSources.piped(videoId, errors),
      FrontendSources.invidious(videoId, errors),
    ]).timeout(const Duration(seconds: 25), onTimeout: () {
      errors.add('Piped/Invidious: timed out');
      return null;
    });
    if (frontend != null) {
      printINFO('Stream for $videoId from a Piped/Invidious server');
      return StreamProvider(
          playable: true, statusMSG: "OK", audioFormats: frontend);
    }

    printERROR('All stream sources failed for $videoId: ${errors.join(' | ')}');
    // keep the specific, user-friendly message for network / unplayable cases
    if (!direct.playable &&
        (direct.statusMSG == 'networkError' ||
            direct.statusMSG.contains('purchase') ||
            direct.statusMSG.contains('unavailable'))) {
      return direct;
    }
    final detail = errors.join(' | ');
    return StreamProvider(
        playable: false,
        statusMSG:
            'Could not get audio. ${detail.length > 300 ? '${detail.substring(0, 300)}...' : detail}');
  }

  static Future<StreamProvider> _fetchDirect(String videoId) async {
    final yt = YoutubeExplode();

    try {
      StreamManifest res;
      try {
        // Fast path: skip the extra watch-page request (quicker song start).
        res = await yt.videos.streamsClient
            .getManifest(videoId, requireWatchPage: false);
      } on SocketException {
        rethrow;
      } catch (_) {
        // Fallback: full path (watch page + all default clients).
        res = await yt.videos.streamsClient.getManifest(videoId);
      }
      final audio = res.audioOnly;
      return StreamProvider(
          playable: true,
          statusMSG: "OK",
          audioFormats: audio
              .map((e) => Audio(
                  itag: e.tag,
                  audioCodec:
                      e.audioCodec.contains('mp') ? Codec.mp4a : Codec.opus,
                  bitrate: e.bitrate.bitsPerSecond,
                  duration: 0, // not provided by youtube_explode_dart >= 3
                  loudnessDb: -5.0, // neutral: no volume change
                  url: e.url.toString(),
                  size: e.size.totalBytes))
              .toList());
    } catch (e) {
      printERROR("Stream fetch failed for $videoId: $e");
      if (e is SocketException) {
        return StreamProvider(
          playable: false,
          statusMSG: "networkError",
        );
      } else if (e is VideoUnplayableException) {
        return StreamProvider(
          playable: false,
          statusMSG: e.message.isNotEmpty ? e.message : "Song is unplayable",
        );
      } else if (e is VideoRequiresPurchaseException) {
        return StreamProvider(
          playable: false,
          statusMSG: "Song requires purchase",
        );
      } else if (e is VideoUnavailableException) {
        return StreamProvider(
          playable: false,
          statusMSG: "Song is unavailable",
        );
      } else if (e is YoutubeExplodeException) {
        return StreamProvider(
          playable: false,
          statusMSG: e.message,
        );
      } else {
        return StreamProvider(
          playable: false,
          statusMSG: "Unknown error occurred",
        );
      }
    } finally {
      yt.close();
    }
  }

  Audio? get highestQualityAudio =>
      audioFormats?.lastWhere((item) => item.itag == 251 || item.itag == 140,
          orElse: () => audioFormats!.first);

  Audio? get highestBitrateMp4aAudio =>
      audioFormats?.lastWhere((item) => item.itag == 140 || item.itag == 139,
          orElse: () => audioFormats!.first);

  Audio? get highestBitrateOpusAudio =>
      audioFormats?.lastWhere((item) => item.itag == 251 || item.itag == 250,
          orElse: () => audioFormats!.first);

  Audio? get lowQualityAudio =>
      audioFormats?.lastWhere((item) => item.itag == 249 || item.itag == 139,
          orElse: () => audioFormats!.first);

  Map<String, dynamic> get hmStreamingData {
    return {
      "playable": playable,
      "statusMSG": statusMSG,
      "lowQualityAudio": lowQualityAudio?.toJson(),
      "highQualityAudio": highestQualityAudio?.toJson()
    };
  }
}

class Audio {
  final int itag;
  final Codec audioCodec;
  final int bitrate;
  final int duration;
  final int size;
  final double loudnessDb;
  final String url;

  /// Extra request headers the stream URL needs (yt-dlp provides some).
  final Map<String, String>? headers;
  Audio(
      {this.headers,
      required this.itag,
      required this.audioCodec,
      required this.bitrate,
      required this.duration,
      required this.loudnessDb,
      required this.url,
      required this.size});

  Map<String, dynamic> toJson() => {
        "itag": itag,
        "audioCodec": audioCodec.toString(),
        "bitrate": bitrate,
        "loudnessDb": loudnessDb,
        "url": url,
        "approxDurationMs": duration,
        "size": size,
        if (headers != null) "headers": headers
      };

  factory Audio.fromJson(json) => Audio(
      audioCodec: (json["audioCodec"] as String).contains("mp4a")
          ? Codec.mp4a
          : Codec.opus,
      itag: json['itag'],
      duration: json["approxDurationMs"] ?? 0,
      bitrate: json["bitrate"] ?? 0,
      loudnessDb: (json['loudnessDb'])?.toDouble() ?? 0.0,
      url: json['url'],
      headers: (json['headers'] as Map?)
          ?.map((k, v) => MapEntry(k.toString(), v.toString())),
      size: json["size"] ?? 0);
}

enum Codec { mp4a, opus }
