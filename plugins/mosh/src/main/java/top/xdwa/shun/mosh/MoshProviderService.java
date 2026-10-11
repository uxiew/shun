package top.xdwa.shun.mosh;

import android.app.Service;
import android.content.Intent;
import android.os.Binder;
import android.os.IBinder;
import android.os.ParcelFileDescriptor;
import android.os.RemoteException;
import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

import top.xdwa.shun.plugin.v1.CallerVerifier;
import top.xdwa.shun.plugin.v1.IShunHost;
import top.xdwa.shun.plugin.v1.IShunProvider;
import top.xdwa.shun.plugin.v1.PluginContract;
import top.xdwa.shun.plugin.v1.ProviderSessions;

/**
 * Mosh 运行时插件（X08）。每个方法第一行核对调用方是信任的宿主（包名 + 证书），见 provider-sdk 的 CallerVerifier。
 *
 * <p>运行时是随本 APK 安装的官方 mosh-client 1.4.0（交叉编译，见 native/build-mosh-client.sh），
 * 装在系统解出的 nativeLibraryDir 里（只读）。不从网络下载、不拷到可写目录执行（docs/13 S54）。
 * 插件只收宿主 bootstrap 后的临时材料（数字 IP、UDP 端口、会话 key），不接触 SSH 凭据和保险库。
 */
public final class MoshProviderService extends Service {
    private static final String TAG = "ShunMosh";
    /** 每个会话一个 mosh-client 进程；先限 4 个，够测并发，又不让一个宿主无限开进程。 */
    private static final int MAX_SESSIONS = 4;

    private CallerVerifier verifier;
    private final ProviderSessions<MoshSession> sessions = new ProviderSessions<>(MAX_SESSIONS);
    private volatile IShunHost host;
    private String clientPath;

    @Override
    public void onCreate() {
        super.onCreate();
        verifier = new CallerVerifier(
                this,
                getString(R.string.shun_trusted_host_package),
                Collections.singleton(getString(R.string.shun_trusted_host_sha256)));
        clientPath = new File(getApplicationInfo().nativeLibraryDir, "libmoshclient.so").getPath();
        Log.i(TAG, "服务启动，运行时 " + (new File(clientPath).canExecute() ? "可执行" : "不可执行"));
    }

    @Override
    public IBinder onBind(Intent intent) {
        return stub;
    }

    private int requireHost(String method) {
        try {
            return verifier.requireTrustedCaller();
        } catch (SecurityException e) {
            Log.w(TAG, method + " 拒绝：" + e.getMessage());
            throw e;
        }
    }

    private final IShunProvider.Stub stub = new IShunProvider.Stub() {
        @Override
        public String handshake(int hostApiMajor, int hostApiMinor, IShunHost callback) {
            int uid = requireHost("handshake");
            if (hostApiMajor != PluginContract.HOST_API_MAJOR) {
                throw new IllegalStateException("只支持宿主 API major " + PluginContract.HOST_API_MAJOR);
            }
            if (callback != null) {
                host = callback;
                watchHostDeath(callback, uid);
                new Thread(() -> {
                    try {
                        callback.onProviderEvent(1, 1, "ready");
                    } catch (RemoteException ignored) {
                        // 宿主已不在
                    }
                }).start();
            }
            return readDescriptor();
        }

        @Override
        public long ping(long nonce) {
            requireHost("ping");
            return nonce;
        }

        @Override
        public void openSession(String handle, long generation, int cols, int rows, ParcelFileDescriptor stream) {
            requireHost("openSession");
            closeQuietly(stream);
            // Mosh 没有临时材料开不了：不能退回「随便连点什么」。
            throw new UnsupportedOperationException("Mosh 会话要用 openMoshSession 带上 bootstrap 材料");
        }

        @Override
        public void openMoshSession(String handle, long generation, int cols, int rows, ParcelFileDescriptor stream,
                                    String udpHost, int udpPort, byte[] printableKey) {
            int uid;
            try {
                uid = requireHost("openMoshSession");
                if (stream == null) throw new IllegalArgumentException("缺少数据流");
                if (!MoshPty.isNumericAddress(udpHost)) throw new IllegalArgumentException("目标必须是数字 IP");
                if (udpPort < 1 || udpPort > 65535) throw new IllegalArgumentException("UDP 端口越界");
                if (cols < 1 || rows < 1 || cols > 1000 || rows > 1000) throw new IllegalArgumentException("窗口尺寸越界");
                if (printableKey == null || printableKey.length != 22) throw new IllegalArgumentException("key 格式不对");
            } catch (RuntimeException e) {
                if (printableKey != null) Arrays.fill(printableKey, (byte) 0);
                closeQuietly(stream);
                throw e;
            }
            MoshSession session = new MoshSession(handle, generation, uid, stream);
            try {
                sessions.open(handle, uid, generation, session);
            } catch (RuntimeException e) {
                Arrays.fill(printableKey, (byte) 0);
                session.abandon();
                throw e;
            }
            try {
                session.start(clientPath, udpHost, udpPort, printableKey, cols, rows,
                        MoshProviderService.this::sendSessionEvent, () -> sessions.drop(handle));
            } catch (IOException | RuntimeException e) {
                sessions.drop(handle);
                session.abandon();
                Log.w(TAG, "会话 " + handle + " 运行时起不来：" + e.getMessage());
                throw new IllegalStateException("运行时起不来：" + e.getMessage());
            }
        }

        @Override
        public void resizeSession(String handle, long generation, int cols, int rows) {
            int uid = requireHost("resizeSession");
            if (cols < 1 || rows < 1 || cols > 1000 || rows > 1000) throw new IllegalArgumentException("窗口尺寸越界");
            MoshSession session = sessions.require(handle, uid, generation);
            session.resize(cols, rows);
            sendSessionEvent(session, "resized:" + cols + "x" + rows);
        }

        @Override
        public void closeSession(String handle, long generation) {
            int uid = requireHost("closeSession");
            MoshSession session = sessions.remove(handle, uid, generation);
            if (session != null) session.stop(); // 退出后由 reap 回报 closed
        }
    };

    private void sendSessionEvent(MoshSession session, String state) {
        IShunHost callback = host;
        if (callback == null) return;
        try {
            callback.onSessionEvent(session.handle, session.generation, session.nextSequence(), state);
        } catch (RemoteException e) {
            Log.w(TAG, "回报 " + state + " 失败：宿主已不在");
        }
    }

    /** 宿主进程死了：它开的会话全部按关闭流程走（mosh-client 通知服务器后退出）。 */
    private void watchHostDeath(IShunHost callback, int hostUid) {
        try {
            callback.asBinder().linkToDeath(() -> {
                List<MoshSession> dead = sessions.dropOwner(hostUid);
                for (MoshSession session : dead) session.stop();
                host = null;
                Log.w(TAG, "宿主已退出，关闭 " + dead.size() + " 个会话");
            }, 0);
        } catch (RemoteException e) {
            Log.w(TAG, "宿主在握手途中就退出了");
        }
    }

    private String readDescriptor() {
        long identity = Binder.clearCallingIdentity();
        try (InputStream in = getResources().openRawResource(R.raw.shun_plugin)) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] chunk = new byte[4096];
            int n;
            while ((n = in.read(chunk)) >= 0) out.write(chunk, 0, n);
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new IllegalStateException("读不出描述符");
        } finally {
            Binder.restoreCallingIdentity(identity);
        }
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
