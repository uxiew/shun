package top.xdwa.shun

import android.app.Activity
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * 带密码、私钥口令、代理口令的页面防截屏（R44）：Dart 说屏幕上现在有没有这种页面，这里给窗口加上或去掉
 * FLAG_SECURE。加上时截屏、录屏、投屏和最近任务的缩略图里都是黑的。什么时候加由 Dart 算（见
 * lib/application/sensitive_screen.dart），终端页从不加：用户要截终端。
 *
 * 跟引擎同寿命（见 [ProcessEngine]），要不要加也记在这里。FLAG_SECURE 挂在 Activity 的窗口上：
 * 开着会话时从最近任务划掉再打开（引擎留着，R22）、系统在后台回收了界面、开了「不保留活动」，
 * 都会换一个 Activity，新窗口不带这个标志，而 Dart 那边停在哪页没变、不会再说一次。所以 MainActivity
 * 接上引擎时调 [applyTo] 重新套上；漏了这步，停在主机编辑页划掉 App 再打开就能截了。转屏不换 Activity
 * （清单里 configChanges 都接了）。
 */
class WindowSecurityChannel(messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "top.xdwa.shun/window_security")

    // 只在主线程读写：MethodChannel 的回调和 Activity 的生命周期都在主线程。
    private var secure = false

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setSecure" -> {
                    secure = call.argument<Boolean>("secure") == true
                    applyTo(ProcessEngine.currentActivity)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun applyTo(activity: Activity?) {
        val window = activity?.window ?: return
        val flag = WindowManager.LayoutParams.FLAG_SECURE
        if (secure) window.addFlags(flag) else window.clearFlags(flag)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }
}
