package top.xdwa.shun

import android.app.Activity
import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import java.lang.ref.WeakReference

/**
 * 进程里唯一的 Flutter 引擎，和跟它同寿命的通道（R22）。
 *
 * SSH 会话、终端、插件会话都活在 Dart 里，Dart 活在引擎里。原来引擎归 MainActivity：
 * 返回手势、从最近任务划掉、画中画小窗关掉都会结束 Activity，引擎跟着销毁，会话全没了，
 * 前台服务和「SSH 会话正在运行」的通知却还挂着（R17 发现的问题 2）。现在引擎归进程：
 * 有会话（保活服务开着或正在开）时 Activity 走了引擎也留着，下次打开界面接回同一个引擎；
 * 没有会话时照旧随 Activity 销毁，下次是干净的冷启动。
 *
 * 跟引擎同寿命的：连接通道（保活服务、网络变化、锁屏查询）和插件桥（插件会话的 Binder 连接）。
 * 它们以前在 Activity.onDestroy 里释放，引擎留着而它们被释放的话，Dart 以为 Mosh 会话还在，
 * 底下的 Binder 已经断了。要用 Activity 的（选目录、UU、RustDesk、画中画）仍归 MainActivity。
 */
object ProcessEngine {
    private var engine: FlutterEngine? = null
    private var connection: ConnectionChannel? = null
    private var plugins: PluginBridge? = null
    private var activity: WeakReference<Activity>? = null

    fun obtain(context: Context): FlutterEngine {
        engine?.let { return it }
        val app = context.applicationContext
        // 自己建的引擎默认自动注册插件（GeneratedPluginRegistrant）；FlutterActivity 对外部给的引擎不再注册。
        // Dart 入口不在这里跑：Activity 第一次 onStart 时发现引擎还没执行 Dart，按启动 intent 的路由去跑。
        val created = FlutterEngine(app)
        val messenger = created.dartExecutor.binaryMessenger
        connection = ConnectionChannel(app, messenger)
        plugins = PluginBridge(app, messenger)
        created.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
            override fun onPreEngineRestart() = Unit

            override fun onEngineWillDestroy() = release(created)
        })
        engine = created
        return created
    }

    /** Activity 走了引擎还留不留：有会话（保活服务开着或正在开）就留。 */
    val keepWithoutActivity: Boolean
        get() = SshKeepAliveService.requested

    /** 现在挂着引擎的界面；没有时为 null。只用来弹通知权限申请这类必须有 Activity 的事。 */
    var currentActivity: Activity?
        get() = activity?.get()
        set(value) {
            activity = value?.let { WeakReference(it) }
        }

    private fun release(target: FlutterEngine) {
        if (engine !== target) return
        // 先停保活服务再撤通道：Dart 已经没了，服务和通知不能留成孤儿。
        connection?.dispose()
        connection = null
        plugins?.dispose()
        plugins = null
        engine = null
    }
}
