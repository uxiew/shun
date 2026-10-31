package top.xdwa.shun

import android.app.Activity
import android.content.Intent
import com.google.zxing.client.android.Intents
import com.journeyapps.barcodescanner.ScanIntentResult
import com.journeyapps.barcodescanner.ScanOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 手机互传扫码（R62）。用 zxing-android-embedded 自带的扫码页，不自己接相机。
 *
 * 不用 mobile_scanner：它在 Android 上靠 ML Kit，是闭源库，GPL 的 App 不该带（docs/21 第 4 节）。
 * ScanOptions 出 Intent、自己 startActivityForResult：它的 ScanContract 要 ComponentActivity，
 * 而 MainActivity 是 FlutterActivity。
 */
class QrScanChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    companion object {
        private const val CHANNEL = "top.xdwa.shun/qr_scan"
        private const val REQUEST_SCAN = 8044
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private var pending: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler(::handleCall)
    }

    private fun handleCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "scan") {
            result.notImplemented()
            return
        }
        if (pending != null) {
            result.error("busy", "already scanning", null)
            return
        }
        val intent = ScanOptions()
            .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
            .setPrompt(call.argument<String>("prompt") ?: "")
            .setBeepEnabled(false)
            .setOrientationLocked(false)
            // 不弹它自己的框：它拿不到相机权限时说「相机出了问题，请重启设备」，引人去重启手机。权限的事交给 Dart 说。
            .addExtra(Intents.Scan.SHOW_MISSING_CAMERA_PERMISSION_DIALOG, false)
            .createScanIntent(activity)
        pending = result
        activity.startActivityForResult(intent, REQUEST_SCAN)
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_SCAN) return false
        val result = pending ?: return true
        pending = null
        val scan = ScanIntentResult.parseActivityResult(resultCode, data)
        when {
            scan.contents != null -> result.success(scan.contents)
            scan.originalIntent?.hasExtra(Intents.Scan.MISSING_CAMERA_PERMISSION) == true ->
                result.error("camera_denied", "camera permission denied", null)
            else -> result.success(null)
        }
        return true
    }

    fun dispose() {
        // 扫码页开着时界面被系统回收：结果到不了这个实例，先告诉 Dart，不然它一直等。
        pending?.error("scan_interrupted", "activity destroyed while scanning", null)
        pending = null
        channel.setMethodCallHandler(null)
    }
}
