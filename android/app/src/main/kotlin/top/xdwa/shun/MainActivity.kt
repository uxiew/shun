package top.xdwa.shun

import android.app.PictureInPictureParams
import android.content.Context
import android.content.res.Configuration
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // 这几个要用 Activity（选目录的 startActivityForResult、拉起 UU/RustDesk、画中画），跟着界面建、跟着界面撤。
    // 跟引擎同寿命的（连接、插件桥）在 ProcessEngine 里。
    private var documentTreeChannel: DocumentTreeChannel? = null
    private var pictureInPictureChannel: MethodChannel? = null
    private var uuRemoteBridge: UuRemoteBridge? = null
    private var rustDeskBridge: RustDeskBridge? = null

    /**
     * UU 远程的回调（X06）不由这里接，由 UuCallbackActivity 接（原因写在那里）。
     * 这里只防一种情况：别的 App 用显式组件名把回调地址直接塞给 MainActivity。那不是 UU 回调的正常路径，
     * 不当回调处理；data 要去掉，否则 Flutter 会把它当成深链路由。
     */
    override fun onCreate(savedInstanceState: Bundle?) {
        if (UuRemoteBridge.isCallback(intent)) intent = UuRemoteBridge.stripped(intent)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        if (UuRemoteBridge.isCallback(intent)) return
        super.onNewIntent(intent)
    }

    /** 引擎归进程（R22），见 ProcessEngine。 */
    override fun provideFlutterEngine(context: Context): FlutterEngine = ProcessEngine.obtain(context)

    /**
     * 有会话时界面走了引擎也留着，会话照常在后台跑（所有者 10-08 定：从最近任务划掉 App 不断开，
     * 要断从通知上点「全部断开」）；没有会话就跟着界面销毁，下次冷启动。
     */
    override fun shouldDestroyEngineWithHost(): Boolean =
        !isChangingConfigurations && !ProcessEngine.keepWithoutActivity

    /**
     * 在首页再按返回：退到后台，不结束 Activity。和 Android 12 起系统对启动器根 Activity 的默认做法一样；
     * FlutterActivity 重写了返回键，默认会 finish()，在 Android 7–11、以及没开预测性返回的版本上
     * 一个返回手势就把会话全断了（R17 发现的问题 2）。
     */
    override fun popSystemNavigator(): Boolean {
        moveTaskToBack(true)
        return true
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ProcessEngine.currentActivity = this
        documentTreeChannel = DocumentTreeChannel(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        uuRemoteBridge = UuRemoteBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        rustDeskBridge = RustDeskBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        pictureInPictureChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "top.xdwa.shun/picture_in_picture",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "isSupported" -> result.success(isPictureInPictureSupported())
                    "enter" -> {
                        if (!isPictureInPictureSupported()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val width = (call.argument<Number>("aspectWidth")?.toInt() ?: 16)
                            .coerceAtLeast(1)
                        val height = (call.argument<Number>("aspectHeight")?.toInt() ?: 9)
                            .coerceAtLeast(1)
                        val params = PictureInPictureParams.Builder()
                            .setAspectRatio(Rational(width, height))
                            .build()
                        result.success(enterPictureInPictureMode(params))
                    }
                    // Android displays the live Flutter surface, so it doesn't need
                    // the text frames used by iOS.
                    "update", "stop" -> result.success(null)
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pictureInPictureChannel?.invokeMethod(
            "stateChanged",
            mapOf("active" to isInPictureInPictureMode),
        )
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (documentTreeChannel?.onActivityResult(requestCode, resultCode, data) == true) {
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    /** 界面和引擎脱开（Activity 销毁、引擎可能留着）：只撤要用 Activity 的通道，连接和插件桥不动。 */
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        documentTreeChannel?.dispose()
        documentTreeChannel = null
        uuRemoteBridge?.dispose()
        uuRemoteBridge = null
        rustDeskBridge?.dispose()
        rustDeskBridge = null
        pictureInPictureChannel?.setMethodCallHandler(null)
        pictureInPictureChannel = null
        if (ProcessEngine.currentActivity === this) ProcessEngine.currentActivity = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun isPictureInPictureSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
}
