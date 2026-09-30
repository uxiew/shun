package app.netcatty.mobile

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * 只接 UU 远程回调的过路 Activity（X06）：收下回调原文，打开 MainActivity，自己马上结束。
 *
 * 为什么不让 MainActivity 直接接：回调地址里有 UU 的加密设备标识。App 没在运行时被回调拉起来，
 * 系统会把这条 Intent 记成 MainActivity 那个任务的基础 Intent——`adb shell dumpsys activity`、bugreport 里
 * 能看到完整地址，还会随「最近任务」留在系统里（模拟器 API 35 实测）。
 * 这个 Activity 在清单里不进最近任务、不留历史，结束后系统那边就不剩这条地址；MainActivity 拿到的是不带数据的 Intent。
 *
 * 没有界面（Theme.NoDisplay）：必须在 onCreate 里 finish，否则系统抛 IllegalStateException。
 */
class UuCallbackActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        UuRemoteBridge.capture(intent)
        startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        finish()
    }
}
