package top.xdwa.shun

import android.Manifest
import android.app.KeyguardManager
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Dart 和 Android 之间关于连接生命周期的那条通道（R22），跟引擎同寿命（见 [ProcessEngine]）。
 *
 * Dart → 这里：开关保活服务（带通知上写什么、这是第几代）、查手机锁没锁。
 * 这里 → Dart：通知上点了「全部断开」、保活服务被别人停了或没开起来、默认网络换了。
 * 事件都带保活的代次：Dart 只认当前这一代，上一代服务迟到的「被停了」不会把新开的会话也停掉（LIFE05）。
 */
class ConnectionChannel(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, "top.xdwa.shun/connection")
    private val main = Handler(Looper.getMainLooper())
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var lastNetwork: Map<String, Any?> = mapOf("available" to false)

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setActive" -> {
                    val active = call.argument<Boolean>("active") == true
                    val generation = call.argument<Number>("generation")?.toInt() ?: 0
                    val title = call.argument<String>("title")
                    val text = call.argument<String>("text")
                    result.success(if (active) start(generation, title, text) else stop())
                }
                "isDeviceLocked" -> result.success(isDeviceLocked())
                "networkState" -> result.success(lastNetwork)
                // iOS 用的两个方法；Android 没有对应的东西。
                "beginBackgroundGrace", "endBackgroundGrace" -> result.success(null)
                else -> result.notImplemented()
            }
        }
        SshKeepAliveService.listener = { type, generation, reason ->
            channel.invokeMethod(
                "keepAlive",
                mapOf("type" to type, "generation" to generation, "reason" to reason),
            )
        }
        watchNetwork()
    }

    fun dispose() {
        SshKeepAliveService.listener = null
        // 引擎没了，会话也就没了：服务和通知不能留下来（R17 发现的问题 2）。
        stop()
        networkCallback?.let { runCatching { connectivity?.unregisterNetworkCallback(it) } }
        networkCallback = null
        channel.setMethodCallHandler(null)
    }

    private fun start(generation: Int, title: String?, text: String?): Map<String, Any?> {
        val content = SshKeepAliveService.Content(generation, title, text)
        if (SshKeepAliveService.requested && !SshKeepAliveService.stopWhenStarted) {
            SshKeepAliveService.update(context, content)
            return status(started = true)
        }
        requestNotificationPermission()
        return try {
            SshKeepAliveService.start(context, content)
            status(started = true)
        } catch (error: IllegalStateException) {
            // Android 12+ 在后台启动前台服务抛 ForegroundServiceStartNotAllowedException（IllegalStateException 的子类）。
            // 不重试、不换别的办法硬开：如实告诉 Dart，回到前台再开。
            status(started = false, error = error.javaClass.simpleName)
        }
    }

    private fun stop(): Map<String, Any?> {
        SshKeepAliveService.stop(context)
        return status(started = false)
    }

    private fun status(started: Boolean, error: String? = null): Map<String, Any?> = mapOf(
        "started" to started,
        "notifications" to NotificationManagerCompat.from(context).areNotificationsEnabled(),
        "error" to error,
    )

    /** 手机锁着、要密码/图案/指纹才能解开。没设锁屏密码的手机按「没锁」算：谁拿到都打得开，锁不锁一样。 */
    private fun isDeviceLocked(): Boolean =
        context.getSystemService(KeyguardManager::class.java)?.isDeviceLocked == true

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val activity = ProcessEngine.currentActivity ?: return
        ActivityCompat.requestPermissions(activity, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 701)
    }

    /**
     * 只报默认网络换没换、有没有，不报「断了」该怎么办：Wi-Fi 断开时系统自己会掐掉绑在它上面的 socket，
     * 回到 Wi-Fi 时蜂窝上的连接还可能活着。连接是死是活由 Dart 逐条去探，不因为一条网络通知就全部断开（LIFE03）。
     */
    private fun watchNetwork() {
        val manager = connectivity ?: return
        // 先按眼下的默认网络填一份：回调要过一会儿才来，这期间 Dart 来问不能答「没有网络」，
        // 否则断线恢复会白等。
        manager.activeNetwork?.let { lastNetwork = stateOf(it, manager.getNetworkCapabilities(it)) }
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = report(network, manager.getNetworkCapabilities(network))

            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) =
                report(network, capabilities)

            override fun onLost(network: Network) {
                main.post {
                    if (lastNetwork["network"] == network.toString()) emitNetwork(mapOf("available" to false))
                }
            }
        }
        try {
            manager.registerDefaultNetworkCallback(callback)
            networkCallback = callback
        } catch (error: RuntimeException) {
            // 注册不上（极少见，比如系统里本 App 的回调太多）：Dart 那边收不到网络事件，退回只靠探活和 socket 报错。
        }
    }

    private fun report(network: Network, capabilities: NetworkCapabilities?) {
        val state = stateOf(network, capabilities)
        main.post { emitNetwork(state) }
    }

    private fun stateOf(network: Network, capabilities: NetworkCapabilities?): Map<String, Any?> {
        val transports = buildList {
            if (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true) add("wifi")
            if (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true) add("cellular")
            if (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true) add("ethernet")
            if (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true) add("vpn")
        }
        return mapOf(
            "available" to true,
            "network" to network.toString(),
            "transports" to transports,
            "validated" to (capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true),
        )
    }

    private fun emitNetwork(state: Map<String, Any?>) {
        if (state == lastNetwork) return
        lastNetwork = state
        channel.invokeMethod("network", state)
    }
}
