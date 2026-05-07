import 'dart:io';

import 'package:flutter/services.dart';

/// One process-level sample (RSS + cumulative CPU used by this process).
class ProcessMetricSnapshot {
  const ProcessMetricSnapshot({
    this.rssBytes,
    this.cpuTimeMicros,
    this.threadCount,
  });

  final int? rssBytes;

  /// Cumulative CPU user+system time for the process (not wall time).
  final int? cpuTimeMicros;

  /// OS thread count for this process (Dart, Flutter engine, Whisper pool, …).
  final int? threadCount;
}

class ProcessMetricsChannel {
  ProcessMetricsChannel._();

  static const MethodChannel _channel = MethodChannel(
    'bangla_transcribe/process_metrics',
  );

  static bool get isSupported =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  static Future<ProcessMetricSnapshot?> snapshot() async {
    if (!isSupported) return null;
    try {
      final dynamic raw =
          await _channel.invokeMethod<dynamic>('getSnapshot');
      if (raw is! Map) return null;
      final r = raw['rssBytes'];
      final c = raw['cpuTimeMicros'];
      final t = raw['threadCount'];
      return ProcessMetricSnapshot(
        rssBytes: _parseIntNullable(r),
        cpuTimeMicros: _parseIntNullable(c),
        threadCount: _parseIntNullable(t),
      );
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }
  }

  static int? _parseIntNullable(Object? value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is double && value.round() == value) return value.toInt();
    return int.tryParse(value.toString());
  }
}
