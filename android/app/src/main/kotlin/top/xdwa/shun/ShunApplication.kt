package top.xdwa.shun

import android.app.Application

/**
 * 进程一起来就装上 Java 崩溃记录（R26 F24，见 [CrashRecorder]）。放在这里而不是 MainActivity：
 * 保活服务、插件回调也会单独把进程拉起来，那时没有 Activity，崩了也要记得下。
 */
class ShunApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        CrashRecorder.install(this)
    }
}
