package app.netcatty.mobile

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.RemoteException
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
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
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Semaphore
import java.util.concurrent.atomic.AtomicLong

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

    /** 按包名。一个包同时只有一条连接。只在主线程读写。 */
    private val connections = mutableMapOf<String, Connection>()

    /**
     * 安装、更新、卸载、组件启停的系统广播（X04）。只转告 Dart「哪个包变了」，由 Dart 重新发现、重新核验：
     * 更新后的证书、描述符、能力都可能变，不能沿用变之前的判定。
     *
     * 运行时注册而不是写在清单里：Android 8 起这些隐式广播不再发给清单声明的接收器。
     * Android 11 起系统只把「对本 App 可见」的包的广播发过来，也就是声明了插件 action 的那些，
     * 不需要、也不申请查看全部应用。进程不在时收不到，所以插件页每次打开还会整体重新发现一次。
     */
    private val packageReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val packageName = intent.data?.schemeSpecificPart ?: return
            emitPackageChange(
                mapOf(
                    "package" to packageName,
                    "action" to when (intent.action) {
                        Intent.ACTION_PACKAGE_ADDED -> "added"
                        Intent.ACTION_PACKAGE_REPLACED -> "replaced"
                        Intent.ACTION_PACKAGE_REMOVED -> "removed"
                        else -> "changed"
                    },
                    "replacing" to intent.getBooleanExtra(Intent.EXTRA_REPLACING, false),
                ),
            )
        }
    }

    init {
        channel.setMethodCallHandler(this)
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_PACKAGE_ADDED)
            addAction(Intent.ACTION_PACKAGE_REPLACED)
            addAction(Intent.ACTION_PACKAGE_REMOVED)
            addAction(Intent.ACTION_PACKAGE_CHANGED)
            addDataScheme("package")
        }
        // 不导出：只收系统和本 App 发的广播。这几个 action 本来就只有系统能发，不导出是多一道保险。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            this.context.registerReceiver(packageReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            this.context.registerReceiver(packageReceiver, filter)
        }
    }

    private fun emitPackageChange(change: Map<String, Any?>) =
        main.post { channel.invokeMethod("packageChanged", change) }

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
                disconnect(call.argument<String>("package") ?: "", "用户断开", "disconnected")
                result.success(null)
            }
            "openSession" -> openSession(call, result)
            "resizeSession" -> withSession(call, result) { connection, session ->
                val cols = call.argument<Int>("cols") ?: 0
                val rows = call.argument<Int>("rows") ?: 0
                connection.callPlugin(result) {
                    it.resizeSession(session.handle, session.generation, cols, rows)
                    null
                }
            }
            "closeSession" -> closeSession(call, result)
            "writeSession" -> withSession(call, result) { _, session ->
                session.write(call.argument<ByteArray>("bytes") ?: ByteArray(0), result)
            }
            "ackSession" -> {
                sessionOf(call)?.second?.ack()
                result.success(null)
            }
            "sessionStats" -> result.success(sessionOf(call)?.second?.stats())
            "openSettings" -> openSettings(
                call.argument<String>("package") ?: "",
                call.argument<String>("activity") ?: "",
                result,
            )
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
                out["settingsActivity"] = settingsActivityOf(packageName)
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

    /** 这个包里声明了设置 action 的导出 Activity；没有或不止一个都返回 null，不替插件挑。 */
    private fun settingsActivityOf(packageName: String): String? {
        val intent = Intent(PluginContract.ACTION_SETTINGS).setPackage(packageName)
        val found = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.queryIntentActivities(intent, PackageManager.ResolveInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            pm.queryIntentActivities(intent, 0)
        }.filter { it.activityInfo.packageName == packageName && it.activityInfo.exported }
        return found.singleOrNull()?.activityInfo?.name
    }

    /**
     * 打开插件自己的设置页（SDK04）。只在用户点了按钮时由 Dart 调用，Dart 那边已确认插件是「可用」。
     * 这里再向系统核一次：这个类确实是该包里唯一声明设置 action 的导出 Activity——
     * 不照 Dart 传来的类名直接启动，免得把任意组件当设置页打开。不带任何 extras。
     */
    private fun openSettings(packageName: String, activity: String, result: MethodChannel.Result) {
        if (packageName.isBlank() || activity.isBlank() || settingsActivityOf(packageName) != activity) {
            result.error("NOT_FOUND", "这个插件没有声明设置页，或者设置页已经变了", null)
            return
        }
        try {
            context.startActivity(
                Intent(PluginContract.ACTION_SETTINGS)
                    .setComponent(ComponentName(packageName, activity))
                    // 从 Application 上下文启动别的 App 的页面，必须开新任务栈。
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            result.success(null)
        } catch (e: RuntimeException) {
            result.error("LAUNCH_FAILED", "系统拒绝打开插件的设置页", null)
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
        disconnect(packageName, "被新的连接取代", "disconnected")
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
        val connection = connections[packageName]
        if (connection?.provider == null) {
            result.error("NOT_CONNECTED", "没有连着这个插件", null)
            return
        }
        connection.callPlugin(result) { it.ping(nonce) }
    }

    private fun sessionOf(call: MethodCall): Pair<Connection, HostSession>? {
        val connection = connections[call.argument<String>("package") ?: ""] ?: return null
        val session = connection.sessions[call.argument<String>("handle") ?: ""] ?: return null
        val generation = call.argument<Number>("generation")?.toLong()
        return if (generation == session.generation) connection to session else null
    }

    private fun withSession(
        call: MethodCall,
        result: MethodChannel.Result,
        body: (Connection, HostSession) -> Unit,
    ) {
        val found = sessionOf(call)
        if (found == null) {
            result.error("NO_SESSION", "会话不存在或已关闭", null)
            return
        }
        body(found.first, found.second)
    }

    /**
     * 打开一个终端会话：宿主建 socketpair，自己留一端，另一端交给插件。
     * 句柄和代次由 Dart 生成；插件把它们和宿主 UID 绑在一起（ProviderSessions）。
     * 插件拒绝或进程已死时，本端立刻关掉，不留半个会话。
     */
    private fun openSession(call: MethodCall, result: MethodChannel.Result) {
        val connection = connections[call.argument<String>("package") ?: ""]
        val handle = call.argument<String>("handle") ?: ""
        val generation = call.argument<Number>("generation")?.toLong() ?: 0L
        val cols = call.argument<Int>("cols") ?: 80
        val rows = call.argument<Int>("rows") ?: 24
        if (connection?.provider == null) {
            result.error("NOT_CONNECTED", "没有连着这个插件", null)
            return
        }
        if (!HANDLE.matches(handle) || generation <= 0 || connection.sessions.containsKey(handle)) {
            result.error("BAD_ARGS", "会话句柄或代次无效", null)
            return
        }
        val pair = ParcelFileDescriptor.createSocketPair()
        val session = HostSession(handle, generation, connection.packageName, pair[0], connection::providerAlive)
        connection.sessions[handle] = session
        connection.callPlugin(
            result,
            onError = {
                connection.sessions.remove(handle)
                session.close()
            },
            always = { runCatching { pair[1].close() } }, // Binder 已把它复制给插件，本进程这份立刻关
        ) {
            it.openSession(handle, generation, cols, rows, pair[1])
            main.post { session.start() }
            null
        }
    }

    /**
     * 关会话：先关宿主自己的那一端（插件读到 EOF），再通知插件；不等插件回应就返回。
     * 插件是否确认停止，看它随后有没有回报 closed（Dart 侧等 2 秒，等不到就如实显示「未确认」）。
     * 幂等：不存在的会话返回 false。
     */
    private fun closeSession(call: MethodCall, result: MethodChannel.Result) {
        val connection = connections[call.argument<String>("package") ?: ""]
        val handle = call.argument<String>("handle") ?: ""
        val session = connection?.sessions?.get(handle)
        val generation = call.argument<Number>("generation")?.toLong()
        if (connection == null || session == null || session.generation != generation) {
            result.success(false)
            return
        }
        connection.sessions.remove(handle)
        connection.rememberClosed(session)
        session.close()
        connection.callPlugin(null) {
            it.closeSession(handle, session.generation)
            null
        }
        result.success(true)
    }

    private fun disconnect(packageName: String, reason: String, cause: String) {
        val connection = connections.remove(packageName) ?: return
        connection.close(reason, cause)
    }

    fun dispose() {
        for (packageName in connections.keys.toList()) disconnect(packageName, "宿主退出", "hostExit")
        runCatching { context.unregisterReceiver(packageReceiver) }
        channel.setMethodCallHandler(null)
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

        /** 这个插件自己的 Binder 调用线程：插件卡住只卡它自己，不拖累别的插件（PLG12）。 */
        private val calls: ExecutorService = Executors.newSingleThreadExecutor()
        val sessions = ConcurrentHashMap<String, HostSession>()

        /** 刚关掉的会话（宿主先关），只为接收插件随后的 closed 确认。有上限。 */
        private val recentlyClosed = object : LinkedHashMap<String, HostSession>() {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, HostSession>?) = size > 32
        }
        private var binder: IBinder? = null
        private val verifier = CallerVerifier(context, packageName, setOf(approvedSha256))
        private var lastSequence = 0L
        private val deathRecipient = IBinder.DeathRecipient {
            main.post {
                if (connections[packageName] === this) connections.remove(packageName)
                close("插件进程已退出", "providerDied")
            }
        }

        /** 插件进程还在不在。读到 EOF 时用它区分「插件自己关了流」和「插件进程死了」。 */
        fun providerAlive(): Boolean = binder?.pingBinder() == true

        fun rememberClosed(session: HostSession) = synchronized(recentlyClosed) {
            recentlyClosed[session.handle] = session
        }

        /** 在这个插件的调用线程上调它；结果回主线程交给 Dart（[result] 为 null 表示不关心结果）。 */
        fun callPlugin(
            result: MethodChannel.Result?,
            onError: () -> Unit = {},
            always: () -> Unit = {},
            body: (IXwshunProvider) -> Any?,
        ) {
            val target = provider
            if (target == null) {
                onError()
                always()
                result?.error("NOT_CONNECTED", "没有连着这个插件", null)
                return
            }
            try {
                calls.execute {
                    try {
                        val value = body(target)
                        main.post { result?.success(value) }
                    } catch (e: SecurityException) {
                        main.post { onError(); result?.error("REFUSED", "插件拒绝了宿主：${e.message}", null) }
                    } catch (e: IllegalStateException) {
                        main.post { onError(); result?.error("REFUSED", "插件拒绝：${e.message}", null) }
                    } catch (e: IllegalArgumentException) {
                        main.post { onError(); result?.error("REFUSED", "插件拒绝：${e.message}", null) }
                    } catch (e: RemoteException) {
                        main.post { onError(); result?.error("DEAD", "插件进程已不在", null) }
                    } finally {
                        always()
                    }
                }
            } catch (e: java.util.concurrent.RejectedExecutionException) {
                onError()
                always()
                result?.error("CLOSED", "连接已关闭", null)
            }
        }

        private fun drop(handle: String?, reason: String) {
            Log.w(TAG, "丢弃会话事件（$packageName，$handle）：$reason")
            emit(mapOf("type" to "droppedEvent", "package" to packageName, "handle" to handle, "reason" to reason))
        }

        /** 交给插件的回调。每个事务都核对调用方：这个 Binder 被转交给别的 App 也调不进来。 */
        val host = object : IXwshunHost.Stub() {
            override fun onSessionEvent(handle: String?, generation: Long, sequence: Long, state: String?) {
                try {
                    verifier.requireTrustedCaller()
                } catch (e: SecurityException) {
                    Log.w(TAG, "拒绝 onSessionEvent：${e.message}")
                    emit(mapOf("type" to "rejectedCall", "package" to packageName, "method" to "onSessionEvent", "reason" to e.message))
                    return
                }
                if (handle == null || state == null || state.length > PluginContract.MAX_EVENT_CHARS) {
                    drop(handle, "事件格式无效")
                    return
                }
                if (closed) {
                    // 已撤销、已断开：插件不理 close 继续发，也一律不进 App（PLG12）。
                    drop(handle, "连接已关闭")
                    return
                }
                val live = sessions[handle]
                val session = live ?: synchronized(recentlyClosed) { recentlyClosed[handle] }
                when {
                    // 不属于这个插件的句柄：可能是别的插件的，也可能是伪造的（PLG06）。
                    session == null -> drop(handle, "不是这个插件的会话")
                    generation != session.generation -> drop(handle, "旧代次 $generation（当前 ${session.generation}）")
                    // 宿主已关的会话，只接受插件的 closed 确认。
                    live == null && state != "closed" -> drop(handle, "会话已关闭")
                    !session.acceptSequence(sequence) -> drop(handle, "序号不递增")
                    else -> emit(
                        mapOf(
                            "type" to "sessionEvent",
                            "package" to packageName,
                            "handle" to handle,
                            "generation" to generation,
                            "sequence" to sequence,
                            "state" to state,
                        ),
                    )
                }
            }

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
            calls.execute {
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
                        close(error, "handshakeFailed")
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
            close("插件服务断开", "providerDied")
        }

        fun fail(code: String, message: String) {
            pending?.error(code, message, null)
            pending = null
        }

        /** [cause]：disconnected / providerDied / handshakeFailed / hostExit，给 Dart 判断会话是被谁结束的。 */
        fun close(reason: String, cause: String) {
            synchronized(this@Connection) {
                if (closed) return
                closed = true
            }
            val target = provider
            provider = null
            fail("CLOSED", reason)
            // 先关宿主自己的 FD，插件读到 EOF；再尽力通知插件（它死了或不理，都不影响这边已关）。
            for (session in sessions.values) {
                session.close()
                emit(mapOf("type" to "sessionClosed", "package" to packageName, "handle" to session.handle, "generation" to session.generation, "reason" to reason, "cause" to cause))
                if (target != null) {
                    calls.execute { runCatching { target.closeSession(session.handle, session.generation) } }
                }
            }
            sessions.clear()
            calls.shutdown()
            binder?.let { runCatching { it.unlinkToDeath(deathRecipient, 0) } }
            runCatching { context.unbindService(this) }
            emit(mapOf("type" to "closed", "package" to packageName, "reason" to reason, "cause" to cause))
        }
    }

    /**
     * 宿主这一端的会话流。
     *
     * 输出（插件 → Dart）：读线程每读到一块就占一个额度，Dart 处理完回 ack 才归还；额度用完就不再读，
     * socket 缓冲随之写满，插件的 write 阻塞——背压一路传到插件，没有任何一段是无界队列（PLG07）。
     * 输入（Dart → 插件）：单独的写线程按顺序写；积压超过上限直接拒绝，而不是无限排队。
     */
    private inner class HostSession(
        val handle: String,
        val generation: Long,
        private val packageName: String,
        private val stream: ParcelFileDescriptor,
        private val providerAlive: () -> Boolean,
    ) {
        private val credits = Semaphore(OUTPUT_WINDOW)
        private val pendingInput = AtomicLong()
        private val writer = Executors.newSingleThreadExecutor()
        private val output = FileOutputStream(stream.fileDescriptor)
        private var lastSequence = 0L
        @Volatile private var closed = false
        private var reader: Thread? = null

        @Synchronized
        fun acceptSequence(sequence: Long): Boolean {
            if (sequence <= lastSequence) return false
            lastSequence = sequence
            return true
        }

        fun start() {
            if (closed) return
            reader = Thread({ readLoop() }, "plugin-session-$handle").also { it.start() }
        }

        private fun readLoop() {
            val buffer = ByteArray(CHUNK_BYTES)
            var eof = false
            try {
                FileInputStream(stream.fileDescriptor).use { input ->
                    while (!closed) {
                        val n = input.read(buffer)
                        if (n < 0) {
                            eof = true
                            break
                        }
                        val chunk = buffer.copyOf(n)
                        // 额度用完就停在这里不再读：宿主最多压着 窗口数 + 1 块（手里这块）。
                        credits.acquire()
                        if (closed) break
                        main.post {
                            channel.invokeMethod(
                                "sessionData",
                                mapOf("package" to packageName, "handle" to handle, "generation" to generation, "bytes" to chunk),
                            )
                        }
                    }
                }
            } catch (e: IOException) {
                eof = !closed
            } catch (e: InterruptedException) {
                // 关闭
            }
            if (eof && !closed) {
                // 插件进程被杀时，内核先关它的 socket，这边先读到 EOF，Binder 死亡通知要晚一点才到。
                // 立刻上报会把「插件死了」记成普通中断（模拟器实测）。等一小会儿：死亡通知先到就由连接统一按
                // providerDied 收尾（那时 closed 已为 true，这里不再上报）；否则附上插件进程此刻是否还在。
                main.postDelayed({
                    if (!closed) {
                        emit(
                            mapOf(
                                "type" to "sessionEof",
                                "package" to packageName,
                                "handle" to handle,
                                "generation" to generation,
                                "providerAlive" to providerAlive(),
                            ),
                        )
                    }
                }, EOF_GRACE_MS)
            }
        }

        fun ack() = credits.release()

        fun write(bytes: ByteArray, result: MethodChannel.Result) {
            if (closed) {
                result.error("CLOSED", "会话已关闭", null)
                return
            }
            if (pendingInput.get() + bytes.size > MAX_PENDING_INPUT) {
                result.error("INPUT_BACKLOG", "插件没有及时读取，输入积压超过上限", null)
                return
            }
            pendingInput.addAndGet(bytes.size.toLong())
            try {
                writer.execute {
                    try {
                        output.write(bytes)
                        main.post { result.success(null) }
                    } catch (e: IOException) {
                        main.post { result.error("CLOSED", "会话已关闭", null) }
                    } finally {
                        pendingInput.addAndGet(-bytes.size.toLong())
                    }
                }
            } catch (e: java.util.concurrent.RejectedExecutionException) {
                pendingInput.addAndGet(-bytes.size.toLong())
                result.error("CLOSED", "会话已关闭", null)
            }
        }

        fun stats(): Map<String, Any> = mapOf(
            "outputChunksInFlight" to OUTPUT_WINDOW - credits.availablePermits().coerceAtMost(OUTPUT_WINDOW),
            "outputWindow" to OUTPUT_WINDOW,
            "chunkBytes" to CHUNK_BYTES,
            "pendingInputBytes" to pendingInput.get(),
            "maxPendingInputBytes" to MAX_PENDING_INPUT,
        )

        /** 幂等。先 shutdown 叫醒阻塞在 read/write 上的线程（只 close 叫不醒），再关 FD。 */
        fun close() {
            synchronized(this) {
                if (closed) return
                closed = true
            }
            try {
                Os.shutdown(stream.fileDescriptor, OsConstants.SHUT_RDWR)
            } catch (e: ErrnoException) {
                // 对端已断
            }
            credits.release(OUTPUT_WINDOW)
            writer.shutdownNow()
            runCatching { stream.close() }
        }
    }

    private companion object {
        const val TAG = "XwshunPlugins"
        val HANDLE = Regex("^[A-Za-z0-9-]{1,64}$")

        /** 每次从 FD 读的上限，也是一次交给 Dart 的最大块。 */
        const val CHUNK_BYTES = 16 * 1024

        /** Dart 还没确认的块数上限：宿主这边最多压着 (4 + 1) × 16 KiB，再多就不读，让插件阻塞。 */
        const val OUTPUT_WINDOW = 4

        /** 输入积压上限：插件不读时，最多替它排 1 MiB，再多直接告诉 Dart。 */
        const val MAX_PENDING_INPUT = 1L * 1024 * 1024

        /** 读到 EOF 后等 Binder 死亡通知的时间。 */
        const val EOF_GRACE_MS = 300L
    }
}
