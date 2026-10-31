package top.xdwa.shun

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.nfc.NfcAdapter
import android.os.Handler
import android.os.Looper
import com.yubico.yubikit.android.YubiKitManager
import com.yubico.yubikit.android.transport.nfc.NfcConfiguration
import com.yubico.yubikit.android.transport.nfc.NfcNotAvailable
import com.yubico.yubikit.android.transport.usb.DeviceFilter
import com.yubico.yubikit.android.transport.usb.UsbConfiguration
import com.yubico.yubikit.core.YubiKeyDevice
import com.yubico.yubikit.core.application.CommandException
import com.yubico.yubikit.core.application.CommandState
import com.yubico.yubikit.core.fido.CtapException
import com.yubico.yubikit.core.fido.FidoConnection
import com.yubico.yubikit.core.smartcard.SmartCardConnection
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 安全密钥（FIDO2）的 Android 桥。只管「等钥匙、连上、执行一次操作」，SSH 的事都在 Dart：
 * lib/domain/security_key.dart（格式）、lib/infrastructure/ssh/security_key_channel.dart（这头的调用方）。
 *
 * 一次只做一件事：第二个请求来时第一个还没完，直接拒绝。跟引擎同寿命（见 [ProcessEngine]），
 * 所以 NFC 要的 Activity 每次从 [ProcessEngine.currentActivity] 拿；界面切走再回来时系统会关掉 reader mode，
 * [onActivityResumed] 就是把它重新打开。不这么做的话，USB 授权框一弹（也算切走），NFC 就再也没反应。
 *
 * PIN 只在执行这次操作时放在内存，用完清零；不写日志、不自动重试（错多次钥匙会锁）。
 */
