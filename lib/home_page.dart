import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';

import 'services/last_model_audio_sample_service.dart';
import 'services/process_metrics_channel.dart';
import 'services/recording_service.dart';
import 'services/transcription_resource_monitor.dart';
import 'services/transcription_service.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}
class _HomePageState extends State<HomePage> {
  late final TranscriptionService _tx;
  late final RecordingService _rec;
  late final LastModelAudioSampleService _sample;
  late final TranscriptionResourceMonitorService _resources;

  LiveTranscriptionSession? _pcmLive;
  StreamSubscription<Uint8List>? _pcmSub;

  final _transcript = ''.obs;
  final _busy = false.obs;
  final _status = ''.obs;

  @override
  void dispose() {
    unawaited(_pcmSub?.cancel());
    _pcmLive?.disposeAbandoned();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _tx = Get.find<TranscriptionService>();
    _rec = Get.find<RecordingService>();
    _sample = Get.find<LastModelAudioSampleService>();
    _resources = Get.find<TranscriptionResourceMonitorService>();
  }

  Future<void> _ensureModel() async {
    if (_tx.isInstalled.value) {
      await _tx.warmup();
      return;
    }
    _status.value =
        'Downloading model (~${kBanglaWhisper.approxSizeMB} MB)…';
    await _tx.ensureInstalled();
    await _tx.warmup();
    _status.value = '';
  }

  Future<void> _toggleRecord() async {
    if (_busy.value) return;
    if (_rec.isRecording.value) {
      await _stopAndTranscribe();
      return;
    }
    _busy.value = true;
    _status.value = '';
    try {
      await _ensureModel();
      _transcript.value = '';
      await _pcmSub?.cancel();
      _pcmLive?.disposeAbandoned();
      _pcmLive = null;
      _pcmSub = null;

      _pcmLive = _tx.beginLiveTranscription(
        onPartial: (t) => _transcript.value = t,
      );
      await _rec.startStreaming();
      _resources.beginPipelinedTranscribeObserve();
      _pcmSub = _rec.pcm16Stream.listen(
        (bytes) {
          try {
            _pcmLive!.ingestAlignedPcm16Mono(bytes);
          } on TranscriptionInputTooLongException catch (e) {
            _status.value = e.toString();
            unawaited(_abortRecordingDueToHardLimit());
          } catch (e) {
            _status.value = e.toString();
            unawaited(_abortRecordingDueToHardLimit());
          }
        },
        cancelOnError: false,
      );
    } on MicPermissionDeniedException catch (e) {
      _status.value = e.toString();
      await _cleanUpFailedRecordingStart();
      if (e.permanentlyDenied) {
        await openAppSettings();
      }
    } catch (e) {
      _status.value = e.toString();
      await _cleanUpFailedRecordingStart();
    } finally {
      _busy.value = false;
    }
  }

  Future<void> _abortRecordingDueToHardLimit() async {
    if (!_rec.isRecording.value) return;
    await _pcmSub?.cancel();
    _pcmSub = null;
    _pcmLive?.disposeAbandoned();
    _pcmLive = null;
    _resources.endPipelinedTranscribeObserve();
    await _rec.cancel();
    _busy.value = false;
  }

  Future<void> _cleanUpFailedRecordingStart() async {
    await _pcmSub?.cancel();
    _pcmSub = null;
    _pcmLive?.disposeAbandoned();
    _pcmLive = null;
    _resources.endPipelinedTranscribeObserve();
    if (_rec.isRecording.value || _rec.isStreamingMode) {
      await _rec.cancel();
    }
  }

