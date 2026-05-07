import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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

/// 16 kHz mono 16-bit — matches Whisper.cpp ingest (`wav` to file or `pcm16bits` streaming).
class RecordingService extends GetxService {
  final AudioRecorder _recorder = AudioRecorder();

  final isRecording = false.obs;
  final elapsed = Duration.zero.obs;

  String? _activePath;
  Timer? _ticker;
  static const Duration _tick = Duration(milliseconds: 200);

  StreamController<Uint8List>? _pcmController;
  StreamSubscription<Uint8List>? _pcmPlatformSub;

  RandomAccessFile? _streamingRaf;

  /// Leftover from splitting platform chunks on 16-bit sample boundaries (s16le aligned).
  Uint8List _pcmCarry = Uint8List(0);

  bool _streamingMode = false;
  int _streamingDataChunkBytes = 0;

  String? get activePath => _activePath;

  /// Aligned pcm16 mono LE slices (even length). Completes after [stopStreaming] closes the recorder.
  Stream<Uint8List> get pcm16Stream {
    final c = _pcmController;
    if (c == null) {
      throw StateError('pcm16Stream: start streaming recording first.');
    }
    return c.stream;
  }

  bool get isStreamingMode => _streamingMode;

  Future<void> start() async {
    if (_streamingMode) {
      throw StateError('Already in streaming mode; cancel streaming first.');
    }
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

  /// Stream-based capture: pcm16 mono 16 kHz appended to [pcm16Stream], and mirrored to a growable WAV
  /// patched on [stopStreaming] — same path semantics as file mode for backups / diagnostics.
  Future<void> startStreaming() async {
    if (isRecording.value && !_streamingMode) {
      throw StateError('Stop classic recording before starting streaming.');
    }
    if (_streamingMode) return;

    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      throw MicPermissionDeniedException(status.isPermanentlyDenied);
    }

    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/dictation_${DateTime.now().millisecondsSinceEpoch}.wav';

    _pcmCarry = Uint8List(0);
    _streamingDataChunkBytes = 0;

    final f = File(path);
    final raf = await f.open(mode: FileMode.write);
    await raf.writeFrom(_minimalPcmWaveHeaderPlaceholder());
    _streamingRaf = raf;
    _streamingMode = true;
    _pcmController = StreamController<Uint8List>.broadcast(sync: true);

    _activePath = path;
    elapsed.value = Duration.zero;
    isRecording.value = true;

    final raw = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        autoGain: false,
        noiseSuppress: false,
      ),
    );

    final ctrl = _pcmController!;
    _pcmPlatformSub = raw.listen(
      _onStreamingPcmBytes,
      onError: (Object e, StackTrace st) {
        if (!ctrl.isClosed) ctrl.addError(e, st);
      },
      onDone: () {},
    );

    _ticker?.cancel();
    _ticker = Timer.periodic(_tick, (_) {
      elapsed.value += _tick;
    });
  }

  void _onStreamingPcmBytes(Uint8List chunk) {
    if (chunk.isEmpty) return;

    final buf = BytesBuilder(copy: false);
    if (_pcmCarry.isNotEmpty) {
      buf.add(_pcmCarry);
    }
    buf.add(chunk);
    final merged = buf.takeBytes();
    final evenLen = merged.length & ~1;
    if (evenLen <= 0) {
      _pcmCarry = merged;
      return;
    }

    final aligned = merged.length == evenLen
        ? merged
        : Uint8List.sublistView(merged, 0, evenLen);

    if (merged.length != evenLen) {
      _pcmCarry =
          Uint8List.sublistView(merged, evenLen, merged.length);
    } else {
      _pcmCarry = Uint8List(0);
    }

    unawaited(_appendStreamingPcm(aligned));

    final c = _pcmController;
    if (c != null && !c.isClosed) {
      c.add(aligned);
    }
  }

  Future<void> _appendStreamingPcm(Uint8List pcmBytes) async {
    final raf = _streamingRaf;
    if (raf == null) return;
    try {
      await raf.writeFrom(pcmBytes);
      _streamingDataChunkBytes += pcmBytes.length;
    } catch (_) {}
  }

  /// Standard 44-byte LE header; `data` size and RIFF chunk size patched in [stopStreaming].
  Uint8List _minimalPcmWaveHeaderPlaceholder() {
    final bd = ByteData(44);
    bd.setUint8(0, 0x52);
    bd.setUint8(1, 0x49);
    bd.setUint8(2, 0x46);
    bd.setUint8(3, 0x46);
    bd.setUint32(4, 36, Endian.little);
    bd.setUint8(8, 0x57);
    bd.setUint8(9, 0x41);
    bd.setUint8(10, 0x56);
    bd.setUint8(11, 0x45);
    bd.setUint8(12, 0x66);
    bd.setUint8(13, 0x6d);
    bd.setUint8(14, 0x74);
    bd.setUint8(15, 0x20);
    bd.setUint32(16, 16, Endian.little);
    bd.setUint16(20, 1, Endian.little);
    bd.setUint16(22, 1, Endian.little);
    bd.setUint32(24, 16000, Endian.little);
    bd.setUint32(28, 32000, Endian.little);
    bd.setUint16(32, 2, Endian.little);
    bd.setUint16(34, 16, Endian.little);
    bd.setUint8(36, 0x64);
    bd.setUint8(37, 0x61);
    bd.setUint8(38, 0x74);
    bd.setUint8(39, 0x61);
    bd.setUint32(40, 0, Endian.little);
    return bd.buffer.asUint8List();
  }

  Future<void> _patchStreamingWavHeader() async {
    final raf = _streamingRaf;
    if (raf == null) return;

    final dataSize = _streamingDataChunkBytes;
    final riffChunkSize = 36 + dataSize;

    final riffBd = ByteData(4)..setUint32(0, riffChunkSize, Endian.little);
    await raf.setPosition(4);
    await raf.writeFrom(riffBd.buffer.asUint8List());

    final dataBd = ByteData(4)..setUint32(0, dataSize, Endian.little);
    await raf.setPosition(40);
    await raf.writeFrom(dataBd.buffer.asUint8List());

    await raf.close();
    _streamingRaf = null;
  }

  Future<String> stopStreaming() async {
    if (!_streamingMode) {
      throw StateError(
        'RecordingService.stopStreaming() called with no active stream.',
      );
    }
    _ticker?.cancel();
    _ticker = null;

    await _recorder.stop();

    await _pcmPlatformSub?.cancel();
    _pcmPlatformSub = null;

    _pcmCarry = Uint8List(0);

    await _patchStreamingWavHeader();

    isRecording.value = false;
    _streamingMode = false;

    await _pcmController?.close();
    _pcmController = null;

    final path = _activePath!;
    return path;
  }

  Future<String> stop() async {
    if (_streamingMode) {
      throw StateError('Use stopStreaming() while streaming.');
    }
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

    await _pcmPlatformSub?.cancel();
    _pcmPlatformSub = null;

    if (_streamingMode) {
      await _recorder.cancel();
      if (_streamingRaf != null) {
        try {
          await _streamingRaf!.close();
        } catch (_) {}
        _streamingRaf = null;
      }
      await _pcmController?.close();
      _pcmController = null;
      _streamingMode = false;
      _pcmCarry = Uint8List(0);
      isRecording.value = false;
      final path = _activePath;
      _activePath = null;
      elapsed.value = Duration.zero;
      if (path != null) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
      return;
    }

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
    unawaited(_pcmPlatformSub?.cancel());
    _recorder.dispose();
    super.onClose();
  }
}
