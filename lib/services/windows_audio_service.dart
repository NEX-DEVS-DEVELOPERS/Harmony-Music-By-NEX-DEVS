import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:harmonymusic/utils/helper.dart';
import 'package:smtc_windows/smtc_windows.dart';

import '../ui/player/player_controller.dart';

class WindowsAudioService extends GetxService {
  late SMTCWindows smtc;
  final playerController = Get.find<PlayerController>();

  static const _mediaKeys = MethodChannel('harmony/media_keys');

  @override
  void onInit() {
    _initService();
    _initMediaKeys();
    super.onInit();
  }

  /// Claim the global media keys (headset buttons etc.) for Harmony so other
  /// apps, e.g. a browser playing a video, don't take them.
  void _initMediaKeys() {
    _mediaKeys.setMethodCallHandler((call) async {
      if (call.method != 'onKey') return;
      switch (call.arguments) {
        case 'playPause':
          playerController.playPause();
          break;
        case 'next':
          playerController.next();
          break;
        case 'previous':
          playerController.prev();
          break;
        case 'stop':
          playerController.pause();
          break;
      }
    });
    final enabled = Hive.box('AppPrefs').get('captureMediaKeys') ?? true;
    setMediaKeysCapture(enabled);
  }

  Future<void> setMediaKeysCapture(bool enable) async {
    try {
      final ok = await _mediaKeys.invokeMethod<bool>(enable ? 'enable' : 'disable');
      if (enable && ok != true) {
        printERROR("Some media keys are already owned by another app");
      }
    } catch (e) {
      printERROR("Media key capture failed: $e");
    }
  }

  _initService() {
    smtc = SMTCWindows(
      enabled: false,
    );
    try {
      smtc.buttonPressStream.listen((event) {
        switch (event) {
          case PressedButton.play:
            playerController.play();
            smtc.setPlaybackStatus(PlaybackStatus.Playing);
            break;
          case PressedButton.pause:
            playerController.pause();
            smtc.setPlaybackStatus(PlaybackStatus.Paused);
            break;
          case PressedButton.next:
            playerController.next();
            break;
          case PressedButton.previous:
            playerController.prev();
            break;

          default:
            break;
        }
      });
    } catch (e) {
      printERROR("Error: $e");
    }

    playerController.buttonState.listen((state) {
      switch (state) {
        case PlayButtonState.playing:
          smtc.setPlaybackStatus(PlaybackStatus.Playing);
          break;
        case PlayButtonState.paused:
          smtc.setPlaybackStatus(PlaybackStatus.Paused);
          break;
        case PlayButtonState.loading:
          smtc.setPlaybackStatus(PlaybackStatus.Paused);
          break;
      }
    });

    playerController.progressBarStatus.listen((status) {
      smtc.setPosition(status.current);
    });

    playerController.currentSong.listen((song) async {
      if (song != null) {
        if (!smtc.enabled) await smtc.enableSmtc();
        await smtc.updateMetadata(
          MusicMetadata(
            title: song.title,
            album: song.album,
            albumArtist: song.artist,
            artist: song.artist,
            thumbnail: song.artUri.toString(),
          ),
        );
        smtc.setEndTime(playerController.progressBarStatus.value.total);
      }
    });
  }

  @override
  void onClose() {
    setMediaKeysCapture(false);
    smtc.clearMetadata();
    smtc.disableSmtc();
    smtc.dispose();
    super.onClose();
  }
}
