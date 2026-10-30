package top.xdwa.shun

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * 日志（R26 F24）要的两样只有 Android 知道的东西：
 * - 上次 Java 层崩溃的堆栈：[CrashRecorder] 在进程死前写下，这里取走；
 * - 系统记下的进程退出原因（Android 11 起的 ApplicationExitInfo）：原生崩溃、无响应被结束、
 *   内存不够被杀，这些 App 自己来不及记。Dart 带上已经看过的最晚时间，只回更晚的。
 * 只读，不联网。跟引擎同寿命（见 [ProcessEngine]）。
 */
class DiagnosticsChannel(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "top.xdwa.shun/diagnostics")

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "takeJavaCrash" -> result.success(CrashRecorder.take(context))
                "exitReasons" -> {
                    val since = call.argument<Number>("since")?.toLong() ?: 0L
                    result.success(exitReasons(since))
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun exitReasons(since: Long): List<Map<String, Any?>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return emptyList()
        val manager = context.getSystemService(ActivityManager::class.java) ?: return emptyList()
        return try {
            manager.getHistoricalProcessExitReasons(context.packageName, 0, 16)
                .filter { it.timestamp > since }
                .map { info ->
                    mapOf(
                        "at" to info.timestamp,
                        "reason" to info.reason,
                        "description" to info.description,
                        "trace" to anrTrace(info),
                    )
                }
        } catch (_: Throwable) {
            emptyList()
        }
    }

    /**
     * 无响应（ANR）时系统存了各线程的堆栈，只取开头一段（主线程在最前面）。
     * 原生崩溃的 tombstone 是 protobuf，这里不解，只记发生过。
     */
    private fun anrTrace(info: ApplicationExitInfo): String? {
        if (info.reason != ApplicationExitInfo.REASON_ANR) return null
        return try {
            info.traceInputStream?.use { input ->
                val buffer = ByteArray(TRACE_LIMIT)
                val read = input.read(buffer)
                if (read <= 0) null else String(buffer, 0, read)
            }
        } catch (_: Throwable) {
            null
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    private companion object {
        const val TRACE_LIMIT = 12_000
    }
}
