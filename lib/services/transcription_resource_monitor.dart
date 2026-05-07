import 'dart:async';
import 'dart:developer' show log;
import 'dart:math' as math;

import 'package:get/get.dart';

import 'process_metrics_channel.dart';

/// Snapshot of process-level stats around a single transcribe call.
class TranscriptionResourceReport {
  const TranscriptionResourceReport({
    required this.wallTime,
    required this.audioDurationSeconds,
    required this.whisperThreads,
    required this.rssBytesBefore,
    required this.rssBytesAfter,
    required this.rssBytesPeak,
    required this.rssSampleCount,
    required this.avgCpuPercent,
    required this.peakCpuPercent,
    required this.osThreadCountStart,
    required this.osThreadCountEnd,
    required this.osThreadCountPeak,
  });

  final Duration wallTime;
  final double audioDurationSeconds;

  /// Whisper `threads` argument (compute pool size), not OS thread total.
  final int whisperThreads;

  final int? rssBytesBefore;
  final int? rssBytesAfter;
  final int? rssBytesPeak;
  final int rssSampleCount;

  /// Mean process CPU use as a % of one logical CPU (can exceed 100% on multi-core).
  final double? avgCpuPercent;

  /// Worst sample window (see monitor sampling interval); same % semantics as [avgCpuPercent].
  final double? peakCpuPercent;

  /// `/proc` or Mach: total pthreads/tasks in this process (Flutter pool, Whisper, I/O, …).
  final int? osThreadCountStart;
  final int? osThreadCountEnd;
  final int? osThreadCountPeak;

  /// Audio seconds per wall second (>1 means faster than realtime).
  double? get realtimeFactor {
    final w = wallTime.inMicroseconds;
    if (w <= 0 || audioDurationSeconds <= 0) return null;
    return audioDurationSeconds / (w / 1e6);
  }
}

class TranscriptionResourceMonitorService extends GetxService {
  final lastReport = Rxn<TranscriptionResourceReport>();

  /// True while [collectDuring] is running (during transcribe).
  final liveTranscribeActive = false.obs;

  /// Smooth wall clock elapsed during transcribe.
  final liveElapsed = Duration.zero.obs;

  final liveRssCurrentBytes = Rxn<int>();
  final liveRssPeakBytes = Rxn<int>();

  /// CPU during the latest ~400 ms sample window (% of one logical core).
  final liveCpuLastIntervalPct = Rxn<double>();

  /// Running max of interval CPU% this session (for sparkline context).
  final liveCpuPeakIntervalPct = Rxn<double>();

  /// OS thread count from last metrics sample.
  final liveOsThreadCount = Rxn<int>();

  /// Highest OS thread count seen this transcribe session.
  final liveOsThreadPeak = Rxn<int>();

  static const Duration _sampleInterval = Duration(milliseconds: 400);
  static const Duration _elapsedTick = Duration(milliseconds: 100);