  Future<void> _stopAndTranscribe() async {
    _busy.value = true;
    _status.value = 'Finishing…';
    String? wavPath;
    try {
      await _pcmSub?.cancel();
      _pcmSub = null;

      wavPath = await _rec.stopStreaming();
      _resources.endPipelinedTranscribeObserve();

      final live = _pcmLive;
      if (live == null) {
        throw StateError('No live transcription session.');
      }

      await _sample.captureFromPath(wavPath);

      _status.value = 'Transcribing…';
      final text = await live.finalize(fullWavPath: wavPath);
      _transcript.value = text;
      _pcmLive = null;
      _status.value = '';
    } on TranscriptionInputTooLongException catch (e) {
      _status.value = e.toString();
      _pcmLive?.disposeAbandoned();
      _pcmLive = null;
    } catch (e) {
      _status.value = e.toString();
      _pcmLive?.disposeAbandoned();
      _pcmLive = null;
    } finally {
      _busy.value = false;
      if (wavPath != null) {
        try {
          final f = File(wavPath);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F0),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'বাংলা',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.5,
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                'Speak in Bangla. Transcription runs on this device.',
                softWrap: true,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.black54,
                    ),
              ),
              const SizedBox(height: 24),
              Obx(() {
                if (!_tx.isInstalled.value && _tx.downloadPct.value > 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LinearProgressIndicator(
                          value: _tx.downloadPct.value / 100.0,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Downloading model ${_tx.downloadPct.value}%',
                          style: const TextStyle(
                            fontSize: 13,
                            color: Colors.black54,
                          ),
                        ),
                      ],
                    ),
                  );
                }
                return const SizedBox.shrink();
              }),
              Expanded(
                child: Obx(() {
                  final live = _resources.liveTranscribeActive.value ||
                      _rec.isRecording.value;
                  if (!live) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: Obx(
                            () => SingleChildScrollView(
                              child: SelectableText(
                                _transcript.value.isEmpty
                                    ? 'Transcript appears here.'
                                    : _transcript.value,
                                style: TextStyle(
                                  fontSize: 20,
                                  height: 1.45,
                                  color: _transcript.value.isEmpty
                                      ? Colors.black38
                                      : Colors.black87,
                                ),
                              ),
                            ),
                          ),
                        ),
                        _idleBelowTranscriptCards(),
                      ],
                    );
                  }
                  return SingleChildScrollView(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _liveTranscribePanel(context),
                        Obx(
                          () => SelectableText(
                            _transcript.value.isEmpty
                                ? 'Transcript appears here.'
                                : _transcript.value,
                            style: TextStyle(
                              fontSize: 20,
                              height: 1.45,
                              color: _transcript.value.isEmpty
                                  ? Colors.black38
                                  : Colors.black87,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        _idleBelowTranscriptCards(),
                      ],
                    ),
                  );
                }),
              ),
              Obx(() {
                final recording = _rec.isRecording.value;
                final busy = _busy.value;
                return Center(
                  child: Material(
                    color: recording
                        ? Colors.red.shade600
                        : const Color(0xFF1A1A1A),
                    borderRadius: BorderRadius.circular(999),
                    child: InkWell(
                      onTap: busy ? null : _toggleRecord,
                      borderRadius: BorderRadius.circular(999),
                      child: SizedBox(
                        width: 72,
                        height: 72,
                        child: Icon(
                          recording ? Icons.stop_rounded : Icons.mic_rounded,
                          color: Colors.white,
                          size: 36,
                        ),
                      ),
                    ),
                  ),
                );
              }),
              Obx(() {
                if (!_rec.isRecording.value) return const SizedBox(height: 8);
                final line = _pcmLive?.backlogHudLine.value ?? '';
                return Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Column(
                    children: [
                      Text(
                        _formatDuration(_rec.elapsed.value),
                        style: const TextStyle(
                          fontFeatures: [FontFeature.tabularFigures()],
                          fontSize: 15,
                          color: Colors.black54,
                        ),
                      ),
                      if (line.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          line,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 12,
                            height: 1.35,
                            color: Colors.black54,
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _idleBelowTranscriptCards() {
    return Obx(() {
      final s = _status.value;
      final report = _resources.lastReport.value;
      final showPlayback = _sample.hasSample.value;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (s.isNotEmpty &&
              !_resources.liveTranscribeActive.value &&
              !_rec.isRecording.value)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                s,
                softWrap: true,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.red.shade800,
                ),
              ),
            ),
          if (showPlayback)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.black12),
                ),
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(
                    start: 12,
                    end: 4,
                    top: 10,
                    bottom: 10,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.graphic_eq_rounded,
                        color: Colors.grey.shade700,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Last recording (sent to model)',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                                color: Colors.grey.shade900,
                              ),
                            ),
                            Text(
                              'Same WAV Whisper ingests (saved on device).',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip:
                            _sample.isPlaying.value ? 'Pause' : 'Play',
                        onPressed: () {
                          unawaited(_sample.togglePlayback());
                        },
                        icon: Icon(
                          _sample.isPlaying.value
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          size: 32,
                          color: const Color(0xFF1A1A1A),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (report != null) _lastTranscribeLoadSection(report),
        ],
      );
    });
  }

  Widget _lastTranscribeLoadSection(TranscriptionResourceReport r) {
    final wall =
        (r.wallTime.inMilliseconds / 1000).toStringAsFixed(2);
    final rf = r.realtimeFactor;
    final rfLabel =
        rf != null ? '${rf.toStringAsFixed(1)}× realtime' : 'realtime n/a';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.black12),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.speed_rounded,
                    size: 20,
                    color: Colors.grey.shade700,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Last transcribe load',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: Colors.grey.shade900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '${wall}s wall · ${_mbOrDash(r.rssBytesPeak)} peak RSS · '
                '${r.whisperThreads} Whisper workers · '
                '${_fmtCpuLoad(r.avgCpuPercent)} avg · '
                '${_fmtCpuLoad(r.peakCpuPercent)} peak · $rfLabel',
                softWrap: true,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  color: Colors.grey.shade800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'OS threads (process total): ${_fmtOsThreads(r)} — '
                'includes Flutter, I/O, and Whisper pool (not the same as Whisper workers).',
                softWrap: true,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.35,
                  color: Colors.grey.shade600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'CPU is process-wide, vs one logical core (like top/htop): '
                'Whisper threads add up, so totals above 100% are normal.',
                softWrap: true,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static const int _liveRssBarCapMb = 800;

  /// Visual cap for OS thread count bar (not a hard limit).
  static const int _liveThreadBarCap = 128;

  Widget _liveTranscribePanel(BuildContext context) {
    return Obx(() {
      if (!_resources.liveTranscribeActive.value &&
          !_rec.isRecording.value) {
        return const SizedBox.shrink();
      }

      final elapsed = _resources.liveElapsed.value;
      final rssPeak = _resources.liveRssPeakBytes.value;
      final cpuLast = _resources.liveCpuLastIntervalPct.value;
      final cpuPeak = _resources.liveCpuPeakIntervalPct.value;
      final nCores = Platform.numberOfProcessors.clamp(1, 999);
      final denomBytes = _liveRssBarCapMb * 1024 * 1024;
      final rssFrac =
          rssPeak != null ? (rssPeak / denomBytes).clamp(0.0, 1.0) : null;
      final cpuDenom = 100.0 * nCores;
      final cpuFrac = cpuLast != null
          ? (cpuLast / cpuDenom).clamp(0.0, 1.0)
          : null;

      final osTh = _resources.liveOsThreadCount.value;
      final osThPeak = _resources.liveOsThreadPeak.value;
      final threadFrac = osTh != null
          ? (osTh / _liveThreadBarCap).clamp(0.0, 1.0)
          : null;

      final track =
          Theme.of(context).colorScheme.surfaceContainerHighest;

      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.black12),
            boxShadow: [
              BoxShadow(
                blurRadius: 12,
                offset: const Offset(0, 4),
                color: Colors.black.withValues(alpha: 0.06),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.auto_awesome_motion,
                      size: 20,
                      color: Colors.grey.shade700,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _rec.isRecording.value
                            ? 'Listening / transcribing'
                            : 'Transcribing',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey.shade900,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _formatDuration(elapsed),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: const TextStyle(
                          fontFeatures: [FontFeature.tabularFigures()],
                          fontSize: 13,
                          color: Colors.black87,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    height: 4,
                    width: double.infinity,
                    child: LinearProgressIndicator(
                      backgroundColor: track,
                      value: null,
                    ),
                  ),
                ),
                if (ProcessMetricsChannel.isSupported) ...[
                  const SizedBox(height: 14),
                  _liveMetricBar(
                    context,
                    track,
                    label:
                        'Peak RSS (bar full $_liveRssBarCapMb MB)',
                    trailing:
                        rssPeak != null ? _mbExact(rssPeak) : '—',
                    value: rssFrac ?? 0,
                    indeterminate: rssFrac == null,
                  ),
                  const SizedBox(height: 12),
                  _liveMetricBar(
                    context,
                    track,
                    label:
                        'CPU last tick ($nCores logical CPUs)',
                    trailing:
                        '${_fmtCpuLoad(cpuLast)} · max ${_fmtCpuLoad(cpuPeak)}',
                    value: cpuFrac ?? 0,
                    indeterminate: cpuFrac == null,
                  ),
                  const SizedBox(height: 12),
                  _liveMetricBar(
                    context,
                    track,
                    label:
                        'OS threads (bar full $_liveThreadBarCap)',
                    trailing:
                        '${osTh ?? '—'} now · peak ${osThPeak ?? '—'}',
                    value: threadFrac ?? 0,
                    indeterminate: threadFrac == null,
                  ),
                ] else ...[
                  const SizedBox(height: 10),
                  Text(
                    'RSS/CPU meters need Android, iOS, or macOS.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _liveMetricBar(
    BuildContext context,
    Color track, {
    required String label,
    required String trailing,
    required double value,
    required bool indeterminate,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 2,
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                softWrap: true,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: Colors.grey.shade800,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              flex: 3,
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Text(
                  trailing,
                  textAlign: TextAlign.end,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  softWrap: true,
                  style: TextStyle(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    fontSize: 11,
                    color: Colors.grey.shade700,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 7,
            width: double.infinity,
            child: indeterminate
                ? LinearProgressIndicator(
                    backgroundColor: track,
                    value: null,
                  )
                : LinearProgressIndicator(
                    backgroundColor: track,
                    value: value,
                  ),
          ),
        ),
      ],
    );
  }

  static String _mbExact(int bytes) {
    final mb = bytes / (1024 * 1024);
    if (mb >= 10) return '${mb.round()} MB';
    return '${mb.toStringAsFixed(1)} MB';
  }

  /// Linux `Threads:` / Mach `task_threads` — count only, not per-thread load.
  static String _fmtOsThreads(TranscriptionResourceReport r) {
    final p = r.osThreadCountPeak;
    final a = r.osThreadCountStart;
    final b = r.osThreadCountEnd;
    if (p == null && a == null && b == null) return '—';
    final range = (a != null && b != null) ? '$a→$b' : null;
    if (range != null && p != null) return 'peak $p ($range)';
    if (p != null) return 'peak $p';
    return range ?? '—';
  }

  /// CPU% is vs one logical core; multi-threaded work stacks above 100% (Unix / htop style).
  static String _fmtCpuLoad(double? pct) {
    if (pct == null) return '—';
    final head = pct >= 10 ? '${pct.round()}%' : '${pct.toStringAsFixed(1)}%';
    if (pct <= 101) return head;
    final cores = pct / 100.0;
    final coresStr =
        cores >= 10 ? '${cores.round()}' : cores.toStringAsFixed(1);
    return '$head (≈$coresStr CPUs)';
  }

  static String _mbOrDash(int? bytes) {
    if (bytes == null) return '—';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    if (h > 0) return '$h:$m:$s';
    return '$m:$s';
  }
}
