import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';

/// Holds a durable copy of the last WAV fed to Whisper and exposes playback.
///
/// Temp dictation paths are deleted after transcription; we copy first so you
/// can rehear exactly what reached the native model ingest.
class LastModelAudioSampleService extends GetxService {
  static const String _destFilename = 'last_model_input.wav';

  final AudioPlayer _player = AudioPlayer();

  final hasSample = false.obs;
  final samplePath = RxnString();
  final isPlaying = false.obs;

  StreamSubscription<PlayerState>? _stateSub;

  @override
  void onInit() {
    super.onInit();
    _stateSub = _player.onPlayerStateChanged.listen((s) {
      isPlaying.value = s == PlayerState.playing;
    });
  }

  /// Copies [sourcePath] into app documents so it survives temp cleanup.
  Future<void> captureFromPath(String sourcePath) async {
    final src = File(sourcePath);
    if (!await src.exists()) return;

    await _player.stop();
    final dir = await getApplicationDocumentsDirectory();
    final dest = File('${dir.path}/$_destFilename');
    await src.copy(dest.path);

    samplePath.value = dest.path;
    hasSample.value = true;
  }

  Future<void> togglePlayback() async {
    final path = samplePath.value;
    if (path == null) return;

    final f = File(path);
    if (!await f.exists()) {
      hasSample.value = false;
      samplePath.value = null;
      return;
    }

    if (isPlaying.value) {
      await _player.pause();
    } else {
      final state = _player.state;
      if (state == PlayerState.paused) {
        await _player.resume();
      } else {
        await _player.play(DeviceFileSource(path));
      }
    }
  }

  Future<void> stopPlayback() async {
    await _player.stop();
  }

  @override
  void onClose() {
    unawaited(_stateSub?.cancel());
    _stateSub = null;
    unawaited(_player.dispose());
    super.onClose();
  }
}
