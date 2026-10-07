// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 xwfe

package example.xwshun.hello;

import android.app.Service;
import android.content.Intent;
import android.os.Binder;
import android.os.IBinder;
import android.os.ParcelFileDescriptor;
import android.os.RemoteException;
import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;

import top.xdwa.xwshun.plugin.v1.CallerVerifier;
import top.xdwa.xwshun.plugin.v1.IXwshunHost;
import top.xdwa.xwshun.plugin.v1.IXwshunProvider;
import top.xdwa.xwshun.plugin.v1.PluginContract;
import top.xdwa.xwshun.plugin.v1.ProviderSessions;

/**
 * 插件服务：宿主绑定它、握手、然后开关会话。照着它写你自己的插件时，下面几条规矩不能省：
 *
 * <ol>
 *   <li>每个 AIDL 方法的<b>第一行</b>调 {@link CallerVerifier#requireTrustedCaller()}。不在 onBind 查：
 *       宿主绑定之后，别的 App 用同样的 Intent 去绑，系统直接把同一个 Binder 给它，onBind 根本不会再被调用
 *       （X02 在模拟器上实测过）。
 *   <li>三个会话方法都立即返回。读写字节放在会话自己的线程里（{@link HelloSession}）；
 *       在 Binder 线程上阻塞会卡住宿主对这个插件的所有调用。
 *   <li>会话句柄、代次由宿主给，用 {@link ProviderSessions} 和调用方 UID 绑在一起；三者对不上就拒绝。
 *   <li>不认识或不支持的东西抛 {@link IllegalStateException} / {@link UnsupportedOperationException}，宿主会如实显示，
 *       不要返回假成功。
 * </ol>
 */
public final class HelloProviderService extends Service {
    static final String TAG = "XwshunHello";

    /** 一个插件同时开的会话上限。到了上限 openSession 抛错，宿主显示「插件拒绝：会话数已到上限」。 */
    private static final int MAX_SESSIONS = 4;

    private CallerVerifier verifier;
    private final ProviderSessions<HelloSession> sessions = new ProviderSessions<>(MAX_SESSIONS);
    private final AtomicLong providerSequence = new AtomicLong();
    private volatile IXwshunHost host;
    private volatile IBinder.DeathRecipient hostDeath;
    /** 握手时协商出来的宿主 API minor。宿主比插件新时，插件只用自己认识的那部分。 */
    private volatile int hostApiMinor;

    @Override
    public void onCreate() {
        super.onCreate();
        // 宿主包名 + 宿主证书 SHA-256 都来自构建参数（app/build.gradle.kts），不是运行时谁说了算。
        String[] digests = getString(R.string.xwshun_host_sha256).split(",");
        verifier = new CallerVerifier(
                this,
                getString(R.string.xwshun_host_package),
                new HashSet<>(Arrays.asList(digests)));
    }

    @Override
    public IBinder onBind(Intent intent) {
        // 谁都能拿到这个 Binder，拿到了也调不动：每个方法自己认人。Intent 里的 extras 是对方随便写的，一概不看。
        return stub;
    }

