package com.example.bangla_transcribe

import android.os.Build
import android.system.Os
import android.system.OsConstants
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "thermalHeadroomForWhisper" -> result.success(androidThermalOk())
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            METRICS_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSnapshot" -> result.success(buildSnapshotMap())
                else -> result.notImplemented()
            }
        }
    }

    private fun buildSnapshotMap(): Map<String, Any?> {
        val rss = readProcStatusVmRssBytes()
        val cpuMicros = procSelfCpuTimeMicros()
        val threads = readProcThreadCount()
        return mapOf(
            "rssBytes" to rss,
            "cpuTimeMicros" to cpuMicros,
            "threadCount" to threads,
        )
    }

    /** Prefer `/proc/self/status`; fall back to counting `/proc/self/task` (some ROMs omit or relocate fields). */
    private fun readProcThreadCount(): Int? {
        readProcStatusThreadCount()?.let { return it }
        return readProcTaskDirectoryCount()
    }

    private fun readProcStatusThreadCount(): Int? {
        return try {
            File("/proc/self/status").bufferedReader().use { reader ->
                var line = reader.readLine()
                while (line != null) {
                    if (line.startsWith("Threads")) {
                        val afterColon = line.substringAfter(':', "").trim()
                        afterColon.toIntOrNull()?.let { return@use it }
                        val parts = line.trim().split(Regex("\\s+"))
                        val lastNumeric = parts.mapNotNull { it.toIntOrNull() }.lastOrNull()
                        if (lastNumeric != null) return@use lastNumeric
                    }
                    line = reader.readLine()
                }
                null
            }
        } catch (_: Throwable) {
            null
        }
    }

    private fun readProcTaskDirectoryCount(): Int? {
        return try {
            val task = File("/proc/self/task")
            if (!task.isDirectory) return null
            task.list()?.count { entry -> entry.all { ch -> ch in '0'..'9' } }
        } catch (_: Throwable) {
            null
        }
    }

    private fun procSelfCpuTimeMicros(): Long? {
        val ticks = readProcSelfCpuTicks() ?: return null
        return try {
            val hz = Os.sysconf(OsConstants._SC_CLK_TCK)
            if (hz <= 0L) return null
            ticks * 1_000_000L / hz
        } catch (_: Throwable) {
            null
        }
    }

    private fun readProcSelfCpuTicks(): Long? {
        return try {
            val line = File("/proc/self/stat").readText().trim()
            val rp = line.lastIndexOf(')')
            if (rp < 0) return null
            val parts = line.substring(rp + 2).trim().split(Regex("\\s+"))
            if (parts.size < 13) return null
            val utime = parts[11].toLongOrNull() ?: return null
            val stime = parts[12].toLongOrNull() ?: return null
            utime + stime
        } catch (_: Throwable) {
            null
        }
    }

    private fun readProcStatusVmRssBytes(): Long? {
        return try {
            File("/proc/self/status").bufferedReader().use { reader ->
                var line = reader.readLine()
                while (line != null) {
                    if (line.startsWith("VmRSS:")) {
                        val parts = line.trim().split(Regex("\\s+"))
                        if (parts.size >= 2) {
                            val kb = parts[1].toLongOrNull() ?: return@use null
                            return kb * 1024L
                        }
                    }
                    line = reader.readLine()
                }
                null
            }
        } catch (_: Throwable) {
            null
        }
    }

    private fun androidThermalOk(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        return try {
            val svc = getSystemService("thermal") ?: return false
            val status = svc.javaClass
                .getMethod("getCurrentThermalStatus").invoke(svc) as Int
            val thermal = Class.forName("android.os.ThermalManager")
            fun tryConst(field: String): Int? =
                try {
                    thermal.getField(field).getInt(null)
                } catch (_: ReflectiveOperationException) {
                    null
                }
            val none = tryConst("THERMAL_STATUS_NONE")
            val light = tryConst("THERMAL_STATUS_LIGHT")
            (none != null && status == none) || (light != null && status == light)
        } catch (_: ReflectiveOperationException) {
            false
        }
    }

    private companion object {
        private const val CHANNEL = "bangla_transcribe/thermal_headroom"
        private const val METRICS_CHANNEL = "bangla_transcribe/process_metrics"
    }
}
