import 'dart:async';
import 'dart:io';

import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

class MicPermissionDeniedException implements Exception {
  MicPermissionDeniedException(this.permanentlyDenied);

  final bool permanentlyDenied;

  @override
  String toString() => permanentlyDenied
      ? 'Microphone permission permanently denied. Enable it in Settings.'
      : 'Microphone permission denied.';
}

/// 16 kHz mono 16-bit PCM WAV — matches Whisper.cpp ingest without transcoding.
class RecordingService extends GetxService {
  final AudioRecorder _recorder = AudioRecorder();

  final isRecording = false.obs;
  final elapsed = Duration.zero.obs;

  String? _activePath;
  Timer? _ticker;
  static const Duration _tick = Duration(milliseconds: 200);

  String? get activePath => _activePath;

  Future<void> start() async {
    if (isRecording.value) return;

    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      throw MicPermissionDeniedException(status.isPermanentlyDenied);
    }

    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/dictation_${DateTime.now().millisecondsSinceEpoch}.wav';

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
        // AGC / WebRTC-style NS can gate or distort long takes for ASR.
        autoGain: false,
        noiseSuppress: false,
      ),
      path: path,
    );

    _activePath = path;
    elapsed.value = Duration.zero;
    isRecording.value = true;

    _ticker?.cancel();
    _ticker = Timer.periodic(_tick, (_) {
      elapsed.value += _tick;
    });
  }

  Future<String> stop() async {
    if (!isRecording.value) {
      throw StateError(
        'RecordingService.stop() called with no active recording.',
      );
    }
    _ticker?.cancel();
    _ticker = null;

    final path = await _recorder.stop();
    isRecording.value = false;

    final finalPath = path ?? _activePath;
    if (finalPath == null) {
      throw StateError('Recorder returned no output path.');
    }
    return finalPath;
  }

  Future<void> cancel() async {
    _ticker?.cancel();
    _ticker = null;

    if (isRecording.value) {
      try {
        await _recorder.cancel();
      } catch (_) {}
      isRecording.value = false;
    }

    final path = _activePath;
    _activePath = null;
    elapsed.value = Duration.zero;
    if (path != null) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  @override
  void onClose() {
    _ticker?.cancel();
    _recorder.dispose();
    super.onClose();
  }
}
