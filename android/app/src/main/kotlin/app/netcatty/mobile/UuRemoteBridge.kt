package app.netcatty.mobile

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.net.Uri
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import top.xdwa.xwshun.plugin.v1.SignerDigests

/**
 * 网易 UU 远程的 Android 平台边界（X06）。协议口径见 plan/v3/docs/17「X06 固定的官方口径」。
 *
 * 这里只做系统层面的事：查谁能打开 `uuremote://`、读官方包的版本和系统报告的证书、用显式包名发请求、
 * 把收到的回调原文排队交给 Dart。**回调的校验（state、nonce、格式）全部在 Dart**，这里不重复一套规则；
 * 冷启动和 App 已在运行时收到的回调走同一个队列、同一个校验器。回调由 UuCallbackActivity 接，不经 MainActivity。
 *
 * 不写日志：回调里有 UU 的加密设备标识，按敏感值处理。
 */
class UuRemoteBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val pm = activity.packageManager
    private val channel = MethodChannel(messenger, "top.xdwa.xwshun/uuremote")

    init {
        channel.setMethodCallHandler(this)
        instance = this
    }

    companion object {
        const val CALLBACK_SCHEME = "xwshun-uuremote"
        private const val UU_PACKAGE = "com.netease.uuremote"
        private const val MAX_CALLBACK_CHARS = 16 * 1024
        private const val MAX_QUEUED = 8

        /** 还没被 Dart 取走的回调原文。只在主线程读写（onCreate、onNewIntent、MethodChannel 都在主线程）。 */
        private val queue = ArrayDeque<String>()
        private var instance: UuRemoteBridge? = null

        fun isCallback(intent: Intent?): Boolean =
            intent?.action == Intent.ACTION_VIEW && intent.data?.scheme == CALLBACK_SCHEME

        /**
         * UuCallbackActivity 收到回调时调用：原文排队，等 Dart 来取（App 是被回调拉起来的时候，Dart 还没起来）。
         *
         * 从「最近任务」重新打开时系统会把当初的 Intent 原样再给一次，那不是新回调，直接丢
         * （UuCallbackActivity 不进最近任务，按理不会发生；清单哪天被改了这里还能兜住）。
         * 队列有上限：被人连发一堆伪造回调也只占这么点内存，反正对不上请求的都会被 Dart 忽略。
         */
        fun capture(intent: Intent?) {
            if (!isCallback(intent)) return
            val fromHistory = intent!!.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0
            val raw = intent.data.toString()
            if (fromHistory || raw.length > MAX_CALLBACK_CHARS) return
            while (queue.size >= MAX_QUEUED) queue.removeFirst()
            queue.addLast(raw)
            instance?.channel?.invokeMethod("callbacksAvailable", null)
        }

        /** 去掉 data 的同一个 Intent：Flutter 看到的就是普通启动。 */
        fun stripped(intent: Intent): Intent = Intent(intent).apply {
            data = null
            action = Intent.ACTION_MAIN
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "probe" -> result.success(probe())
            "launch" -> launch(
                call.argument<String>("uri") ?: "",
                call.argument<String>("sha256") ?: "",
                result,
            )
            "takeCallbacks" -> {
                val taken = queue.toList()
                queue.clear()
                result.success(taken)
            }
            else -> result.notImplemented()
        }
    }

    private fun queryActivities(intent: Intent): List<ResolveInfo> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.queryIntentActivities(
                intent,
                PackageManager.ResolveInfoFlags.of(PackageManager.MATCH_DEFAULT_ONLY.toLong()),
            )
        } else {
            @Suppress("DEPRECATION")
            pm.queryIntentActivities(intent, PackageManager.MATCH_DEFAULT_ONLY)
        }

    /**
     * 官方的检测方式是 `uuremote://external` 能不能解析；另外读官方包名的版本和证书。
     * 两样分开报：装了官方包名但解析不到 scheme（旧版本），和别的 App 声明了 scheme 但官方包没装，是两回事。
     */
    private fun probe(): Map<String, Any?> {
        val handlers = queryActivities(Intent(Intent.ACTION_VIEW, Uri.parse("uuremote://external")))
            .map { it.activityInfo.packageName }
            .distinct()
        // 别的 App 也声明了本 App 的回调地址：UU 回调时系统会让用户选 App，选到它回调就到了别人手里（UUR06）。
        // 查法和 UU 发回调时系统的解析一致（隐式 VIEW、只算 DEFAULT 类别）。
        val rivals = queryActivities(Intent(Intent.ACTION_VIEW, Uri.parse("$CALLBACK_SCHEME://callback/bind")))
            .map { it.activityInfo.packageName }
            .distinct()
            .filter { it != activity.packageName }
        val out = mutableMapOf<String, Any?>(
            "handlesScheme" to (UU_PACKAGE in handlers),
            "otherHandlers" to handlers.filter { it != UU_PACKAGE },
            "callbackRivals" to rivals,
        )
        try {
            val info = pm.getPackageInfo(UU_PACKAGE, 0)
            out["installed"] = true
            out["versionName"] = info.versionName
            out["versionCode"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                info.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                info.versionCode.toLong()
            }
            out["signers"] = SignerDigests.of(pm, UU_PACKAGE).map { it.sha256 }
        } catch (e: PackageManager.NameNotFoundException) {
            out["installed"] = false
        }
        return out
    }

    /**
     * 只发官方协议的请求，只发给官方包名，发之前再核一次证书：Dart 判定「可用」和这里发出之间，
     * 包可能被卸载重装成别人签的同名包。显式包名也保证别的 App 声明同一个 scheme 拿不到请求。
     */
    private fun launch(uri: String, sha256: String, result: MethodChannel.Result) {
        if (!uri.startsWith("uuremote://external/device/authorize?") &&
            !uri.startsWith("uuremote://external/device/control?")
        ) {
            result.error("bad_request", "只发官方协议的绑定和远控请求", null)
            return
        }
        val current = try {
            SignerDigests.digests(SignerDigests.of(pm, UU_PACKAGE))
        } catch (e: PackageManager.NameNotFoundException) {
            result.error("not_installed", "没有装 UU 远程", null)
            return
        }
        if (sha256.isEmpty() || current != setOf(sha256)) {
            result.error("signer_changed", "UU 远程的签名证书和核对过的不一致，没有发送", null)
            return
        }
        try {
            activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(uri)).setPackage(UU_PACKAGE))
            result.success(null)
        } catch (e: ActivityNotFoundException) {
            result.error("not_handled", "UU 远程没有接收这个请求（版本可能太旧）", null)
        } catch (e: SecurityException) {
            result.error("not_allowed", "系统不允许打开 UU 远程", null)
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        if (instance === this) instance = null
    }
}
