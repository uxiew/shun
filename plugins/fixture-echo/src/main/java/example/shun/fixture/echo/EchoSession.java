package example.shun.fixture.echo;

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

/** 一个回显会话：从宿主给的 FD 读到什么就原样写回去。只用于测试字节流、背压和生命周期。 */
final class EchoSession {
    private static final String TAG = "ShunEcho";

    interface Events {
        void send(EchoSession session, String state);
    }

    final String handle;
    final long generation;
    final int ownerUid;
    private final ParcelFileDescriptor stream;
    private final AtomicBoolean closed = new AtomicBoolean();
    private final AtomicLong sequence = new AtomicLong();
    private volatile Thread worker;
    volatile int cols;
    volatile int rows;

    EchoSession(String handle, long generation, int ownerUid, ParcelFileDescriptor stream, int cols, int rows) {
        this.handle = handle;
        this.generation = generation;
        this.ownerUid = ownerUid;
        this.stream = stream;
        this.cols = cols;
        this.rows = rows;
    }

    long nextSequence() {
        return sequence.incrementAndGet();
    }

    boolean isClosed() {
        return closed.get();
    }

    /** 在插件自己的线程里跑，不占 Binder 线程。 */
    void start(long openDelayMs, Runnable afterActive, Events events, Runnable onEnd) {
        Thread thread = new Thread(() -> {
            try {
                if (openDelayMs > 0) Thread.sleep(openDelayMs);
            } catch (InterruptedException ignored) {
                // 继续
            }
            if (!closed.get()) {
                events.send(this, "active");
                afterActive.run();
            }
            long echoed = 0;
            byte[] buffer = new byte[16 * 1024];
            try (FileInputStream in = new FileInputStream(stream.getFileDescriptor());
                 FileOutputStream out = new FileOutputStream(stream.getFileDescriptor())) {
                int n;
                while ((n = in.read(buffer)) >= 0) {
                    out.write(buffer, 0, n); // 宿主不读时这里阻塞：背压一路传回宿主的写入
                    echoed += n;
                }
            } catch (IOException e) {
                // 被关闭或宿主断开
            }
            Log.i(TAG, "会话 " + handle + " 结束，回显 " + echoed + " 字节");
            close();
            events.send(this, "closed");
            onEnd.run();
        }, "echo-" + handle);
        worker = thread;
        thread.start();
    }

    /** 幂等。先 shutdown 叫醒阻塞在 read/write 上的线程，再关 FD。 */
    void close() {
        if (!closed.compareAndSet(false, true)) return;
        Thread thread = worker;
        // 慢打开还在等时被关：叫醒它，好立刻回报 closed，而不是等满延迟。
        if (thread != null && thread != Thread.currentThread()) thread.interrupt();
        try {
            Os.shutdown(stream.getFileDescriptor(), OsConstants.SHUT_RDWR);
        } catch (ErrnoException ignored) {
            // 已经断了
        }
        try {
            stream.close();
        } catch (IOException ignored) {
            // 已关
        }
    }
}
