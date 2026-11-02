package top.xdwa.shun

import android.app.PictureInPictureParams
import android.content.ComponentName
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
    private var qrScanChannel: QrScanChannel? = null
    private var appLockChannel: AppLockChannel? = null
    private var pictureInPictureChannel: MethodChannel? = null
    private var uuRemoteBridge: UuRemoteBridge? = null
    private var rustDeskBridge: RustDeskBridge? = null
    private var tailscaleAppBridge: TailscaleAppBridge? = null

    // 自己拉起、等结果的页面（选文件、扫码）开着：应用锁在这种离开上宽松一点，见 AppLockController。
    private var launchedOwnActivity = false

    /**
     * MainActivity 必须导出（启动器要用），所以别的 App 能用显式组件名带任意 extras 和 data 启动它，
     * FlutterActivity 又会照单全收：`cached_engine_id` 指向一个不存在的引擎，冷启动在 provideFlutterEngine 之前就抛
     * IllegalStateException，整个 App 崩掉（X11 在 release 包上实测）；`route` 和 data 被当成路由推给导航；
     * `background_mode` 改窗口背景；`dart_entrypoint_args` 交给 Dart 入口。本 App 自己从不往这里放 extras 和 data
     * （通知点开用的是启动器那条 Intent），所以进来的一律换成普通启动：ACTION_MAIN，只留 category 和 flags。
     * 逐个重写 getCachedEngineId 这类方法也行，但 Flutter 哪天多读一个 extra 这里就漏了。
     *
     * UU 远程的回调（X06）不由这里接，由 UuCallbackActivity 接（原因写在那里）。别的 App 把回调地址直接塞给
     * MainActivity 不是 UU 回调的正常路径，不当回调处理。
     */
    override fun onCreate(savedInstanceState: Bundle?) {
        intent = withoutPayload(intent)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        if (UuRemoteBridge.isCallback(intent)) return
        val clean = withoutPayload(intent)
        setIntent(clean)
        super.onNewIntent(clean)
    }

    override fun onResume() {
        super.onResume()
        launchedOwnActivity = false
        ProcessEngine.applyWindowSecurity(this)
        ProcessEngine.onActivityResumed()
    }

    override fun onPause() {
        super.onPause()
        // 画中画也走 onPause，但那窗是用户要看的，不盖。
        if (isInPictureInPictureMode) return
        // 系统马上要截最近任务的缩略图，Dart 画遮罩赶不上（API 30 模拟器实测：缩略图里主机列表清清楚楚）。
        // 这时加 FLAG_SECURE，缩略图是黑的；onResume 再按 Dart 说的恢复，不影响终端页截屏（R44）。
        if (ProcessEngine.protectRecents) {
            window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
        }
        appLockChannel?.onActivityPaused(launchedOwnActivity)
    }

    override fun startActivityForResult(intent: Intent, requestCode: Int, options: Bundle?) {
        launchedOwnActivity = true
        super.startActivityForResult(intent, requestCode, options)
    }

    /** 系统的权限框不走上面那个方法（requestPermissions 是 final），弹之前在这里说一声。 */
    fun noteOwnActivity() {
        launchedOwnActivity = true
    }

    private fun withoutPayload(source: Intent?): Intent =
        Intent(Intent.ACTION_MAIN).apply {
            component = ComponentName(this@MainActivity, MainActivity::class.java)
            source?.categories?.forEach(::addCategory)
            source?.let { flags = it.flags }
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
        ProcessEngine.applyWindowSecurity(this)
        ProcessEngine.applyProtectRecents(this)
        documentTreeChannel = DocumentTreeChannel(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        qrScanChannel = QrScanChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        appLockChannel = AppLockChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        uuRemoteBridge = UuRemoteBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        rustDeskBridge = RustDeskBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        tailscaleAppBridge = TailscaleAppBridge(this, flutterEngine.dartExecutor.binaryMessenger)
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
        if (qrScanChannel?.onActivityResult(requestCode, resultCode, data) == true) {
            return
        }
        if (appLockChannel?.onActivityResult(requestCode, resultCode) == true) {
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    /** 界面和引擎脱开（Activity 销毁、引擎可能留着）：只撤要用 Activity 的通道，连接和插件桥不动。 */
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        documentTreeChannel?.dispose()
        documentTreeChannel = null
        qrScanChannel?.dispose()
        qrScanChannel = null
        appLockChannel?.dispose()
        appLockChannel = null
        uuRemoteBridge?.dispose()
        uuRemoteBridge = null
        rustDeskBridge?.dispose()
        rustDeskBridge = null
        tailscaleAppBridge?.dispose()
        tailscaleAppBridge = null
        pictureInPictureChannel?.setMethodCallHandler(null)
        pictureInPictureChannel = null
        if (ProcessEngine.currentActivity === this) ProcessEngine.currentActivity = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun isPictureInPictureSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
}
