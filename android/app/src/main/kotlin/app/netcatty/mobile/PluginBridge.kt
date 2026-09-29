package app.netcatty.mobile

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.RemoteException
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONException
import org.json.JSONObject
import top.xdwa.xwshun.plugin.v1.CallerVerifier
import top.xdwa.xwshun.plugin.v1.IXwshunHost
import top.xdwa.xwshun.plugin.v1.IXwshunProvider
import top.xdwa.xwshun.plugin.v1.PluginContract
import top.xdwa.xwshun.plugin.v1.SignerDigests
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * 独立插件 APK 的 Android 平台边界（X02）。
 *
 * 分工：这里只做系统层面的事——按 action 查询、读清单里的静态描述符、读系统报告的签名证书、
 * 显式组件绑定、逐事务核对回调方。**准入判定（批准、换签、冒用 ID）全部在 Dart 的 PluginRegistry**，
 * 这里不重复一套规则；`connect` 只在绑定前再核一次「证书仍是批准的那张」，防止判定和绑定之间包被换掉。
 *
 * 批准之前不绑定、不执行插件任何代码：描述符来自清单 meta-data 指向的 raw 资源，读它不会启动插件进程。
 */
class PluginBridge(
    context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val context = context.applicationContext
    private val pm = this.context.packageManager
    private val channel = MethodChannel(messenger, "app.netcatty.mobile/plugins")
    private val main = Handler(Looper.getMainLooper())

    /** 跟插件的 Binder 调用都放这里：对方可能卡住，不能卡 UI 线程。 */
    private val binderCalls = Executors.newSingleThreadExecutor()

    /** 按包名。一个包同时只有一条连接。只在主线程读写。 */
    private val connections = mutableMapOf<String, Connection>()

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "discover" -> result.success(discover())
            "inspect" -> result.success(inspect(call.argument<String>("package") ?: ""))
            "connect" -> connect(
                packageName = call.argument<String>("package") ?: "",
                serviceClass = call.argument<String>("serviceClass") ?: "",
                pluginId = call.argument<String>("pluginId") ?: "",
                approvedSha256 = call.argument<String>("sha256") ?: "",
                result = result,
            )
            "ping" -> ping(
                call.argument<String>("package") ?: "",
                call.argument<Number>("nonce")?.toLong() ?: 0L,
                result,
            )
            "disconnect" -> {
                disconnect(call.argument<String>("package") ?: "", "用户断开")
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun queryProviders(intent: Intent, flags: Int): List<ResolveInfo> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.queryIntentServices(intent, PackageManager.ResolveInfoFlags.of(flags.toLong()))
        } else {
            @Suppress("DEPRECATION")
            pm.queryIntentServices(intent, flags)
        }

    /** 所有声明了插件 action 的服务。一个包只允许一个：多于一个整包判为描述符有问题，不挑其中一个用。 */
    private fun discover(): List<Map<String, Any?>> {
        val byPackage = queryProviders(
            Intent(PluginContract.ACTION_PROVIDER),
            PackageManager.GET_META_DATA,
        ).groupBy { it.serviceInfo.packageName }
        return byPackage.map { (packageName, services) ->
            val service = services.first().serviceInfo
            val out = mutableMapOf<String, Any?>(
                "package" to packageName,
                "serviceClass" to service.name,
                "exported" to service.exported,
                "uid" to service.applicationInfo.uid,
            )
            try {
                val info = pm.getPackageInfo(packageName, 0)
                out["versionName"] = info.versionName
                out["versionCode"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    info.longVersionCode
                } else {
                    @Suppress("DEPRECATION")
                    info.versionCode.toLong()
                }
                out["signers"] = SignerDigests.of(pm, packageName).map {
                    mapOf("sha256" to it.sha256, "androidDebug" to it.androidDebug)
                }
            } catch (e: PackageManager.NameNotFoundException) {
                out["problem"] = "查询到服务后包又不见了（可能刚被卸载）"
                return@map out
            }
            when {
                services.size > 1 -> out["problem"] = "一个安装包声明了 ${services.size} 个插件服务，只允许一个"
                !service.exported -> out["problem"] = "插件服务没有导出，宿主无法绑定"
                else -> readDescriptor(service.metaData?.getInt(PluginContract.META_DESCRIPTOR, 0) ?: 0, service.applicationInfo)
                    .let { (json, problem) ->
                        out["descriptor"] = json
                        out["problem"] = problem
                    }
            }
            out
        }
    }

    private fun readDescriptor(resId: Int, app: android.content.pm.ApplicationInfo): Pair<String?, String?> {
        if (resId == 0) return null to "插件服务没有声明 ${PluginContract.META_DESCRIPTOR}"
        return try {
            pm.getResourcesForApplication(app).openRawResource(resId).use { input ->
                val buffer = ByteArrayOutputStream()
                val chunk = ByteArray(4096)
                while (true) {
                    val n = input.read(chunk)
                    if (n < 0) break
                    buffer.write(chunk, 0, n)
                    if (buffer.size() > PluginContract.MAX_DESCRIPTOR_BYTES) {
                        return null to "描述符超过 16 KiB"
                    }
                }
                buffer.toString(Charsets.UTF_8.name()) to null
            }
        } catch (e: Exception) {
            null to "读不出描述符资源"
        }
    }

    /** 某个包为什么没出现在插件列表里（PLG03）。只用于诊断，不影响准入。 */
    private fun inspect(packageName: String): Map<String, Any?> {
        if (packageName.isBlank()) return mapOf("visible" to false, "reason" to "包名为空")
        try {
            pm.getPackageInfo(packageName, 0)
        } catch (e: PackageManager.NameNotFoundException) {
            return mapOf(
                "visible" to false,
                "reason" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    "看不到这个包：没有安装，或者它没有声明插件 action。Android 11 起本 App 只能看到声明了 " +
                        "${PluginContract.ACTION_PROVIDER} 的插件（本 App 故意不申请「查看全部应用」权限）"
                } else {
                    "这个包没有安装"
                },
            )
        }
        val services = queryProviders(
            Intent(PluginContract.ACTION_PROVIDER).setPackage(packageName),
            PackageManager.GET_META_DATA,
        )
        return mapOf(
            "visible" to true,
            "reason" to if (services.isEmpty()) {
                "装了，但它没有声明插件服务 action，不是本 App 的插件"
            } else {
                "装了，声明了 ${services.size} 个插件服务"
            },
        )
    }

    private fun connect(
        packageName: String,
        serviceClass: String,
        pluginId: String,
        approvedSha256: String,
        result: MethodChannel.Result,
    ) {
        if (packageName.isBlank() || serviceClass.isBlank() || pluginId.isBlank() || approvedSha256.isBlank()) {
            result.error("BAD_ARGS", "缺少包名、服务、pluginId 或批准的证书", null)
            return
        }
        disconnect(packageName, "被新的连接取代")
        // 绑定前再核一次：服务还在且仍声明 action、证书仍是批准时那张。Dart 那边判定之后包可能已被换掉。
        val stillDeclared = queryProviders(
            Intent(PluginContract.ACTION_PROVIDER).setPackage(packageName),
            0,
        ).any { it.serviceInfo.name == serviceClass && it.serviceInfo.exported }
        if (!stillDeclared) {
            result.error("NOT_FOUND", "插件服务已不在设备上，或不再声明插件 action", null)
            return
        }
        val actual = try {
            SignerDigests.digests(SignerDigests.of(pm, packageName))
        } catch (e: PackageManager.NameNotFoundException) {
            result.error("NOT_FOUND", "插件已被卸载", null)
            return
        }
        if (actual != setOf(approvedSha256)) {
            result.error("SIGNER_CHANGED", "插件的签名证书和批准时不同，已拒绝绑定", null)
            return
        }
        val connection = Connection(packageName, pluginId, approvedSha256, result)
        // 显式组件：绑定的一定是这个包里的这个类，不交给系统按 action 挑。
        val intent = Intent(PluginContract.ACTION_PROVIDER)
            .setComponent(ComponentName(packageName, serviceClass))
        connections[packageName] = connection
        val bound = try {
            context.bindService(intent, connection, Context.BIND_AUTO_CREATE)
        } catch (e: SecurityException) {
            false
        }
        if (!bound) {
            connections.remove(packageName)
            connection.fail("BIND_FAILED", "系统拒绝绑定插件服务")
            runCatching { context.unbindService(connection) }
        }
    }

    private fun ping(packageName: String, nonce: Long, result: MethodChannel.Result) {
        val provider = connections[packageName]?.provider
        if (provider == null) {
            result.error("NOT_CONNECTED", "没有连着这个插件", null)
            return
        }
        binderCalls.execute {
            try {
                val echoed = provider.ping(nonce)
                main.post { result.success(echoed) }
            } catch (e: SecurityException) {
                main.post { result.error("REFUSED", "插件拒绝了宿主：${e.message}", null) }
            } catch (e: RemoteException) {
                main.post { result.error("DEAD", "插件进程已不在", null) }
            }
        }
    }

    private fun disconnect(packageName: String, reason: String) {
        val connection = connections.remove(packageName) ?: return
        connection.close(reason)
    }

    fun dispose() {
        for (packageName in connections.keys.toList()) disconnect(packageName, "宿主退出")
        channel.setMethodCallHandler(null)
        binderCalls.shutdownNow()
    }

    private fun emit(event: Map<String, Any?>) = main.post { channel.invokeMethod("event", event) }

    /** 一次绑定。handshake 成功前 [provider] 为 null，Dart 拿不到任何可调用的东西。 */
    private inner class Connection(
        val packageName: String,
        val pluginId: String,
        approvedSha256: String,
        private var pending: MethodChannel.Result?,
    ) : ServiceConnection {
        @Volatile var provider: IXwshunProvider? = null
        @Volatile private var closed = false
        private var binder: IBinder? = null
        private val verifier = CallerVerifier(context, packageName, setOf(approvedSha256))
        private var lastSequence = 0L
        private val deathRecipient = IBinder.DeathRecipient {
            main.post {
                if (connections[packageName] === this) connections.remove(packageName)
                close("插件进程已退出")
            }
        }

        /** 交给插件的回调。每个事务都核对调用方：这个 Binder 被转交给别的 App 也调不进来。 */
        val host = object : IXwshunHost.Stub() {
            override fun onProviderEvent(generation: Long, sequence: Long, event: String?) {
                try {
                    verifier.requireTrustedCaller()
                } catch (e: SecurityException) {
                    // oneway 调用，异常回不到对方；记下来，照样什么都不做。
                    Log.w(TAG, "拒绝 onProviderEvent：${e.message}")
                    emit(mapOf("type" to "rejectedCall", "package" to packageName, "method" to "onProviderEvent", "reason" to e.message))
                    return
                }
                if (event == null || event.length > PluginContract.MAX_EVENT_CHARS) return
                synchronized(this@Connection) {
                    if (closed || sequence <= lastSequence) return
                    lastSequence = sequence
                }
                emit(mapOf("type" to "providerEvent", "package" to packageName, "generation" to generation, "sequence" to sequence, "event" to event))
            }
        }

        override fun onServiceConnected(name: ComponentName, service: IBinder) {
            if (closed) return
            binder = service
            runCatching { service.linkToDeath(deathRecipient, 0) }
            val candidate = IXwshunProvider.Stub.asInterface(service)
            binderCalls.execute {
                val outcome: Pair<String?, String?> = try {
                    val descriptor = candidate.handshake(PluginContract.HOST_API_MAJOR, PluginContract.HOST_API_MINOR, host)
                    val claimed = try {
                        JSONObject(descriptor ?: "").optString("pluginId")
                    } catch (e: JSONException) {
                        ""
                    }
                    if (claimed != pluginId) null to "插件握手时自称 $claimed，与批准的 $pluginId 不符" else descriptor to null
                } catch (e: SecurityException) {
                    null to "插件拒绝了宿主：${e.message}"
                } catch (e: IllegalStateException) {
                    null to "插件不接受宿主的 API 版本：${e.message}"
                } catch (e: RemoteException) {
                    null to "握手时插件进程退出"
                }
                main.post {
                    val (descriptor, error) = outcome
                    if (closed) return@post
                    if (error != null) {
                        if (connections[packageName] === this) connections.remove(packageName)
                        fail("HANDSHAKE_FAILED", error)
                        close(error)
                    } else {
                        provider = candidate
                        pending?.success(mapOf("descriptor" to descriptor, "package" to packageName))
                        pending = null
                    }
                }
            }
        }

        override fun onServiceDisconnected(name: ComponentName) {
            if (connections[packageName] === this) connections.remove(packageName)
            close("插件服务断开")
        }

        fun fail(code: String, message: String) {
            pending?.error(code, message, null)
            pending = null
        }

        fun close(reason: String) {
            synchronized(this@Connection) {
                if (closed) return
                closed = true
            }
            provider = null
            fail("CLOSED", reason)
            binder?.let { runCatching { it.unlinkToDeath(deathRecipient, 0) } }
            runCatching { context.unbindService(this) }
            emit(mapOf("type" to "closed", "package" to packageName, "reason" to reason))
        }
    }

    private companion object {
        const val TAG = "XwshunPlugins"
    }
}
