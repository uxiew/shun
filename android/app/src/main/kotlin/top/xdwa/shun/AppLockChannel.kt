package top.xdwa.shun

import android.app.Activity
import android.app.KeyguardManager
import android.content.Intent
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** 验证走哪条路，只看系统版本。拆出来是为了能在 JVM 上测：手上只有 API 30 的模拟器。 */
internal enum class AuthRoute {
    /** API 30 起：BiometricPrompt 直接写允许哪些验证方式。 */
    PROMPT_AUTHENTICATORS,

    /** API 29：只有「允许回退到 PIN」这一个开关。 */
    PROMPT_CREDENTIAL_ALLOWED,

    /** API 28：BiometricPrompt 不认 PIN，负按钮和出错时转到系统 PIN 页。 */
    PROMPT_THEN_CONFIRM,

    /** API 24–27，或者 API 30 以前选了直接用 PIN：系统 PIN 页。 */
    CONFIRM_CREDENTIAL,
}

internal fun authRoute(sdk: Int, pinOnly: Boolean): AuthRoute = when {
    sdk >= 30 -> AuthRoute.PROMPT_AUTHENTICATORS
    pinOnly -> AuthRoute.CONFIRM_CREDENTIAL
    sdk == 29 -> AuthRoute.PROMPT_CREDENTIAL_ALLOWED
    sdk == 28 -> AuthRoute.PROMPT_THEN_CONFIRM
    else -> AuthRoute.CONFIRM_CREDENTIAL
}

/** API 30 起 setAllowedAuthenticators 的参数。常量从外面传：JVM 单测里没有 BiometricManager。 */
internal fun allowedAuthenticators(
    pinOnly: Boolean,
    allowWeak: Boolean,
    weak: Int,
    strong: Int,
    credential: Int,
): Int = when {
    pinOnly -> credential
    allowWeak -> weak or credential
    else -> strong or credential
}

/**
 * 应用锁（R46）和 sudo 键（R66）的系统验证。只用手机自己的生物识别和 PIN，不自建密码体系。
 *
 * 用框架的 BiometricPrompt，不用 local_auth / androidx.biometric：它们要 FragmentActivity，
 * 而 MainActivity 是 FlutterActivity，换基类要重测 R22 那一整套（plan/v3/docs/21 第 5 节）。
 */
class AppLockChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    companion object {
        private const val CHANNEL = "top.xdwa.shun/app_lock"
        private const val REQUEST_CONFIRM = 8045
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private val keyguard = activity.getSystemService(KeyguardManager::class.java)
    private var pending: MethodChannel.Result? = null
    private var cancellation: CancellationSignal? = null

    init {
        channel.setMethodCallHandler(::handleCall)
    }

    private fun handleCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isDeviceSecure" -> result.success(keyguard.isDeviceSecure)
            "authenticate" -> authenticate(call, result)
            "setProtectRecents" -> {
                ProcessEngine.protectRecents = call.argument<Boolean>("enabled") == true
                ProcessEngine.applyProtectRecents(activity)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun authenticate(call: MethodCall, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("busy", "already authenticating", null)
            return
        }
        if (!keyguard.isDeviceSecure) {
            result.success(outcome("unavailable"))
            return
        }
        pending = result
        val title = call.argument<String>("title") ?: "shun"
        val pinOnly = call.argument<Boolean>("pinOnly") == true
        val allowWeak = call.argument<Boolean>("allowWeak") == true
        when (authRoute(Build.VERSION.SDK_INT, pinOnly)) {
            AuthRoute.PROMPT_AUTHENTICATORS -> promptWithAuthenticators(title, pinOnly, allowWeak)
            AuthRoute.PROMPT_CREDENTIAL_ALLOWED -> promptCredentialAllowed(title)
            AuthRoute.PROMPT_THEN_CONFIRM -> promptThenConfirm(title)
            AuthRoute.CONFIRM_CREDENTIAL -> confirmCredential(title)
        }
    }

