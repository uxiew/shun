package top.xdwa.shun

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
import top.xdwa.shun.plugin.v1.SignerDigests

/**
 * RustDesk 外部客户端联动的 Android 平台边界（X07）。口径见 plan/v3/docs/17「X07 固定的 RustDesk 口径」。
 *
 * 这里只做系统层面的事：查谁声明能打开 `rustdesk://`、读它们的版本和系统报告的证书、用显式包名发一条连接链接。
 * 发给谁、证书算不算可信，由 Dart（`evaluateRustDeskApp`）决定；这里在发出前再核一次链接写法和证书。
 *
 * RustDesk 不回报结果，所以这里没有回调通道：startActivity 没抛异常，只说明系统接下了这次启动。
 */
class RustDeskBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val pm = activity.packageManager
    private val channel = MethodChannel(messenger, "top.xdwa.shun/rustdesk")

    init {
        channel.setMethodCallHandler(this)
    }

    companion object {
        private const val OFFICIAL_PACKAGE = "com.carriez.flutter_hbb"

        /**
         * 本 App 发给 RustDesk 的唯一一种链接。和 Dart 的 `rustDeskConnectUri` 是同一条正则：
         * Dart 那边出了错（或者别的代码直接调这个通道），带密码的、改配置的链接也出不了这个进程（RDX02）。
         */
        private val CONNECT_URI =
            Regex("^rustdesk://connect/(?:[0-9]{1,16}|[A-Za-z][A-Za-z0-9_-]{5,15})$")
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "probe" -> result.success(probe())
            "launch" -> launch(
                call.argument<String>("uri") ?: "",
                call.argument<String>("package") ?: "",
                call.argument<String>("sha256") ?: "",
                result,
            )
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

    /** 一个包的版本和证书。包不见了（刚被卸载）返回 null。 */
    private fun describe(packageName: String): Map<String, Any?>? = try {
        val info = pm.getPackageInfo(packageName, 0)
        mapOf(
            "package" to packageName,
            "versionName" to info.versionName,
            "versionCode" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                info.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                info.versionCode.toLong()
            },
            "signers" to SignerDigests.of(pm, packageName).map { it.sha256 },
        )
    } catch (e: PackageManager.NameNotFoundException) {
        null
    }

    /**
     * 谁声明能打开本 App 会发的那种链接，连同各自的版本和证书；另外单独报官方包名装没装。
     * 两样分开：装了官方包名但它不接链接（1.2.3 及更早），和别的 App 声明了 scheme 但官方包没装，是两回事。
     */
    private fun probe(): Map<String, Any?> {
        val handlers = queryActivities(Intent(Intent.ACTION_VIEW, Uri.parse("rustdesk://connect/0")))
            .map { it.activityInfo.packageName }
            .distinct()
            .filter { it != activity.packageName }
        return mapOf(
            "handlers" to handlers.mapNotNull { describe(it) },
            "official" to describe(OFFICIAL_PACKAGE),
        )
    }

    /**
     * 只发白名单里的连接链接，只发给 Dart 指定的那一个包，发之前再核一次证书：Dart 判定「可用」和这里发出之间，
     * 包可能被卸载重装成别人签的同名包。显式包名保证别的 App 声明同一个 scheme 也拿不到请求（RDX01）。
     *
     * 带 NEW_TASK：RustDesk 在它自己的任务里打开，和从浏览器点链接一样。不带的话它的界面会叠在本 App 的任务里，
     * 「最近任务」里看着像本 App 在远控。不带任何 extras。
     */
    private fun launch(uri: String, packageName: String, sha256: String, result: MethodChannel.Result) {
        if (!CONNECT_URI.matches(uri)) {
            result.error("bad_request", "只发 RustDesk 的连接链接", null)
            return
        }
        if (packageName.isEmpty() || packageName == activity.packageName) {
            result.error("bad_request", "没有指定要交给哪个 RustDesk", null)
            return
        }
        val current = try {
            SignerDigests.digests(SignerDigests.of(pm, packageName))
        } catch (e: PackageManager.NameNotFoundException) {
            result.error("not_installed", "要交给的那个 RustDesk 已经不在手机上了", null)
            return
        }
        if (sha256.isEmpty() || current != setOf(sha256)) {
            result.error("signer_changed", "RustDesk 的签名证书和核对过的不一致，没有发送", null)
            return
        }
        try {
            activity.startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse(uri))
                    .setPackage(packageName)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            result.success(null)
        } catch (e: ActivityNotFoundException) {
            result.error("not_handled", "RustDesk 没有接收这个请求（版本可能太旧，或被停用了）", null)
        } catch (e: SecurityException) {
            result.error("not_allowed", "系统不允许打开 RustDesk", null)
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }
}