    private final IXwshunProvider.Stub stub = new IXwshunProvider.Stub() {
        @Override
        public String handshake(int hostApiMajor, int hostApiMinor, IXwshunHost callback) {
            int uid = requireHost("handshake");
            // 版本协商：major 不同就是不兼容，minor 只追加。抛 IllegalStateException，宿主显示
            // 「连接失败：插件不接受宿主的 API 版本：<这里的话>」。话要写清楚要什么版本。
            if (hostApiMajor != PluginContract.HOST_API_MAJOR) {
                throw new IllegalStateException("本插件只支持宿主 API " + PluginContract.HOST_API_MAJOR
                        + ".x，宿主是 " + hostApiMajor + "." + hostApiMinor);
            }
            int minMinor = getResources().getInteger(R.integer.xwshun_min_host_minor);
            if (hostApiMinor < minMinor) {
                throw new IllegalStateException("本插件要求宿主 API 1." + minMinor + " 及以上，宿主是 1." + hostApiMinor);
            }
            HelloProviderService.this.hostApiMinor = hostApiMinor;
            if (callback == null) throw new IllegalStateException("宿主没有给回调接口");
            watchHost(callback, uid);
            providerSequence.set(0);
            Log.i(TAG, "握手：宿主 API " + hostApiMajor + "." + hostApiMinor + "，uid=" + uid);
            sendProviderEvent("ready");
            return readDescriptor();
        }

        @Override
        public long ping(long nonce) {
            requireHost("ping");
            return nonce;
        }

        @Override
        public void openSession(String handle, long generation, int cols, int rows, ParcelFileDescriptor stream) {
            int uid = requireHost("openSession");
            if (stream == null) throw new IllegalArgumentException("缺少数据流");
            if (host == null) {
                close(stream);
                throw new IllegalStateException("还没握手");
            }
            HelloSession session = new HelloSession(
                    HelloProviderService.this, handle, generation, stream, cols, rows, hostApiMinor);
            try {
                sessions.open(handle, uid, generation, session); // 句柄格式、重复、上限都在这里查
            } catch (RuntimeException e) {
                session.close();
                throw e;
            }
            Log.i(TAG, "openSession " + handle + " gen=" + generation + " " + cols + "x" + rows);
            session.start(HelloProviderService.this::sendSessionEvent, () -> sessions.drop(handle));
        }

        @Override
        public void resizeSession(String handle, long generation, int cols, int rows) {
            int uid = requireHost("resizeSession");
            HelloSession session = sessions.require(handle, uid, generation);
            session.resize(cols, rows);
            sendSessionEvent(session, "resized:" + cols + "x" + rows);
        }

        @Override
        public void closeSession(String handle, long generation) {
            int uid = requireHost("closeSession");
            // 幂等：已经关了、不存在都直接返回。关掉 FD 后会话线程自己回报 closed，宿主据此确认「已停止」。
            HelloSession session = sessions.remove(handle, uid, generation);
            if (session != null) session.close();
        }

        @Override
        public void openMoshSession(String handle, long generation, int cols, int rows, ParcelFileDescriptor stream,
                String udpHost, int udpPort, byte[] printableKey) {
            requireHost("openMoshSession");
            // 不做 Mosh 的插件也要实现这个方法（AIDL 接口里有它）：收到的临时密钥立刻清零、流关掉、明确拒绝。
            // 描述符没申请 own-session-ephemeral-secret，宿主本来就不会调到这里。
            if (printableKey != null) Arrays.fill(printableKey, (byte) 0);
            close(stream);
            throw new UnsupportedOperationException("样例插件不提供 Mosh 会话");
        }
    };

    private int requireHost(String method) {
        try {
            return verifier.requireTrustedCaller();
        } catch (SecurityException e) {
            Log.w(TAG, method + " 拒绝：" + e.getMessage());
            throw e;
        }
    }

    /** 宿主进程死了：它开的会话全部关掉，不等宿主来 close（宿主已经不在了）。 */
    private void watchHost(IXwshunHost callback, int hostUid) {
        IXwshunHost previous = host;
        IBinder.DeathRecipient previousDeath = hostDeath;
        if (previous != null && previousDeath != null) {
            previous.asBinder().unlinkToDeath(previousDeath, 0);
        }
        IBinder.DeathRecipient death = () -> {
            List<HelloSession> dead = sessions.dropOwner(hostUid);
            for (HelloSession session : dead) session.close();
            host = null;
            Log.w(TAG, "宿主已退出，关闭 " + dead.size() + " 个会话");
        };
        try {
            callback.asBinder().linkToDeath(death, 0);
        } catch (RemoteException e) {
            throw new IllegalStateException("宿主在握手途中退出了");
        }
        host = callback;
        hostDeath = death;
    }

    /** 插件级事件（比如 ready）。宿主插件页的「事件」里看得到；短的状态名，不超过 64 字符。 */
    private void sendProviderEvent(String event) {
        IXwshunHost callback = host;
        if (callback == null) return;
        try {
            callback.onProviderEvent(1, providerSequence.incrementAndGet(), event);
        } catch (RemoteException e) {
            Log.w(TAG, "回报 " + event + " 失败：宿主已不在");
        }
    }

    /**
     * 会话状态：active / resized:COLSxROWS / closed / failed:<原因>。每个会话的序号从 1 递增，
     * 宿主丢掉序号不增、代次不对的事件。回调是 oneway 的，不会阻塞调用它的线程。
     */
    void sendSessionEvent(HelloSession session, String state) {
        IXwshunHost callback = host;
        if (callback == null) return;
        try {
            callback.onSessionEvent(session.handle, session.generation, session.nextSequence(), state);
        } catch (RemoteException e) {
            Log.w(TAG, "回报 " + state + " 失败：宿主已不在");
        }
    }

    /** handshake 的返回值：和清单里给宿主看的是同一份描述符，pluginId 对不上宿主会断开。 */
    private String readDescriptor() {
        // 读自己的资源不需要调用方身份；先清掉，免得系统按宿主的身份去查权限。
        long identity = Binder.clearCallingIdentity();
        try (InputStream in = getResources().openRawResource(R.raw.xwshun_plugin)) {
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

    private static void close(ParcelFileDescriptor stream) {
        if (stream == null) return;
        try {
            stream.close();
        } catch (IOException ignored) {
            // 已关
        }
    }
}
