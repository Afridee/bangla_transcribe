import 'dart:async';
import 'dart:convert';
import 'dart:developer' show log;
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
// ignore: implementation_imports
import 'package:whisper_ggml/src/models/requests/transcribe_request_dto.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

import 'transcription_resource_monitor.dart';

class WhisperVariant {
  const WhisperVariant({
    required this.id,
    required this.label,
    required this.url,
    required this.filename,
    required this.approxSizeMB,
    required this.minSizeBytes,
    this.expectedSha256,
    this.lockedLanguage,
  });

  final String id;
  final String label;
  final String url;
  final String filename;
  final int approxSizeMB;
  final int minSizeBytes;
  final String? expectedSha256;
  final String? lockedLanguage;
}

/// Fine-tuned Bangla Whisper-tiny (ehzawad/whisper-tiny-bn) Q8_0 GGML for on-device use.
const WhisperVariant kBanglaWhisper = WhisperVariant(
  id: 'whisper-tiny-bn-q8_0',
  label: 'Bangla (whisper-tiny-bn, q8_0)',
  url:
      'https://huggingface.co/afridee/whisper-tiny-bn-ggml/resolve/main/ggml-whisper-tiny-bn-q8_0.bin',
  filename: 'ggml-whisper-tiny-bn-q8_0.bin',
  approxSizeMB: 42,
  minSizeBytes: 35 * 1024 * 1024,
  expectedSha256:
      'b834f768f83ab726881a1f68a6d8592c928c8be7b7422a9cf351e991a36370aa',
  lockedLanguage: 'bn',
);

class TranscriptionInputTooLongException implements Exception {
  TranscriptionInputTooLongException(this.maxDurationSeconds);

  final int maxDurationSeconds;

  @override
  String toString() {
    final m = (maxDurationSeconds / 60).round();
    return 'Recording is too long for on-device transcription '
        '(about $m minutes max). Try a shorter take.';
  }
}

typedef _WhisperGgmlRequestNative = Pointer<Utf8> Function(Pointer<Utf8> body);

class TranscriptionService extends GetxService {
  final isInstalled = false.obs;
  final isReady = false.obs;
  final downloadPct = 0.obs;
  final lastError = RxnString();

  static const int _maxTranscribeDurationSeconds = 45 * 60;

  /// Long clips are split into overlapping windows (short passes decode more reliably for this model).
  static const int _pcmSampleRate = 16000;
  static const int _chunkWindowSamples =
      8 * _pcmSampleRate; // 8 s per Whisper call
  static const int _chunkHopSamples =
      6 * _pcmSampleRate; // 2 s overlap between consecutive windows

  static const int _pcmBytesPerSample = 2;
  static int get _maxRecordedSamples =>
      _maxTranscribeDurationSeconds * _pcmSampleRate;
  static const double _pipelinedBurstLogThresholdSec = 14.0;

  static const MethodChannel _thermalHeadroomChannel = MethodChannel(
    'bangla_transcribe/thermal_headroom',
  );

  static int _whisperThreadCountBase(int nProcs) {
    if (nProcs <= 2) return 1;
    if (nProcs <= 4) return 2;
    return 3;
  }

  static Future<bool> _thermalAllowsExtraThreads() async {
    if (!(Platform.isAndroid || Platform.isIOS)) return false;
    try {
      final v = await _thermalHeadroomChannel.invokeMethod<Object?>(
        'thermalHeadroomForWhisper',
      );
      return v == true;
    } catch (_) {
      return false;
    }
  }

  static Future<int> _resolveWhisperThreadCount() async {
    final n = Platform.numberOfProcessors;
    final base = _whisperThreadCountBase(n);
    if (!await _thermalAllowsExtraThreads()) return base;
    final maxSuggested = math.min(n, 6);
    return base < maxSuggested ? base + 1 : base;
  }

  @override
  void onInit() {
    super.onInit();
    unawaited(_refreshInstalled());
  }

  Future<void> _refreshInstalled() async {
    final path = await _pathFor(kBanglaWhisper);
    isInstalled.value = await _isUsable(File(path), kBanglaWhisper);
    downloadPct.value = isInstalled.value ? 100 : 0;
  }