class SecurityKeyChannel(private val app: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "top.xdwa.shun/security_key")
    private val main = Handler(Looper.getMainLooper())

    // 只在主线程读写。
    private var pending: Pending? = null

    // 没有 NFC 的手机也能建，那时它内部的 NFC 管理器是 null。用到才建：注册广播不必提前。
    private val yubiKit by lazy { YubiKitManager(app) }
    private val usbConfiguration by lazy {
        UsbConfiguration()
            .handlePermissions(true)
            .setDeviceFilter(FidoDeviceFilter(app.getSystemService(UsbManager::class.java)))
    }

    init {
        channel.setMethodCallHandler { call, result -> onCall(call, result) }
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "availability" -> result.success(availability())
            "cancel" -> {
                pending?.finishWithError(SecurityKeyOperations.CANCELLED)
                result.success(null)
            }
            "sign", "create", "listResident" -> start(call, result)
            else -> result.notImplemented()
        }
    }

    private fun availability(): Map<String, Boolean> {
        val adapter = NfcAdapter.getDefaultAdapter(app)
        return mapOf(
            "nfc" to (adapter != null),
            "nfcEnabled" to (adapter?.isEnabled == true),
            "usb" to app.packageManager.hasSystemFeature(PackageManager.FEATURE_USB_HOST),
        )
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        if (pending != null) {
            result.error(SecurityKeyOperations.TRANSPORT, "busy", null)
            return
        }
        val operation: SecurityKeyOperations.Operation
        try {
            operation = SecurityKeyOperations.parse(call.method, call.arguments())
        } catch (_: IllegalArgumentException) {
            result.error(SecurityKeyOperations.TRANSPORT, "bad arguments", null)
            return
        }
        val next = Pending(operation, result)
        pending = next
        try {
            yubiKit.startUsbDiscovery(usbConfiguration) { next.onDevice(it) }
        } catch (_: RuntimeException) {
            // 系统拒绝 USB（比如没有 USB 主机能力）时还能用 NFC，不在这里结束。
        }
        startNfc(next)
    }

    /** 界面回到前台。reader mode 只在前台有效，退到后台系统就关了，回来要重新开。 */
    fun onActivityResumed() {
        pending?.let(::startNfc)
    }

    private fun startNfc(target: Pending) {
        val activity: Activity = ProcessEngine.currentActivity ?: return
        try {
            yubiKit.startNfcDiscovery(nfcConfiguration, activity) { target.onDevice(it) }
            target.nfcActivity = activity
        } catch (_: NfcNotAvailable) {
            // 没有 NFC 或关着：界面按 availability 提示，这次还能用 USB。
        } catch (_: IllegalStateException) {
            // 当前不在前台。回到前台时 onActivityResumed 再开。
        }
    }

    private fun stopDiscovery(target: Pending) {
        runCatching { yubiKit.stopUsbDiscovery() }
        target.nfcActivity?.let { activity ->
            runCatching { yubiKit.stopNfcDiscovery(activity) }
        }
        target.nfcActivity = null
    }

    private inner class Pending(
        val operation: SecurityKeyOperations.Operation,
        val result: MethodChannel.Result,
    ) {
        var nfcActivity: Activity? = null

        // 可能在别的线程设置、在主线程清除，取消和设置同时发生也要正常。
        @Volatile private var state: CommandState? = null
        private val started = AtomicBoolean(false)
        private val finished = AtomicBoolean(false)

        /** USB、NFC 都还开着，先到的那把钥匙生效，另一边来了不理。 */
        fun onDevice(device: YubiKeyDevice) {
            if (finished.get() || !started.compareAndSet(false, true)) return
            stage("communicating")
            val commandState = object : CommandState() {
                override fun onKeepAliveStatus(status: Byte) {
                    if (status == STATUS_UPNEEDED) stage("touch")
                }
            }
            state = commandState
            if (finished.get()) commandState.cancel()
            // 连接由 yubikit 在回调结束后关，这里不用管。
            if (device.supportsConnection(FidoConnection::class.java)) {
                device.requestConnection(FidoConnection::class.java) { connection ->
                    run { SecurityKeyOperations.run(operation, connection.value, commandState) }
                }
            } else if (device.supportsConnection(SmartCardConnection::class.java)) {
                device.requestConnection(SmartCardConnection::class.java) { connection ->
                    run { SecurityKeyOperations.run(operation, connection.value, commandState) }
                }
            } else {
                finishWithError(SecurityKeyOperations.UNSUPPORTED)
            }
        }

        /** 连接回调在 yubikit 的后台线程：在那里等结果，结果回主线程。 */
        private inline fun run(block: () -> Map<String, Any?>) {
            try {
                finish(block())
            } catch (error: CtapException) {
                val code = SecurityKeyOperations.errorCodeOf(error)
                finishWithError(code, SecurityKeyOperations.retriesOf(error))
            } catch (_: CommandException) {
                finishWithError(SecurityKeyOperations.TRANSPORT)
            } catch (_: IOException) {
                // 通信中途拿走钥匙。
                finishWithError(SecurityKeyOperations.TRANSPORT)
            } catch (_: Exception) {
                // yubikit 报的其他错（不支持的钥匙等）全收在这，它在后台线程，漏出去整个进程就没了。
                finishWithError(SecurityKeyOperations.UNSUPPORTED)
            }
        }

        private fun stage(name: String) {
            main.post {
                if (!finished.get()) channel.invokeMethod("stage", name)
            }
        }

        private fun finish(value: Map<String, Any?>) = complete { result.success(value) }

        fun finishWithError(code: String, retries: Int? = null) = complete {
            result.error(code, null, retries?.let { mapOf("pinRetries" to it) })
        }

        private fun complete(deliver: () -> Unit) {
            if (!finished.compareAndSet(false, true)) return
            operation.wipe()
            state?.cancel()
            main.post {
                if (pending === this) pending = null
                stopDiscovery(this)
                deliver()
            }
        }
    }

    fun dispose() {
        pending?.finishWithError(SecurityKeyOperations.CANCELLED)
        channel.setMethodCallHandler(null)
    }

    /**
     * yubikit 默认只认 Yubico 的厂商号。放开所有厂商的话，插着的键盘、扩展坞也会弹 USB 授权框，
     * 所以只放过带「通用 HID 接口」的设备：FIDO 钥匙是类别 HID、子类别 0、协议 0，键盘鼠标是子类别 1。
     * 没授权时读不了 HID 报告描述符，只能看接口。带通用 HID 的别的设备（比如有按键的耳机）仍会弹框。
     *
     * 判断要放在 [checkVendorProductIds]：[checkUsbDevice] 是授权以后才调的（UsbYubiKeyManager），放那里拦不住弹框。
     * 只按厂商号找设备：yubikit 3.1.0 首次扫描时把 deviceId 当 productId 传进来（UsbDeviceManager），按产品号比会漏掉已插着的钥匙。
     */
    private class FidoDeviceFilter(private val usbManager: UsbManager) : DeviceFilter() {
        override fun checkVendorProductIds(vendorId: Int, productId: Int): Boolean =
            usbManager.deviceList.values.any { it.vendorId == vendorId && hasGenericHid(it) }

        override fun checkUsbDevice(usbManager: UsbManager, usbDevice: UsbDevice): Boolean =
            hasGenericHid(usbDevice)

        private fun hasGenericHid(usbDevice: UsbDevice): Boolean =
            (0 until usbDevice.interfaceCount).any { index ->
                val usbInterface = usbDevice.getInterface(index)
                usbInterface.interfaceClass == UsbConstants.USB_CLASS_HID &&
                    usbInterface.interfaceSubclass == 0 &&
                    usbInterface.interfaceProtocol == 0
            }
    }

    private companion object {
        val nfcConfiguration: NfcConfiguration = NfcConfiguration()
            .skipNdefCheck(true)
            .handleUnavailableNfc(false)
    }
}
