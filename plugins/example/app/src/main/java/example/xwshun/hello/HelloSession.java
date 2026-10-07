// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 xwfe

package example.xwshun.hello;

import android.content.Context;
import android.content.pm.PackageManager;
import android.os.ParcelFileDescriptor;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import android.util.Log;

import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

/**
 * 一个会话的接线：把宿主给的 FD 接到 {@link HelloShell} 上。收什么、回什么都在 HelloShell 里，这里只管读写和收尾。
 *
 * <p>字节流的约定：从 FD 读到的是用户的输入，往 FD 写的是终端输出；读到 EOF 表示宿主关了，插件随之清理、回报 closed。
 * 读写都在这个会话自己的线程里。宿主不读输出时 write 会阻塞，读线程随之不再读输入——背压就这样传回宿主，不用另设队列。
 */
final class HelloSession {
    interface Events {
        void send(HelloSession session, String state);
    }

    final String handle;
    final long generation;
    private final Context context;
    private final ParcelFileDescriptor stream;
    private final HelloShell shell;
    private final AtomicBoolean closed = new AtomicBoolean();
    private final AtomicLong sequence = new AtomicLong();

    HelloSession(Context context, String handle, long generation, ParcelFileDescriptor stream,
            int cols, int rows, int hostApiMinor) {
        this.context = context.getApplicationContext();
        this.handle = handle;
        this.generation = generation;
        this.stream = stream;
        this.shell = new HelloShell(HelloProviderService.PLUGIN_ID, versionName(this.context), hostApiMinor,
                handle, generation, cols, rows);
    }

    long nextSequence() {
        return sequence.incrementAndGet();
    }

    /** 改尺寸只记下新值，不往终端写字：这个方法在 Binder 线程上调，写 FD 可能阻塞。输入 size 能看到新值。 */
    void resize(int cols, int rows) {
        shell.resize(cols, rows);
    }

    void start(Events events, Runnable onEnd) {
        new Thread(() -> run(events, onEnd), "hello-" + handle).start();
    }

    private void run(Events events, Runnable onEnd) {
        // 先回报 active，宿主才把会话当成「可以收发了」。
        events.send(this, "active");
        String reason = "宿主关闭";
        boolean color = context.getSharedPreferences(SettingsActivity.PREFS, Context.MODE_PRIVATE)
                .getBoolean(SettingsActivity.KEY_COLOR_BANNER, true);
        try (FileInputStream in = new FileInputStream(stream.getFileDescriptor());
             FileOutputStream out = new FileOutputStream(stream.getFileDescriptor())) {
            out.write(shell.banner(color));
            byte[] buffer = new byte[4096];
            int n;
            while ((n = in.read(buffer)) >= 0) {
                out.write(shell.feed(buffer, n));
                if (shell.ended()) {
                    reason = "用户输入 exit";
                    break;
                }
            }
        } catch (IOException e) {
            // 被 close() 叫醒，或者宿主那端断了
        }
        Log.i(HelloProviderService.TAG, "会话 " + handle + " 结束：" + reason);
        // 先关流再回报 closed：最后写的字在 closed 之前到宿主。宿主读到 EOF 后等 300 ms，等到 closed 就记「已关闭」，
        // 等不到才记成「中断」。
        close();
        events.send(this, "closed");
        onEnd.run();
    }

    private static String versionName(Context context) {
        try {
            return context.getPackageManager().getPackageInfo(context.getPackageName(), 0).versionName;
        } catch (PackageManager.NameNotFoundException e) {
            return "?";
        }
    }

    /** 幂等。先 shutdown 叫醒阻塞在 read/write 上的线程（只 close 叫不醒），再关 FD。 */
    void close() {
        if (!closed.compareAndSet(false, true)) return;
        try {
            Os.shutdown(stream.getFileDescriptor(), OsConstants.SHUT_RDWR);
        } catch (ErrnoException ignored) {
            // 对端已断
        }
        try {
            stream.close();
        } catch (IOException ignored) {
            // 已关
        }
    }
}
