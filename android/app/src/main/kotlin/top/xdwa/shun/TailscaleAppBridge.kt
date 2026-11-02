package top.xdwa.shun

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 只打开 Tailscale 的启动页（R77），什么都不带过去。连没连上 tailnet 只有它自己知道，
 * 本 App 不查：要查得申请 VPN 相关的权限，换不来多少东西，用户看一眼 Tailscale 就清楚了。
 * 包名写死，不从 Dart 传：这座桥不能变成「打开任意 App」。
 */
class TailscaleAppBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "top.xdwa.shun/tailscale_app")

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "open") {
            result.notImplemented()
            return
        }
        // 清单里不列这个包名的话，Android 11 起这里永远是 null，装了也说没装。
        val launch = activity.packageManager.getLaunchIntentForPackage(TAILSCALE_PACKAGE)
        if (launch == null) {
            result.success(false)
            return
        }
        try {
            activity.startActivity(launch)
            result.success(true)
        } catch (e: ActivityNotFoundException) {
            result.success(false)
        } catch (e: SecurityException) {
            result.success(false)
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    private companion object {
        const val TAILSCALE_PACKAGE = "com.tailscale.ipn"
    }
}
