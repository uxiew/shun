package top.xdwa.shun

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.io.File

/**
 * Java/Kotlin 层没接住的异常（R26 F24）：进程死之前把堆栈写进私有目录，再交回系统原来的处理
 * （照常崩、照常进系统的崩溃记录）。下次启动 Dart 经 [DiagnosticsChannel] 取走、去敏后记进日志。
 *
 * 系统的退出记录里 Java 崩溃只有一句「crash」，没有堆栈，所以要自己留。只留最近一次：连着崩几次时，
 * 前几次在系统退出记录里还能看到发生过。文件和 Dart 的日志在同一个目录（filesDir/diagnostics，
 * allowBackup=false）。这里不去敏：进程马上就死，尽量少做事；去敏在 Dart 记进日志时做。
 */
object CrashRecorder {
    private const val DIRECTORY = "diagnostics"
    private const val FILE = "java_crash.json"

    /** 堆栈太长时只留前面这么多（cause 链可能很长）。 */
    private const val STACK_LIMIT = 16_000

    fun install(context: Context) {
        val app = context.applicationContext
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                val stack = Log.getStackTraceString(error).take(STACK_LIMIT)
                val json = JSONObject()
                    .put("at", System.currentTimeMillis())
                    .put("thread", thread.name)
                    .put("stack", stack)
                val file = file(app)
                file.parentFile?.mkdirs()
                file.writeText(json.toString())
            } catch (_: Throwable) {
                // 写不进去就算了，不能挡着系统的崩溃处理。
            }
            previous?.uncaughtException(thread, error)
        }
    }

    /** 取走上次的崩溃记录（取完就删）；没有就是 null。 */
    fun take(context: Context): Map<String, Any?>? {
        val file = file(context.applicationContext)
        if (!file.exists()) return null
        return try {
            val json = JSONObject(file.readText())
            mapOf(
                "at" to json.optLong("at"),
                "thread" to json.optString("thread"),
                "stack" to json.optString("stack"),
            )
        } catch (_: Throwable) {
            null
        } finally {
            file.delete()
        }
    }

    private fun file(context: Context) = File(File(context.filesDir, DIRECTORY), FILE)
}