  /// Runs [work] while sampling process metrics on the main isolate.
  Future<R> collectDuring<R>({
    required Future<R> Function() work,
    required double audioDurationSeconds,
    required int whisperThreads,
  }) async {
    void stopLiveUi() {
      liveTranscribeActive.value = false;
    }

    void startLiveUi() {
      liveTranscribeActive.value = true;
      liveElapsed.value = Duration.zero;
      liveRssCurrentBytes.value = null;
      liveRssPeakBytes.value = null;
      liveCpuLastIntervalPct.value = null;
      liveCpuPeakIntervalPct.value = null;
      liveOsThreadCount.value = null;
      liveOsThreadPeak.value = null;
    }

    if (!ProcessMetricsChannel.isSupported) {
      startLiveUi();
      final sw = Stopwatch()..start();
      Timer? elapsedTicker;
      elapsedTicker = Timer.periodic(_elapsedTick, (_) {
        liveElapsed.value = sw.elapsed;
      });
      try {
        return await work();
      } finally {
        elapsedTicker.cancel();
        sw.stop();
        liveElapsed.value = sw.elapsed;
        final report = TranscriptionResourceReport(
          wallTime: sw.elapsed,
          audioDurationSeconds: audioDurationSeconds,
          whisperThreads: whisperThreads,
          rssBytesBefore: null,
          rssBytesAfter: null,
          rssBytesPeak: null,
          rssSampleCount: 0,
          avgCpuPercent: null,
          peakCpuPercent: null,
          osThreadCountStart: null,
          osThreadCountEnd: null,
          osThreadCountPeak: null,
        );
        lastReport.value = report;
        _logLastTranscribeLoad(report);
        stopLiveUi();
      }
    }

    startLiveUi();
    final sw = Stopwatch()..start();

    Timer? elapsedTicker;
    elapsedTicker = Timer.periodic(_elapsedTick, (_) {
      liveElapsed.value = sw.elapsed;
    });

    final startSnap = await ProcessMetricsChannel.snapshot();
    final rssBefore = startSnap?.rssBytes;
    int? peakRss = rssBefore;
    var sampleCount = 0;
    var pollBusy = false;

    final threadsStart = startSnap?.threadCount;
    int? peakThreads = threadsStart;
    void noteOsThreads(int? n) {
      if (n == null) return;
      liveOsThreadCount.value = n;
      peakThreads = peakThreads == null ? n : math.max(peakThreads!, n);
      liveOsThreadPeak.value = peakThreads;
    }

    noteOsThreads(threadsStart);

    liveRssCurrentBytes.value = rssBefore;
    liveRssPeakBytes.value = rssBefore;

    final startCpu = startSnap?.cpuTimeMicros;
    double? peakCpuPct;
    int? prevWallMicros = DateTime.now().microsecondsSinceEpoch;
    int? prevCpuMicros = startCpu;

    void considerCpuPeak(int? cpuNow, int wallNowMicros) {
      final prevC = prevCpuMicros;
      final prevW = prevWallMicros;
      if (cpuNow == null || prevC == null || prevW == null) {
        return;
      }
      final dCpu = cpuNow - prevC;
      final dWall = wallNowMicros - prevW;
      if (dWall > 0 && dCpu >= 0) {
        final pct = 100.0 * dCpu / dWall;
        peakCpuPct = peakCpuPct == null ? pct : math.max(peakCpuPct!, pct);
        liveCpuLastIntervalPct.value = pct;
        final prevPeak = liveCpuPeakIntervalPct.value;
        liveCpuPeakIntervalPct.value =
            prevPeak == null ? pct : math.max(prevPeak, pct);
      }
      prevCpuMicros = cpuNow;
      prevWallMicros = wallNowMicros;
    }

    Timer? timer;
    timer = Timer.periodic(_sampleInterval, (_) {
      if (pollBusy) return;
      pollBusy = true;
      ProcessMetricsChannel.snapshot().then((snap) {
        pollBusy = false;
        final wall = DateTime.now().microsecondsSinceEpoch;
        if (snap == null) return;

        noteOsThreads(snap.threadCount);

        final b = snap.rssBytes;
        if (b != null) {
          sampleCount++;
          if (peakRss == null || b > peakRss!) {
            peakRss = b;
          }
          liveRssCurrentBytes.value = b;
          liveRssPeakBytes.value = peakRss;
        }

        considerCpuPeak(snap.cpuTimeMicros, wall);
      });
    });

    try {
      return await work();
    } finally {
      elapsedTicker.cancel();
      timer.cancel();
      sw.stop();
      liveElapsed.value = sw.elapsed;

      final endWall = DateTime.now().microsecondsSinceEpoch;
      final endSnap = await ProcessMetricsChannel.snapshot();
      final rssAfter = endSnap?.rssBytes;
      if (rssAfter != null) {
        liveRssCurrentBytes.value = rssAfter;
        if (peakRss == null || rssAfter > peakRss!) {
          peakRss = rssAfter;
        }
        liveRssPeakBytes.value = peakRss;
      }

      noteOsThreads(endSnap?.threadCount);
      considerCpuPeak(endSnap?.cpuTimeMicros, endWall);

      final endCpu = endSnap?.cpuTimeMicros;
      double? avgCpu;
      final wallMicros = sw.elapsedMicroseconds;
      if (startCpu != null &&
          endCpu != null &&
          wallMicros > 0 &&
          endCpu >= startCpu) {
        avgCpu = 100.0 * (endCpu - startCpu) / wallMicros;
      }

      final report = TranscriptionResourceReport(
        wallTime: sw.elapsed,
        audioDurationSeconds: audioDurationSeconds,
        whisperThreads: whisperThreads,
        rssBytesBefore: rssBefore,
        rssBytesAfter: rssAfter,
        rssBytesPeak: peakRss,
        rssSampleCount: sampleCount,
        avgCpuPercent: avgCpu,
        peakCpuPercent: peakCpuPct,
        osThreadCountStart: threadsStart,
        osThreadCountEnd: endSnap?.threadCount,
        osThreadCountPeak: peakThreads,
      );
      lastReport.value = report;
      _logLastTranscribeLoad(report);

      stopLiveUi();
    }
  }

  void _logLastTranscribeLoad(TranscriptionResourceReport r) {
    final rf = r.realtimeFactor;
    final rfLabel = rf != null ? rf.toStringAsFixed(2) : 'n/a';
    log(
      'last_transcribe_load '
      'audio_sec=${r.audioDurationSeconds.toStringAsFixed(3)} '
      'wall_ms=${r.wallTime.inMilliseconds} '
      'audio_per_wall_ratio=$rfLabel '
      '(>1=faster_than_realtime) '
      'whisper_workers=${r.whisperThreads} '
      'rss_samples=${r.rssSampleCount} '
      'rss_peak_bytes=${r.rssBytesPeak ?? '—'} '
      'rss_before_bytes=${r.rssBytesBefore ?? '—'} '
      'rss_after_bytes=${r.rssBytesAfter ?? '—'} '
      'avg_cpu_pct=${r.avgCpuPercent?.toStringAsFixed(1) ?? '—'} '
      'peak_cpu_pct_interval=${r.peakCpuPercent?.toStringAsFixed(1) ?? '—'} '
      'os_threads_peak=${r.osThreadCountPeak ?? '—'} '
      'os_threads=${r.osThreadCountStart ?? '—'}->${r.osThreadCountEnd ?? '—'}',
      name: 'bangla_transcribe',
    );
  }
}