    private fun promptWithAuthenticators(title: String, pinOnly: Boolean, allowWeak: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val allowed = allowedAuthenticators(
            pinOnly,
            allowWeak,
            weak = BiometricManager.Authenticators.BIOMETRIC_WEAK,
            strong = BiometricManager.Authenticators.BIOMETRIC_STRONG,
            credential = BiometricManager.Authenticators.DEVICE_CREDENTIAL,
        )
        // 允许 PIN 时不能设负按钮，设了直接抛 IllegalArgumentException。
        show(
            BiometricPrompt.Builder(activity)
                .setTitle(title)
                .setConfirmationRequired(false)
                .setAllowedAuthenticators(allowed)
                .build(),
            title,
        )
    }

    @Suppress("DEPRECATION")
    private fun promptCredentialAllowed(title: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        show(
            BiometricPrompt.Builder(activity)
                .setTitle(title)
                .setConfirmationRequired(false)
                .setDeviceCredentialAllowed(true)
                .build(),
            title,
        )
    }

    private fun promptThenConfirm(title: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return
        show(
            BiometricPrompt.Builder(activity)
                .setTitle(title)
                .setNegativeButton("用 PIN", activity.mainExecutor) { _, _ -> confirmCredential(title) }
                .build(),
            title,
        )
    }

    private fun show(prompt: BiometricPrompt, title: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return
        val signal = CancellationSignal()
        cancellation = signal
        prompt.authenticate(
            signal,
            activity.mainExecutor,
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    finish("success")
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    when (errorCode) {
                        BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED,
                        BiometricPrompt.BIOMETRIC_ERROR_CANCELED,
                        BiometricPrompt.BIOMETRIC_ERROR_TIMEOUT,
                        -> finish("canceled")
                        // 指纹坏了、没录、锁住了：走系统 PIN 页，不把人挡在外面。
                        BiometricPrompt.BIOMETRIC_ERROR_NO_BIOMETRICS,
                        BiometricPrompt.BIOMETRIC_ERROR_HW_NOT_PRESENT,
                        BiometricPrompt.BIOMETRIC_ERROR_HW_UNAVAILABLE,
                        BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT,
                        BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT_PERMANENT,
                        -> confirmCredential(title)
                        BiometricPrompt.BIOMETRIC_ERROR_NO_DEVICE_CREDENTIAL -> finish("unavailable")
                        else -> finish("failed", errString.toString())
                    }
                }
            },
        )
    }

    @Suppress("DEPRECATION")
    private fun confirmCredential(title: String) {
        // 废弃了但没别的换：API 24–28 只有它能验 PIN。没设屏幕锁时返回 null。
        val intent = keyguard.createConfirmDeviceCredentialIntent(title, null)
        if (intent == null) {
            finish("unavailable")
            return
        }
        activity.startActivityForResult(intent, REQUEST_CONFIRM)
    }

    fun onActivityResult(requestCode: Int, resultCode: Int): Boolean {
        if (requestCode != REQUEST_CONFIRM) return false
        finish(if (resultCode == Activity.RESULT_OK) "success" else "canceled")
        return true
    }

    /** 界面退到后台：告诉 Dart 先盖上，最近任务的缩略图和回来的第一帧都是盖住的样子。 */
    fun onActivityPaused(ownActivity: Boolean) {
        channel.invokeMethod("activityPaused", mapOf("ownActivity" to ownActivity))
    }

    private fun outcome(result: String, message: String? = null) =
        mapOf("result" to result, "message" to message)

    private fun finish(result: String, message: String? = null) {
        cancellation = null
        val waiting = pending ?: return
        pending = null
        waiting.success(outcome(result, message))
    }

    fun dispose() {
        // 验证开着时界面被系统回收：结果到不了这个实例，先算取消，不然 Dart 一直等、下次也弹不出来。
        cancellation?.cancel()
        finish("canceled")
        channel.setMethodCallHandler(null)
    }
}
