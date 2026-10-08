package app.netcatty.mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.content.ContextCompat

/**
 * 用户开着终端会话时的前台服务：让系统别在 App 退到后台后把进程收走（R22）。
 *
 * 只做这一件事，不保证「永不断线」：
 * - 不拿唤醒锁、不拿 Wi-Fi 锁。基座原来一直拿着不限时的 PARTIAL_WAKE_LOCK 和 Wi-Fi 高性能锁，
 *   前台服务在 Doze 里唤醒锁照样生效，等于开着会话 CPU 就永远不睡；Wi-Fi 锁在 Android 14+ 后台根本不起作用。
 *   现在息屏后 CPU 照常休眠，收到数据时网卡会叫醒它；连接因此断了由 Dart 按恢复策略处理。
 * - 类型是 specialUse（交互式 SSH 终端不属于任何一种标准类型），不伪装成媒体播放、定位之类。
 * - START_NOT_STICKY：进程被杀后系统不重启它——SSH 连接在 Dart 里，单独把服务拉起来什么也恢复不了，
 *   只会留下一个空挂的通知。
 *
 * 通知上的「全部断开」交给 Dart 去断（先让进行中的连接和恢复失效，再释放连接，见 docs/07），
 * Dart 断完再停服务；Dart 5 秒内没反应（引擎没了）服务就自己停。
 */
class SshKeepAliveService : Service() {
    /** Dart 给的通知内容和保活代次。 */
    data class Content(val generation: Int, val title: String?, val text: String?)

    companion object {
        private const val CHANNEL_ID = "netcatty_ssh_sessions"
        private const val NOTIFICATION_ID = 701
        private const val ACTION_STOP_ALL = "top.xdwa.xwshun.action.STOP_ALL_SESSIONS"
        private const val STOP_FALLBACK_MS = 5_000L

        // 下面几个状态只在主线程读写（MethodChannel 回调和 Service 生命周期都跑在主线程），不用加锁。
        /** 已经调过 startForegroundService，服务还没销毁。 */
        var requested = false
            private set

        /** onCreate 里已经 startForeground。在这之前 stopService 会让系统杀掉 App。 */
        var inForeground = false
            private set

        /** 进入前台之前就收到了停止：进入前台后立刻自己停。 */
        var stopWhenStarted = false
            private set

        /** 这次销毁是 App 自己要的（Dart 让停、引擎没了）。不是的话就是被系统或别人停的，要告诉 Dart。 */
        private var stopByApp = false

        private var content = Content(0, null, null)

        /** 报给 Dart：(事件, 保活代次, 原因)。引擎没了时为 null。 */
        var listener: ((String, Int, String) -> Unit)? = null

        fun start(context: Context, next: Content) {
            content = next
            stopWhenStarted = false
            stopByApp = false
            ContextCompat.startForegroundService(context, Intent(context, SshKeepAliveService::class.java))
            requested = true
        }

        /** 服务已经开着：只换通知内容和代次，不再 startForegroundService（不给系统再一次「5 秒内必须进前台」的考题）。 */
        fun update(context: Context, next: Content) {
            content = next
            if (!inForeground) return
            context.getSystemService(NotificationManager::class.java)
                ?.notify(NOTIFICATION_ID, buildNotification(context))
        }

        fun stop(context: Context) {
            if (inForeground) {
                stopByApp = true
                context.stopService(Intent(context, SshKeepAliveService::class.java))
            } else if (requested) {
                // 服务刚被拉起、还没在 onCreate 里 startForeground 时不能 stopService：
                // 系统会以 ForegroundServiceDidNotStartInTimeException 杀掉整个 App。
                // 连接在拨号前就失败（路线配置错、凭据解不开）时必现，模拟器 API 35 实测。
                // 改为记下来，由服务进入前台后自己停。
                stopByApp = true
                stopWhenStarted = true
            }
        }

        private fun buildNotification(context: Context): Notification {
            val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            val open = PendingIntent.getActivity(
                context,
                0,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            // 服务开着（进程是前台服务状态），普通 startService 不受后台启动限制。
            val stopAll = PendingIntent.getService(
                context,
                1,
                Intent(context, SshKeepAliveService::class.java).setAction(ACTION_STOP_ALL),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            val action = Notification.Action.Builder(
                Icon.createWithResource(context, R.mipmap.ic_launcher),
                "全部断开",
                stopAll,
            ).build()
            return builder
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(content.title ?: "xwshun 终端会话")
                .setContentText(content.text ?: "点击回到终端")
                .setContentIntent(open)
                .addAction(action)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setCategory(Notification.CATEGORY_SERVICE)
                .build()
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private var stopRequestGeneration: Int? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        startForeground(NOTIFICATION_ID, buildNotification(this))
        inForeground = true
        if (stopWhenStarted) {
            stopWhenStarted = false
            stopSelf()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (stopWhenStarted) {
            stopWhenStarted = false
            stopSelf()
            return START_NOT_STICKY
        }
        if (intent?.action == ACTION_STOP_ALL) onStopAll()
        return START_NOT_STICKY
    }

    private fun onStopAll() {
        val generation = content.generation
        val report = listener
        if (report == null) {
            // 没有 Dart 来断（引擎没了）：没有会话可保，直接停。
            stopByApp = true
            stopSelf()
            return
        }
        report("stopRequested", generation, "notification")
        if (stopRequestGeneration == generation) return
        stopRequestGeneration = generation
        main.postDelayed({
            // Dart 断完会让服务停；5 秒还在而且还是这一代，说明 Dart 那边没反应。停掉，按「被停」报给 Dart。
            if (requested && content.generation == generation) {
                stopByApp = false
                stopSelf()
            }
        }, STOP_FALLBACK_MS)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        main.removeCallbacksAndMessages(null)
        val unexpected = !stopByApp
        inForeground = false
        requested = false
        stopWhenStarted = false
        stopByApp = false
        if (unexpected) listener?.invoke("stopped", content.generation, "system")
        super.onDestroy()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "SSH 会话",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "开着终端会话时常驻，可从这里全部断开"
                setShowBadge(false)
            },
        )
    }
}
