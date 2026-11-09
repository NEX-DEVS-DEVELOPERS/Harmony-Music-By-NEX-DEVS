import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '/services/music_service.dart';
import '/services/song_recognition_service.dart';
import '/ui/player/player_controller.dart';
import 'common_dialog_widget.dart';

enum _Phase { needToken, ready, listening, identifying, found, notFound, error }

/// "Listen & identify" dialog: records the music around you, finds the song,
/// searches it and starts playing it from the part you were listening to.
class RecognizeSongDialog extends StatefulWidget {
  const RecognizeSongDialog({super.key});

  @override
  State<RecognizeSongDialog> createState() => _RecognizeSongDialogState();
}

class _RecognizeSongDialogState extends State<RecognizeSongDialog> {
  final _service = SongRecognitionService();
  final _tokenController = TextEditingController();
  _Phase _phase = _Phase.ready;
  String _message = '';

  @override
  void initState() {
    super.initState();
    if (SongRecognitionService.apiToken == null) {
      _phase = _Phase.needToken;
    } else {
      // start listening straight away, like Shazam
      WidgetsBinding.instance.addPostFrameCallback((_) => _listen());
    }
  }

  @override
  void dispose() {
    _service.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _saveToken() async {
    if (_tokenController.text.trim().isEmpty) return;
    await SongRecognitionService.saveApiToken(_tokenController.text);
    _listen();
  }

  Future<void> _listen() async {
    setState(() => _phase = _Phase.listening);
    try {
      final song = await _service.listenAndIdentify(
        onListeningDone: () {
          if (mounted) setState(() => _phase = _Phase.identifying);
        },
      );
      if (!mounted) return;
      if (song == null || song.title.isEmpty) {
        setState(() => _phase = _Phase.notFound);
        return;
      }
      setState(() {
        _phase = _Phase.found;
        _message = '${song.title} - ${song.artist}';
      });
      await _playRecognized(song);
      if (mounted) Navigator.of(context).pop();
    } on RecognitionException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _message = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _message = e.toString();
      });
    }
  }

  /// Search the recognised song, play it and jump to where the music is now.
  Future<void> _playRecognized(RecognizedSong song) async {
    final results =
        await Get.find<MusicServices>().search('${song.title} ${song.artist}');
    final candidates = <MediaItem>[
      ...((results['Songs'] as List?) ?? const []).whereType<MediaItem>(),
      ...((results['Videos'] as List?) ?? const []).whereType<MediaItem>(),
    ];
    if (candidates.isEmpty) {
      throw RecognitionException(
          'Found "${song.title}" but could not find it to play.');
    }
    final player = Get.find<PlayerController>();
    await player.playPlayListSong([candidates.first], 0);

    // wait until the song is loaded, then jump to the position being heard
    for (var i = 0; i < 60; i++) {
      if (player.progressBarStatus.value.total > Duration.zero) break;
      await Future.delayed(const Duration(milliseconds: 250));
    }
    player.seek(song.currentPosition);
  }

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme;
    Widget body;
    switch (_phase) {
      case _Phase.needToken:
        body = Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Song recognition needs a free AudD API token.',
              style: style.titleSmall, textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text('Get one at dashboard.audd.io, then paste it here. '
              'It is stored only on this device.',
              style: style.bodySmall, textAlign: TextAlign.center),
          const SizedBox(height: 14),
          TextField(
            controller: _tokenController,
            decoration: const InputDecoration(hintText: 'AudD API token'),
            onSubmitted: (_) => _saveToken(),
          ),
          const SizedBox(height: 14),
          ElevatedButton(onPressed: _saveToken, child: const Text('Save & listen')),
        ]);
      case _Phase.ready:
      case _Phase.listening:
        body = Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.mic, size: 56),
          const SizedBox(height: 12),
          Text('Listening...', style: style.titleMedium),
          const SizedBox(height: 6),
          Text('Hold your device near the music', style: style.bodySmall),
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
        ]);
      case _Phase.identifying:
        body = Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text('Identifying song...', style: style.titleMedium),
        ]);
      case _Phase.found:
        body = Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.music_note, size: 48),
          const SizedBox(height: 10),
          Text(_message, style: style.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text('Playing from where you were listening...',
              style: style.bodySmall),
        ]);
      case _Phase.notFound:
        body = Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Could not recognise that song.', style: style.titleMedium),
          const SizedBox(height: 8),
          Text(
              'The microphone heard sound (${_service.lastMaxLevelDb.toStringAsFixed(0)} dB), '
              'but the song was not matched. Play it louder / closer to the '
              'microphone, avoid talking over it, and try again.',
              style: style.bodySmall,
              textAlign: TextAlign.center),
          const SizedBox(height: 14),
          ElevatedButton(onPressed: _listen, child: const Text('Try again')),
        ]);
      case _Phase.error:
        body = Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_message, style: style.titleSmall, textAlign: TextAlign.center),
          const SizedBox(height: 14),
          Wrap(spacing: 10, children: [
            ElevatedButton(onPressed: _listen, child: const Text('Try again')),
            TextButton(
                onPressed: () => setState(() => _phase = _Phase.needToken),
                child: const Text('Change token')),
          ]),
        ]);
    }
    return CommonDialog(
      maxWidth: 420,
      child: Padding(padding: const EdgeInsets.all(24), child: body),
    );
  }
}
