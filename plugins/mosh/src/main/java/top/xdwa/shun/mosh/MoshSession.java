package top.xdwa.shun.mosh;

import android.os.ParcelFileDescriptor;
import android.os.Process;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import android.util.Log;

import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.Arrays;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

/**
 * 一个 Mosh 会话 = 一个 mosh-client 子进程 + 它的 PTY。宿主给的 socketpair 和 PTY 主端之间双向搬字节：
 * 宿主写进来的是用户输入（原样进 PTY），PTY 出来的是 mosh-client 画好的 VT（原样给宿主的 flterm）。
 *
 * <p>关闭：先给 mosh-client 发 SIGHUP——它收到后按协议通知 mosh-server 关闭（远端 shell 随之结束），
 * 等服务器确认或超时后自己退出；{@link #KILL_AFTER_MS} 内没退就 SIGKILL（这时远端可能留着 mosh-server）。
 */
final class MoshSession {
    private static final String TAG = "ShunMosh";
    private static final int SIGHUP = 1;
    /** mosh-client 收到 SIGHUP 后等服务器确认关闭的时间有上限（约几秒）；再留余量后强杀。 */
    static final long KILL_AFTER_MS = 8000;

    interface Events {
        void send(MoshSession session, String state);
    }

    final String handle;
    final long generation;
    final int ownerUid;
    private final ParcelFileDescriptor hostStream;
    private final AtomicBoolean stopping = new AtomicBoolean();
    private final AtomicBoolean ended = new AtomicBoolean();
    private final AtomicLong sequence = new AtomicLong();
    private volatile ParcelFileDescriptor master;
    private volatile int pid = -1;
    private volatile boolean exited;

    MoshSession(String handle, long generation, int ownerUid, ParcelFileDescriptor hostStream) {
        this.handle = handle;
        this.generation = generation;
        this.ownerUid = ownerUid;
        this.hostStream = hostStream;
    }

    long nextSequence() {
        return sequence.incrementAndGet();
    }

    int pid() {
        return pid;
    }

    /**
     * 拉起 mosh-client。key 用完（无论成败）都清零。失败抛异常，调用方负责回收会话表。
     * 在 Binder 线程上调用：fork + exec 很快，不等远端。
     */
    void start(String clientPath, String udpHost, int udpPort, byte[] key, int cols, int rows,
               Events events, Runnable onEnd) throws IOException {
        int[] spawned;
        try {
            spawned = MoshPty.spawn(
                    clientPath,
                    new String[] {"mosh-client", udpHost, Integer.toString(udpPort)},
                    new String[] {
                        // mosh-client 按 TERM 查 terminfo（编进库里的只有 xterm-256color），按 LANG 判断 UTF-8。
                        // key 不在这里：JNI 经管道交给它（MOSH_KEY_FD=3，见 moshpty.c 和 native/patches/0002）。
                        "TERM=xterm-256color",
                        "LANG=en_US.UTF-8",
                        "PATH=/system/bin",
                    },
                    key, rows, cols);
        } finally {
            Arrays.fill(key, (byte) 0);
        }
        pid = spawned[0];
        master = ParcelFileDescriptor.adoptFd(spawned[1]);
        Log.i(TAG, "会话 " + handle + " 运行时 pid=" + pid);
        events.send(this, "active");

        Thread output = new Thread(this::pumpOutput, "mosh-out-" + handle);
        Thread input = new Thread(this::pumpInput, "mosh-in-" + handle);
        output.start();
        input.start();
        new Thread(() -> reap(output, events, onEnd), "mosh-reap-" + handle).start();
    }

    // 下面的流都从 FileDescriptor 构造：Android 上这种流不拥有 fd，close() 不关它（libcore isFdOwner=false）。
    // fd 只由 reap() 关一次，避免两个线程各关一次、第二次关掉别人刚复用的 fd 号。

    /** PTY → 宿主。mosh-client 退出后读到 EIO 结束；宿主不读时写阻塞，背压传回 mosh-client。 */
    private void pumpOutput() {
        byte[] buffer = new byte[16 * 1024];
        try (FileInputStream in = new FileInputStream(master.getFileDescriptor());
             FileOutputStream out = new FileOutputStream(hostStream.getFileDescriptor())) {
            int n;
            while ((n = in.read(buffer)) >= 0) out.write(buffer, 0, n);
        } catch (IOException e) {
            // EIO：子进程已退出、PTY 从端全关；或宿主关了 socket
        }
    }

    /** 宿主 → PTY。读到 EOF 说明宿主关了这个会话：按关闭流程走。 */
    private void pumpInput() {
        byte[] buffer = new byte[16 * 1024];
        try (FileInputStream in = new FileInputStream(hostStream.getFileDescriptor());
             FileOutputStream out = new FileOutputStream(master.getFileDescriptor())) {
            int n;
            while ((n = in.read(buffer)) >= 0) out.write(buffer, 0, n);
        } catch (IOException e) {
            // 宿主断开或 PTY 已关
        }
        stop();
    }

    private void reap(Thread output, Events events, Runnable onEnd) {
        int code;
        try {
            code = MoshPty.waitFor(pid);
        } catch (IOException e) {
            code = -1;
        }
        exited = true;
        try {
            output.join(2000); // 把 mosh-client 最后画的东西送完再关
        } catch (InterruptedException ignored) {
            Thread.currentThread().interrupt();
        }
        closeQuietly(master);
        shutdownAndClose(hostStream);
        Log.i(TAG, "会话 " + handle + " 运行时退出 code=" + code);
        if (ended.compareAndSet(false, true)) {
            events.send(this, code == 0 ? "closed" : "failed:exit-" + code);
            onEnd.run();
        }
    }

    void resize(int cols, int rows) {
        ParcelFileDescriptor m = master;
        if (m != null) MoshPty.setWindowSize(m.getFd(), rows, cols);
    }

    /** 幂等。SIGHUP 让 mosh-client 走协议关闭；超时强杀。 */
    void stop() {
        if (!stopping.compareAndSet(false, true)) return;
        int p = pid;
        if (p <= 0 || exited) return;
        Process.sendSignal(p, SIGHUP);
        Thread killer = new Thread(() -> {
            try {
                Thread.sleep(KILL_AFTER_MS);
            } catch (InterruptedException ignored) {
                return;
            }
            if (!exited) {
                Log.w(TAG, "会话 " + handle + " 的运行时 " + KILL_AFTER_MS + " ms 没退出，强杀");
                Process.sendSignal(p, Process.SIGNAL_KILL);
            }
        }, "mosh-kill-" + handle);
        killer.setDaemon(true);
        killer.start();
    }

    /** 打开前就失败时用：没起子进程，只关宿主给的流。 */
    void abandon() {
        shutdownAndClose(hostStream);
    }

    private static void shutdownAndClose(ParcelFileDescriptor fd) {
        try {
            Os.shutdown(fd.getFileDescriptor(), OsConstants.SHUT_RDWR);
        } catch (ErrnoException ignored) {
            // 已断
        }
        closeQuietly(fd);
    }

    private static void closeQuietly(ParcelFileDescriptor fd) {
        if (fd == null) return;
        try {
            fd.close();
        } catch (IOException ignored) {
            // 已关
        }
    }
}