  Future<TranscriptionService> ensureInstalled({
    void Function(double)? onProgress,
  }) async {
    final variant = kBanglaWhisper;
    try {
      lastError.value = null;
      final targetPath = await _pathFor(variant);
      final target = File(targetPath);

      if (await _isUsable(target, variant)) {
        if (variant.expectedSha256 != null) {
          final ok = await _verifySha256(target, variant.expectedSha256!);
          if (!ok) {
            await target.delete();
          } else {
            downloadPct.value = 100;
            isInstalled.value = true;
            return this;
          }
        } else {
          downloadPct.value = 100;
          isInstalled.value = true;
          return this;
        }
      }

      await _downloadStreaming(
        Uri.parse(variant.url),
        target,
        variant,
        onProgress,
      );

      if (variant.expectedSha256 != null) {
        final ok = await _verifySha256(target, variant.expectedSha256!);
        if (!ok) {
          await target.delete().catchError((_) => target);
          throw const FormatException(
            'Whisper model failed sha256 verification. '
            'The download may be corrupt; please try again.',
          );
        }
      }

      isInstalled.value = true;
      return this;
    } catch (e, st) {
      lastError.value = e.toString();
      log(
        'TranscriptionService.ensureInstalled failed (${variant.id})',
        name: 'TranscriptionService',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }

  Future<TranscriptionService> warmup() async {
    final variant = kBanglaWhisper;
    final path = await _pathFor(variant);
    if (!await _isUsable(File(path), variant)) {
      throw StateError(
        'TranscriptionService.warmup() called before ensureInstalled() '
        'for ${variant.id}.',
      );
    }
    isReady.value = true;
    return this;
  }

  Future<String> transcribeFile(
    String path, {
    String? initialPrompt,
  }) async {
    final variant = kBanglaWhisper;
    final modelPath = await _pathFor(variant);
    final lang = variant.lockedLanguage ?? 'bn';

    final file = File(path);
    if (!await file.exists()) {
      throw StateError('Audio file not found: $path');
    }

    final totalSeconds = await _wavPlaybackSeconds(file);
    if (totalSeconds > _maxTranscribeDurationSeconds) {
      throw TranscriptionInputTooLongException(_maxTranscribeDurationSeconds);
    }

    final threads = await _resolveWhisperThreadCount();
    final monitor = Get.find<TranscriptionResourceMonitorService>();
    await _logWavLevelDiagnostics(file, nominalSeconds: totalSeconds);

    final response = await monitor.collectDuring(
      audioDurationSeconds: totalSeconds.toDouble(),
      whisperThreads: threads,
      work: () => _transcribePipeline(
        path,
        lang: lang,
        modelPath: modelPath,
        initialPrompt: initialPrompt,
        threads: threads,
      ),
    );
    final cleaned = _clampAndSanitizeResponse(
      response,
      totalDurationMs: totalSeconds * 1000,
    );
    _logWhisperSegments(cleaned, modelId: variant.id);
    final text = cleaned.text.trim();
    _logTranscript(
      text,
      audioSeconds: totalSeconds,
      modelId: variant.id,
    );
    return text;
  }

  LiveTranscriptionSession beginLiveTranscription({
    required void Function(String merged) onPartial,
    String? initialPrompt,
  }) {
    return LiveTranscriptionSession._(
      this,
      onPartial: onPartial,
      initialPrompt: initialPrompt,
    );
  }

  /// Helps tell “empty / gated start” (mic path) from “model collapsed” (Whisper path).
  Future<void> _logWavLevelDiagnostics(
    File f, {
    required int nominalSeconds,
  }) async {
    final pcm = await _readWavPcm16Mono(f);
    if (pcm == null || pcm.isEmpty) {
      log(
        'wav_levels nominal_sec=$nominalSeconds samples=0 (could not read data)',
        name: 'TranscriptionService',
      );
      return;
    }
    final n = pcm.length;
    final third = math.max(1, n ~/ 3);
    double rmsWindow(int start, int len) {
      final end = math.min(start + len, n);
      if (end <= start) return 0;
      var sum = 0.0;
      for (var i = start; i < end; i++) {
        final x = pcm[i] / 32768.0;
        sum += x * x;
      }
      return math.sqrt(sum / (end - start));
    }

    int maxAbsWindow(int start, int len) {
      final end = math.min(start + len, n);
      var m = 0;
      for (var i = start; i < end; i++) {
        final a = pcm[i].abs();
        if (a > m) m = a;
      }
      return m;
    }

    final rms0 = rmsWindow(0, third);
    final rms1 = rmsWindow(third, third);
    final rms2 = rmsWindow(2 * third, n - 2 * third);
    final mx0 = maxAbsWindow(0, third);
    final mx1 = maxAbsWindow(third, third);
    final mx2 = maxAbsWindow(2 * third, n - 2 * third);

    log(
      'wav_levels nominal_sec=$nominalSeconds samples=$n '
      'rms_thirds=${rms0.toStringAsFixed(4)},${rms1.toStringAsFixed(4)},${rms2.toStringAsFixed(4)} '
      'maxAbs_thirds=$mx0,$mx1,$mx2',
      name: 'TranscriptionService',
    );
  }

  void _logWhisperSegments(WhisperTranscribeResponse response, {required String modelId}) {
    final segs = response.segments;
    if (segs == null || segs.isEmpty) {
      log(
        'whisper_segments model=$modelId count=0 (no timestamp payload)',
        name: 'TranscriptionService',
      );
      return;
    }
    final buf = StringBuffer('whisper_segments model=$modelId count=${segs.length}\n');
    for (var i = 0; i < segs.length; i++) {
      final s = segs[i];
      final t0 = s.fromTs.inMilliseconds;
      final t1 = s.toTs.inMilliseconds;
      final snippet = s.text.replaceAll('\n', ' ').trim();
      final clip = snippet.length > 120 ? '${snippet.substring(0, 120)}…' : snippet;
      buf.writeln('#$i ${t0}ms→${t1}ms len=${snippet.runes.length}: $clip');
    }
    log(buf.toString().trimRight(), name: 'TranscriptionService');
  }

  /// Multi-line log so the Bangla text isn't truncated by IDE log viewers.
  void _logTranscript(
    String text, {
    required int audioSeconds,
    required String modelId,
  }) {
    final codePointCount = text.runes.length;
    final words = _wordCount(text);
    log(
      'last_transcript model=$modelId audio_sec=$audioSeconds chars=$codePointCount words=$words\n'
      '----- BEGIN TRANSCRIPT -----\n'
      '$text\n'
      '----- END TRANSCRIPT -----',
      name: 'TranscriptionService',
    );
  }

  static int _wordCount(String text) {
    var n = 0;
    var inWord = false;
    for (final r in text.runes) {
      final isSpace = r == 0x20 ||
          r == 0x09 ||
          r == 0x0A ||
          r == 0x0D ||
          r == 0x00A0;
      if (isSpace) {
        inWord = false;
      } else if (!inWord) {
        inWord = true;
        n++;
      }
    }
    return n;
  }

  Future<WhisperTranscribeResponse> _transcribePipeline(
    String audioPath, {
    required String lang,
    required String modelPath,
    required int threads,
    String? initialPrompt,
  }) async {
    final f = File(audioPath);
    final nativeReady = await _wavIsWhisperNativeReady(f);
    if (!nativeReady) {
      return _transcribeOneFile(
        audioPath,
        lang: lang,
        modelPath: modelPath,
        threads: threads,
        initialPrompt: initialPrompt,
      );
    }

    final pcm = await _readWavPcm16Mono(f);
    if (pcm == null || pcm.length <= _chunkWindowSamples) {
      return _transcribeOneFile(
        audioPath,
        lang: lang,
        modelPath: modelPath,
        threads: threads,
        initialPrompt: initialPrompt,
      );
    }

    return _transcribeChunkedPcm(
      pcm,
      lang: lang,
      modelPath: modelPath,
      threads: threads,
      initialPrompt: initialPrompt,
    );
  }

  /// Splits mono PCM into overlapping ~8 s WAV slices; merges text with rune-safe overlap trim.
  Future<WhisperTranscribeResponse> _transcribeChunkedPcm(
    Int16List fullPcm, {
    required String lang,
    required String modelPath,
    required int threads,
    String? initialPrompt,
  }) async {
    final windows = <({int start, Int16List slice})>[];
    var start = 0;
    while (start < fullPcm.length) {
      final end = math.min(start + _chunkWindowSamples, fullPcm.length);
      if (end > start) {
        windows.add((start: start, slice: fullPcm.sublist(start, end)));
      }
      if (end >= fullPcm.length) break;
      start += _chunkHopSamples;
    }

    log(
      'chunked_transcribe total_samples=${fullPcm.length} (~${fullPcm.length / _pcmSampleRate}s) '
      'windows=${windows.length} len_s=${_chunkWindowSamples / _pcmSampleRate} '
      'hop_s=${_chunkHopSamples / _pcmSampleRate} overlap_s=${(_chunkWindowSamples - _chunkHopSamples) / _pcmSampleRate}',
      name: 'TranscriptionService',
    );

    final dir = await getTemporaryDirectory();
    final session = DateTime.now().microsecondsSinceEpoch;
    final mergedSegs = <WhisperTranscribeSegment>[];

    var mergedText = '';
    for (var chunkIx = 0; chunkIx < windows.length; chunkIx++) {
      final w = windows[chunkIx];
      final wavPath = '${dir.path}/bangla_chunk_${session}_$chunkIx.wav';
      final tmp = File(wavPath);
      await tmp.writeAsBytes(_wavFromPcm16Mono(w.slice));
      try {
        final resp = await _transcribeOneFile(
          wavPath,
          lang: lang,
          modelPath: modelPath,
          threads: threads,
          initialPrompt: chunkIx == 0 ? initialPrompt : null,
        );
        final t = resp.text.trim();
        final segCount = resp.segments?.length ?? 0;
        final pcmEnd = w.start + w.slice.length;
        final durMs = (w.slice.length * 1000 / _pcmSampleRate).round();
        log(
          'chunk_result ix=$chunkIx '
          'pcm=${w.start}..$pcmEnd (~${(durMs / 1000).toStringAsFixed(2)}s) '
          'empty=${t.isEmpty} runes=${t.runes.length} words=${_wordCount(t)} '
          'segments=$segCount '
          'snippet=${_oneLineLogSnippet(t)}',
          name: 'TranscriptionService',
        );

        mergedText = mergedText.isEmpty
            ? t
            : _mergeOverlappingChunkText(mergedText, t);

        final offMs = w.start * 1000 ~/ _pcmSampleRate;
        final segs = resp.segments;
        if (segs != null) {
          for (final s in segs) {
            mergedSegs.add(
              WhisperTranscribeSegment(
                fromTs: Duration(
                  milliseconds: s.fromTs.inMilliseconds + offMs,
                ),
                toTs: Duration(
                  milliseconds: s.toTs.inMilliseconds + offMs,
                ),
                text: s.text,
              ),
            );
          }
        }
      } finally {
        await _deleteIfExists(tmp);
      }
    }

    return WhisperTranscribeResponse(
      type: 'transcribe',
      text: mergedText,
      segments: mergedSegs.isEmpty ? null : mergedSegs,
    );
  }

  /// Minimal PCM WAV (16 kHz mono s16le) for temp chunk files.
  Uint8List _wavFromPcm16Mono(Int16List pcm, {int sampleRate = _pcmSampleRate}) {
    final n = pcm.length;
    final dataSize = n * 2;
    final out = Uint8List(44 + dataSize);
    final bd = ByteData.sublistView(out);

    out.setAll(0, [0x52, 0x49, 0x46, 0x46]);
    bd.setUint32(4, 36 + dataSize, Endian.little);
    out.setAll(8, [0x57, 0x41, 0x56, 0x45]);
    out.setAll(12, [0x66, 0x6d, 0x74, 0x20]);
    bd.setUint32(16, 16, Endian.little);
    bd.setUint16(20, 1, Endian.little);
    bd.setUint16(22, 1, Endian.little);
    bd.setUint32(24, sampleRate, Endian.little);
    bd.setUint32(28, sampleRate * 2, Endian.little);
    bd.setUint16(32, 2, Endian.little);
    bd.setUint16(34, 16, Endian.little);
    out.setAll(36, [0x64, 0x61, 0x74, 0x61]);
    bd.setUint32(40, dataSize, Endian.little);

    for (var i = 0; i < n; i++) {
      bd.setInt16(44 + i * 2, pcm[i], Endian.little);
    }
    return out;
  }

  /// Drops duplicate prefix of [nextChunk] when it repeats a suffix of [accumulated] (overlap stitch).
  String _mergeOverlappingChunkText(String accumulated, String nextChunk) {
    final a = accumulated.trimRight();
    final b = nextChunk.trimLeft();
    if (b.isEmpty) return a;
    if (a.isEmpty) return b;

    final ar = a.runes.toList();
    final br = b.runes.toList();
    final maxK = math.min(ar.length, br.length);
    const minOverlapRunes = 3;
    for (var k = maxK; k >= minOverlapRunes; k--) {
      var match = true;
      for (var i = 0; i < k; i++) {
        if (ar[ar.length - k + i] != br[i]) {
          match = false;
          break;
        }
      }
      if (match) {
        final tail = br.sublist(k);
        return a + String.fromCharCodes(tail);
      }
    }
    return '$a $b';
  }

  /// Single-line preview for chunk debug logs (rune-safe cap).
  String _oneLineLogSnippet(String s, {int maxRunes = 96}) {
    final folded = s
        .replaceAll('\n', ' ')
        .replaceAll('\r', ' ')
        .replaceAll('\t', ' ')
        .trim();
    final collapsed = folded.split(' ').where((w) => w.isNotEmpty).join(' ');
    final r = collapsed.runes.toList();
    if (r.length <= maxRunes) return collapsed;
    return '${String.fromCharCodes(r.sublist(0, maxRunes))}…';
  }

  /// U+FFFD often appears at bounds from JSON / truncated UTF-8; trim for display and logs.
  String _stripReplacementCharArtifacts(String s) {
    final r = s.runes.toList();
    var a = 0;
    while (a < r.length && r[a] == 0xFFFD) {
      a++;
    }
    var b = r.length;
    while (b > a && r[b - 1] == 0xFFFD) {
      b--;
    }
    if (a == 0 && b == r.length) return s;
    return String.fromCharCodes(r.sublist(a, b));
  }

  /// Whisper timestamp units can overshoot short tails; keep segments within real clip length.
  WhisperTranscribeResponse _clampAndSanitizeResponse(
    WhisperTranscribeResponse r, {
    required int totalDurationMs,
  }) {
    final text = _stripReplacementCharArtifacts(r.text.trim());
    final segs = r.segments;
    if (segs == null || segs.isEmpty) {
      return WhisperTranscribeResponse(type: r.type, text: text, segments: null);
    }
    final out = <WhisperTranscribeSegment>[];
    for (final s in segs) {
      var from = s.fromTs.inMilliseconds.clamp(0, totalDurationMs);
      var to = s.toTs.inMilliseconds.clamp(0, totalDurationMs);
      if (to < from) to = from;
      out.add(
        WhisperTranscribeSegment(
          fromTs: Duration(milliseconds: from),
          toTs: Duration(milliseconds: to),
          text: _stripReplacementCharArtifacts(s.text),
        ),
      );
    }
    return WhisperTranscribeResponse(type: r.type, text: text, segments: out);
  }

  Future<WhisperTranscribeResponse> _transcribeOneFile(
    String audioPath, {
    required String lang,
    required String modelPath,
    required int threads,
    String? initialPrompt,
  }) async {
    final f = File(audioPath);
    final skipFfmpeg = await _wavIsWhisperNativeReady(f);
    try {
      if (skipFfmpeg) {
        final dto = TranscribeRequestDto.fromTranscribeRequest(
          TranscribeRequest(
            audio: audioPath,
            language: lang,
            isTranslate: false,
            // Per-segment times in JSON for logging; concatenated text unchanged.
            isNoTimestamps: false,
            splitOnWord: false,
            isRealtime: false,
            speedUp: false,
            threads: threads,
          ),
          modelPath,
        );
        final result = await _whisperNativeRequest(
          dto,
          initialPrompt: initialPrompt,
        );
        if (result['text'] == null) {
          throw Exception(result['message'] ?? 'Whisper failed');
        }
        return WhisperTranscribeResponse.fromJson(result);
      }

      final whisper = Whisper(model: WhisperModel.tiny);
      final response = await whisper.transcribe(
        transcribeRequest: TranscribeRequest(
          audio: audioPath,
          language: lang,
          isTranslate: false,
          isNoTimestamps: false,
          splitOnWord: false,
          isRealtime: false,
          speedUp: false,
          threads: threads,
        ),
        modelPath: modelPath,
      );
      return response;
    } finally {
      if (!skipFfmpeg) {
        await _deleteWhisperConvertSidecar(audioPath);
      }
    }
  }

  Future<Map<String, dynamic>> _whisperNativeRequest(
    TranscribeRequestDto dto, {
    String? initialPrompt,
  }) {
    final Map<String, dynamic> map =
        json.decode(dto.toRequestString()) as Map<String, dynamic>;
    if (initialPrompt != null && initialPrompt.trim().isNotEmpty) {
      map['prompt'] = initialPrompt.trim();
    }
    final payload = json.encode(map);
    return Isolate.run(() async {
      final data = payload.toNativeUtf8();
      final lib = Platform.isAndroid
          ? DynamicLibrary.open('libwhisper.so')
          : DynamicLibrary.process();
      final native = lib.lookupFunction<
          _WhisperGgmlRequestNative,
          _WhisperGgmlRequestNative>('request');
      final resPtr = native.call(data);
      final result =
          json.decode(resPtr.toDartString()) as Map<String, dynamic>;
      malloc.free(data);
      return result;
    });
  }

  Future<void> _deleteIfExists(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<void> _deleteWhisperConvertSidecar(String audioPath) async {
    await _deleteIfExists(File('$audioPath.wav'));
  }

  Future<bool> _wavIsWhisperNativeReady(File f) async {
    final fmt = await _readWavPcmFmt(f);
    if (fmt == null) return false;
    return fmt.sampleRate == 16000 &&
        fmt.numChannels == 1 &&
        fmt.bitsPerSample == 16 &&
        fmt.audioFormat == 1;
  }

  Future<_WavPcmFmt?> _readWavPcmFmt(File f) async {
    RandomAccessFile? raf;
    try {
      raf = await f.open(mode: FileMode.read);
      final fileLen = await raf.length();
      if (fileLen < 12) return null;

      await raf.setPosition(0);
      final head = await raf.read(12);
      if (head.length < 12) return null;
      if (String.fromCharCodes(head.sublist(0, 4)) != 'RIFF') return null;
      if (String.fromCharCodes(head.sublist(8, 12)) != 'WAVE') return null;

      var pos = 12;
      while (pos + 8 <= fileLen) {
        await raf.setPosition(pos);
        final idBytes = await raf.read(4);
        final sizeBytes = await raf.read(4);
        if (idBytes.length < 4 || sizeBytes.length < 4) return null;
        final chunkId = String.fromCharCodes(idBytes);
        final chunkSize = ByteData.sublistView(
          Uint8List.fromList(sizeBytes),
        ).getUint32(0, Endian.little);
        final payloadStart = pos + 8;

        if (chunkId == 'fmt ') {
          await raf.setPosition(payloadStart);
          final n = math.min(chunkSize, 24);
          final raw = await raf.read(n);
          if (raw.length < 16) return null;
          final bd = ByteData.sublistView(Uint8List.fromList(raw.sublist(0, 16)));
          return _WavPcmFmt(
            audioFormat: bd.getUint16(0, Endian.little),
            numChannels: bd.getUint16(2, Endian.little),
            sampleRate: bd.getUint32(4, Endian.little),
            bitsPerSample: bd.getUint16(14, Endian.little),
          );
        }

        pos = payloadStart + chunkSize + (chunkSize & 1);
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      await raf?.close();
    }
  }

  /// Raw mono PCM from first `data` chunk (16-bit LE). Stereo is downmixed for diagnostics only.
  Future<Int16List?> _readWavPcm16Mono(File f) async {
    RandomAccessFile? raf;
    try {
      raf = await f.open(mode: FileMode.read);
      final fileLen = await raf.length();
      if (fileLen < 44) return null;

      await raf.setPosition(0);
      final head = await raf.read(12);
      if (head.length < 12) return null;
      if (String.fromCharCodes(head.sublist(0, 4)) != 'RIFF') return null;
      if (String.fromCharCodes(head.sublist(8, 12)) != 'WAVE') return null;

      var pos = 12;
      int numChannels = 1;
      var bitsPerSample = 16;

      while (pos + 8 <= fileLen) {
        await raf.setPosition(pos);
        final idBytes = await raf.read(4);
        final sizeBytes = await raf.read(4);
        if (idBytes.length < 4 || sizeBytes.length < 4) return null;
        final chunkId = String.fromCharCodes(idBytes);
        final chunkSize = ByteData.sublistView(
          Uint8List.fromList(sizeBytes),
        ).getUint32(0, Endian.little);
        final payloadStart = pos + 8;

        if (chunkId == 'fmt ') {
          await raf.setPosition(payloadStart);
          final n = math.min(chunkSize, 32);
          final fmt = await raf.read(n);
          if (fmt.length >= 16) {
            final bd = ByteData.sublistView(
              Uint8List.fromList(fmt.sublist(0, 16)),
            );
            numChannels = bd.getUint16(2, Endian.little);
            bitsPerSample = bd.getUint16(14, Endian.little);
          }
        } else if (chunkId == 'data') {
          if (bitsPerSample != 16) return null;
          await raf.setPosition(payloadStart);
          final raw = await raf.read(chunkSize);
          if (raw.length < chunkSize) return null;
          if (raw.length % 2 != 0) return null;
          final bytes = Uint8List.fromList(raw);
          final all = Int16List.view(
            bytes.buffer,
            bytes.offsetInBytes,
            bytes.length ~/ 2,
          );
          if (numChannels == 1) {
            return all;
          }
          if (numChannels == 2 && all.length >= 2) {
            final out = Int16List(all.length ~/ 2);
            for (var i = 0; i < out.length; i++) {
              final l = all[i * 2];
              final r = all[i * 2 + 1];
              out[i] = ((l + r) >> 1);
            }
            return out;
          }
          return null;
        }

        pos = payloadStart + chunkSize + (chunkSize & 1);
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      await raf?.close();
    }
  }

  Future<int> _wavPlaybackSeconds(File f) async {
    final fromHeader = await _parseWavDurationSeconds(f);
    if (fromHeader != null && fromHeader > 0) return fromHeader;

    final len = await f.length();
    final approx = (len ~/ 32000).clamp(1, _maxTranscribeDurationSeconds);
    return approx;
  }

  Future<int?> _parseWavDurationSeconds(File f) async {
    RandomAccessFile? raf;
    try {
      raf = await f.open(mode: FileMode.read);
      final fileLen = await raf.length();
      if (fileLen < 44) return null;

      await raf.setPosition(0);
      final head = await raf.read(12);
      if (head.length < 12) return null;
      if (String.fromCharCodes(head.sublist(0, 4)) != 'RIFF') return null;
      if (String.fromCharCodes(head.sublist(8, 12)) != 'WAVE') return null;

      var pos = 12;
      int? sampleRate;
      int? numChannels;
      int? bitsPerSample;

      while (pos + 8 <= fileLen) {
        await raf.setPosition(pos);
        final idBytes = await raf.read(4);
        final sizeBytes = await raf.read(4);
        if (idBytes.length < 4 || sizeBytes.length < 4) return null;
        final chunkId = String.fromCharCodes(idBytes);
        final chunkSize = ByteData.sublistView(
          Uint8List.fromList(sizeBytes),
        ).getUint32(0, Endian.little);
        final payloadStart = pos + 8;

        if (chunkId == 'fmt ') {
          await raf.setPosition(payloadStart);
          final n = math.min(chunkSize, 32);
          final fmt = await raf.read(n);
          if (fmt.length >= 16) {
            final bd = ByteData.sublistView(
              Uint8List.fromList(fmt.sublist(0, 16)),
            );
            numChannels = bd.getUint16(2, Endian.little);
            sampleRate = bd.getUint32(4, Endian.little);
            bitsPerSample = bd.getUint16(14, Endian.little);
          }
        } else if (chunkId == 'data') {
          sampleRate ??= 16000;
          numChannels ??= 1;
          bitsPerSample ??= 16;
          final bytesPerFrame = numChannels * (bitsPerSample ~/ 8);
          if (bytesPerFrame <= 0 || sampleRate <= 0) return null;
          final frameCount = chunkSize ~/ bytesPerFrame;
          return math.max(1, (frameCount + sampleRate - 1) ~/ sampleRate);
        }

        pos = payloadStart + chunkSize + (chunkSize & 1);
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      await raf?.close();
    }
  }

  Future<String> _modelDir() async {
    final dir = Platform.isAndroid
        ? await getApplicationSupportDirectory()
        : await getLibraryDirectory();
    return dir.path;
  }

  Future<String> _pathFor(WhisperVariant v) async {
    return '${await _modelDir()}/${v.filename}';
  }

  Future<bool> _isUsable(File f, WhisperVariant variant) async {
    if (!await f.exists()) return false;
    final len = await f.length();
    return len >= variant.minSizeBytes;
  }

  Future<bool> _verifySha256(File f, String expectedHex) async {
    final digest = await sha256.bind(f.openRead()).first;
    final actual = digest.toString();
    if (actual.toLowerCase() != expectedHex.toLowerCase()) {
      log(
        'sha256 mismatch for ${f.path}: expected $expectedHex, got $actual',
        name: 'TranscriptionService',
      );
      return false;
    }
    return true;
  }

  Future<void> _downloadStreaming(
    Uri uri,
    File target,
    WhisperVariant variant,
    void Function(double)? onProgress,
  ) async {
    final partFile = File('${target.path}.part');
    await target.parent.create(recursive: true);
    if (await partFile.exists()) {
      await partFile.delete();
    }

    final client = HttpClient();
    try {
      final req = await client.getUrl(uri);
      req.followRedirects = true;
      req.maxRedirects = 5;
      final resp = await req.close();

      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpException(
          'Whisper model download failed: HTTP ${resp.statusCode}',
          uri: uri,
        );
      }

      final total = resp.contentLength;
      var received = 0;
      downloadPct.value = 0;

      final sink = partFile.openWrite();
      try {
        await for (final chunk in resp) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) {
            final pct = (received / total) * 100.0;
            downloadPct.value = pct.floor().clamp(0, 100);
            onProgress?.call(pct);
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      if (total > 0 && received < total) {
        throw const HttpException(
          'Whisper model download truncated before EOF.',
        );
      }
      if (!await _isUsable(partFile, variant)) {
        throw const HttpException(
          'Whisper model download too small to be valid.',
        );
      }

      if (await target.exists()) await target.delete();
      await partFile.rename(target.path);
      downloadPct.value = 100;
    } finally {
      client.close(force: true);
    }
  }
}

/// Pipelined chunked transcription fed from aligned `pcm16` stream (see [RecordingService.startStreaming]).
class LiveTranscriptionSession {
  LiveTranscriptionSession._(
    this._svc, {
    required void Function(String merged) onPartial,
    String? initialPrompt,
  })  : _onPartial = onPartial,
        _initialPrompt = initialPrompt,
        _sessionId = DateTime.now().microsecondsSinceEpoch;

  final TranscriptionService _svc;
  final void Function(String merged) _onPartial;
  final String? _initialPrompt;
  final int _sessionId;

  Future<int>? _threadsFut;
  Future<String>? _modelPathFut;

  final _fifo = _ByteFifo();
  int _fifoBaseAbsoluteSample = 0;
  int _nextWindowAbsoluteStart = 0;
  int _samplesIngestedTotal = 0;
  int _chunksDone = 0;

  Future<void> _drainLocks = Future<void>.value();

  bool _disposed = false;
  bool _finalized = false;
  bool _heavyBacklogLogged = false;

  String _mergedText = '';
  final List<WhisperTranscribeSegment> _mergedSegments = [];

  /// Wall-audio not yet covered by the segmentation cursor (informative only).
  final backlogAudioSeconds = 0.0.obs;

  /// Human-readable backlog hint for the HUD (empty when negligible).
  final backlogHudLine = ''.obs;

  bool get isDisposed => _disposed;

  void _kickDrain() {
    _drainLocks = _drainLocks.then((_) async {
      if (_disposed) return;
      await _pumpBodies();
    });
  }

  Future<void> _pumpBodies() async {
    if (_disposed) return;

    final t = await (_threadsFut ??=
        TranscriptionService._resolveWhisperThreadCount());
    final m =
        await (_modelPathFut ??= _svc._pathFor(kBanglaWhisper));
    final lang = kBanglaWhisper.lockedLanguage ?? 'bn';
    final w = TranscriptionService._chunkWindowSamples;
    final hop = TranscriptionService._chunkHopSamples;
    final dir = await getTemporaryDirectory();

    while (!_disposed) {
      while (!_disposed) {
        final absEnd = _fifoBaseAbsoluteSample +
            (_fifo.byteLength ~/ TranscriptionService._pcmBytesPerSample);
        if (absEnd < _nextWindowAbsoluteStart + w) {
          break;
        }

        await _emitOneWindow(
          dir: dir,
          modelPath: m,
          threads: t,
          lang: lang,
          windowSamples: w,
          hopSamples: hop,
        );
      }

      if (!_finalized) {
        _recomputeBacklog();
        return;
      }

      final absEnd = _fifoBaseAbsoluteSample +
          (_fifo.byteLength ~/ TranscriptionService._pcmBytesPerSample);
      final tailSamples = absEnd - _nextWindowAbsoluteStart;
      if (tailSamples > 0) {
        await _emitTail(
          dir: dir,
          modelPath: m,
          threads: t,
          lang: lang,
          tailSamples: tailSamples,
        );
      }

      _recomputeBacklog();
      return;
    }

    _recomputeBacklog();
  }

  Future<void> _emitOneWindow({
    required Directory dir,
    required String modelPath,
    required int threads,
    required String lang,
    required int windowSamples,
    required int hopSamples,
  }) async {
    final S = _nextWindowAbsoluteStart;
    final byteOff = (S - _fifoBaseAbsoluteSample) *
        TranscriptionService._pcmBytesPerSample;
    final pcm = _fifo.int16Slice(byteOff, windowSamples);

    final ix = _chunksDone;
    final wavPath = '${dir.path}/bangla_live_${_sessionId}_$ix.wav';
    final tmp = File(wavPath);
    await tmp.writeAsBytes(_svc._wavFromPcm16Mono(pcm));

    try {
      final resp = await _svc._transcribeOneFile(
        wavPath,
        lang: lang,
        modelPath: modelPath,
        threads: threads,
        initialPrompt: ix == 0 ? _initialPrompt : null,
      );
      _applyChunkResult(
        absoluteStartSamples: S,
        windowSamples: windowSamples,
        resp: resp,
        chunkIx: ix,
      );
    } finally {
      await _svc._deleteIfExists(tmp);
    }

    _chunksDone++;

    final newBase = S + hopSamples;
    final dropBytes =
        (newBase - _fifoBaseAbsoluteSample) *
            TranscriptionService._pcmBytesPerSample;
    _fifo.dropFirst(dropBytes);
    _fifoBaseAbsoluteSample = newBase;
    _nextWindowAbsoluteStart = newBase;

    _onPartial(_mergedText.trim());
  }

  Future<void> _emitTail({
    required Directory dir,
    required String modelPath,
    required int threads,
    required String lang,
    required int tailSamples,
  }) async {
    final S = _nextWindowAbsoluteStart;
    final byteOff =
        (S - _fifoBaseAbsoluteSample) * TranscriptionService._pcmBytesPerSample;
    final pcm = _fifo.int16Slice(byteOff, tailSamples);

    final ix = _chunksDone;
    final wavPath = '${dir.path}/bangla_live_${_sessionId}_$ix.wav';
    final tmp = File(wavPath);
    await tmp.writeAsBytes(_svc._wavFromPcm16Mono(pcm));

    try {
      final resp = await _svc._transcribeOneFile(
        wavPath,
        lang: lang,
        modelPath: modelPath,
        threads: threads,
        initialPrompt: ix == 0 ? _initialPrompt : null,
      );
      _applyChunkResult(
        absoluteStartSamples: S,
        windowSamples: tailSamples,
        resp: resp,
        chunkIx: ix,
      );
    } finally {
      await _svc._deleteIfExists(tmp);
    }

    _chunksDone++;

    final newEnd = S + tailSamples;
    _fifo.clear();
    _fifoBaseAbsoluteSample = newEnd;
    _nextWindowAbsoluteStart = newEnd;

    _onPartial(_mergedText.trim());
  }

  void _applyChunkResult({
    required int absoluteStartSamples,
    required int windowSamples,
    required WhisperTranscribeResponse resp,
    required int chunkIx,
  }) {
    final t = resp.text.trim();
    final pcmEnd = absoluteStartSamples + windowSamples;
    final durMs =
        (windowSamples * 1000 / TranscriptionService._pcmSampleRate).round();
    log(
      'live_chunk ix=$chunkIx '
      'pcm=$absoluteStartSamples..$pcmEnd (~${(durMs / 1000).toStringAsFixed(2)}s) '
      'empty=${t.isEmpty} segments=${resp.segments?.length ?? 0} '
      'snippet=${_svc._oneLineLogSnippet(t)}',
      name: 'TranscriptionService',
    );

    _mergedText = _mergedText.isEmpty
        ? t
        : _svc._mergeOverlappingChunkText(_mergedText, t);

    final offMs =
        absoluteStartSamples * 1000 ~/ TranscriptionService._pcmSampleRate;
    final segs = resp.segments;
    if (segs != null) {
      for (final s in segs) {
        _mergedSegments.add(
          WhisperTranscribeSegment(
            fromTs: Duration(milliseconds: s.fromTs.inMilliseconds + offMs),
            toTs: Duration(milliseconds: s.toTs.inMilliseconds + offMs),
            text: s.text,
          ),
        );
      }
    }
  }

  void _recomputeBacklog() {
    final absEnd = _fifoBaseAbsoluteSample +
        (_fifo.byteLength ~/ TranscriptionService._pcmBytesPerSample);
    final debtSamples = math.max(0, absEnd - _nextWindowAbsoluteStart);
    final secs = debtSamples / TranscriptionService._pcmSampleRate;
    backlogAudioSeconds.value = secs;

    backlogHudLine.value = secs >= 2.0
        ? 'Transcription backlog ~${secs.clamp(0, 9999).toStringAsFixed(0)} s ahead (Whisper may trail while recording)'
        : '';
  }

  void ingestAlignedPcm16Mono(Uint8List bytes) {
    if (_disposed || _finalized || bytes.isEmpty) return;
    if (bytes.length.isOdd) return;

    final newSamples =
        bytes.length ~/ TranscriptionService._pcmBytesPerSample;
    final maxSamples = TranscriptionService._maxRecordedSamples;

    final nextTotal = _samplesIngestedTotal + newSamples;
    if (nextTotal > maxSamples) {
      throw TranscriptionInputTooLongException(
        TranscriptionService._maxTranscribeDurationSeconds,
      );
    }

    _fifo.add(bytes);
    _samplesIngestedTotal = nextTotal;
    _recomputeBacklog();

    final latest = backlogAudioSeconds.value;
    if (!_finalized &&
        !_disposed &&
        latest >= TranscriptionService._pipelinedBurstLogThresholdSec &&
        !_heavyBacklogLogged) {
      _heavyBacklogLogged = true;
      log(
        'live_pcm_burst backlog_audio_sec=${latest.toStringAsFixed(2)} '
        '(hint: Whisper may lag realtime on long takes)',
        name: 'TranscriptionService',
      );
    }

    _kickDrain();
  }

  Future<String> finalize({String? fullWavPath}) async {
    if (_finalized) {
      throw StateError('LiveTranscriptionSession.finalize twice');
    }
    _finalized = true;

    final threads = await (_threadsFut ??=
        TranscriptionService._resolveWhisperThreadCount());

    final totalDurMs =
        _samplesIngestedTotal * 1000 ~/ TranscriptionService._pcmSampleRate;
    final nominalSeconds =
        _samplesIngestedTotal / TranscriptionService._pcmSampleRate;

    final monitor = Get.find<TranscriptionResourceMonitorService>();

    if (fullWavPath != null) {
      final pf = File(fullWavPath);
      if (await pf.exists()) {
        await _svc._logWavLevelDiagnostics(
          pf,
          nominalSeconds: nominalSeconds.ceil(),
        );
      }
    }

    final mergedResponse =
        await monitor.collectDuring<WhisperTranscribeResponse>(
      audioDurationSeconds: nominalSeconds,
      whisperThreads: threads,
      work: () async {
        _kickDrain();
        await _drainLocks;
        if (_disposed) {
          throw StateError('Transcription disposed before finalize completed.');
        }
        return WhisperTranscribeResponse(
          type: 'transcribe',
          text: _mergedText,
          segments: _mergedSegments.isEmpty
              ? null
              : List<WhisperTranscribeSegment>.from(_mergedSegments),
        );
      },
    );

    final cleaned = _svc._clampAndSanitizeResponse(
      mergedResponse,
      totalDurationMs: totalDurMs,
    );
    _svc._logWhisperSegments(cleaned, modelId: kBanglaWhisper.id);
    final text = cleaned.text.trim();

    log(
      'live_finalize windows=$_chunksDone total_samples=$_samplesIngestedTotal (~${nominalSeconds.toStringAsFixed(2)} s)',
      name: 'TranscriptionService',
    );

    _svc._logTranscript(
      text,
      audioSeconds: nominalSeconds.ceil(),
      modelId: kBanglaWhisper.id,
    );

    _disposed = true;
    backlogHudLine.value = '';
    backlogAudioSeconds.value = 0;
    return text;
  }

  void disposeAbandoned() {
    _disposed = true;
    backlogHudLine.value = '';
    backlogAudioSeconds.value = 0;
  }
}

class _ByteFifo {
  Uint8List _buf = Uint8List(8192);
  int _len = 0;

  int get byteLength => _len;

  void add(Uint8List u) {
    final need = _len + u.length;
    while (need > _buf.length) {
      final next = Uint8List(_buf.length * 2);
      next.setRange(0, _len, _buf);
      _buf = next;
    }
    _buf.setRange(_len, need, u);
    _len = need;
  }

  void dropFirst(int nbytes) {
    if (nbytes <= 0) return;
    if (nbytes >= _len) {
      clear();
      return;
    }
    final remain = _len - nbytes;
    _buf.setRange(0, remain, _buf, nbytes);
    _len = remain;
  }

  void clear() {
    _len = 0;
  }

  Int16List int16Slice(int fifoByteOffset, int sampleCount) {
    final nbytes = sampleCount * 2;
    assert(fifoByteOffset >= 0 && fifoByteOffset + nbytes <= _len);
    final u8 =
        Uint8List.sublistView(_buf, fifoByteOffset, fifoByteOffset + nbytes);
    return Int16List.view(u8.buffer, u8.offsetInBytes, sampleCount);
  }
}

class _WavPcmFmt {
  const _WavPcmFmt({
    required this.audioFormat,
    required this.numChannels,
    required this.sampleRate,
    required this.bitsPerSample,
  });

  final int audioFormat;
  final int numChannels;
  final int sampleRate;
  final int bitsPerSample;
}
