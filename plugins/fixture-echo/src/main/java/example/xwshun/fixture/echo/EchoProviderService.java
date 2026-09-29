package example.xwshun.fixture.echo;

import android.app.Service;
import android.content.ComponentName;
import android.content.Intent;
import android.content.ServiceConnection;
import android.os.Binder;
import android.os.Bundle;
import android.os.IBinder;
import android.os.ParcelFileDescriptor;
import android.os.RemoteException;
import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.List;

import top.xdwa.xwshun.plugin.v1.CallerVerifier;
import top.xdwa.xwshun.plugin.v1.IXwshunHost;
import top.xdwa.xwshun.plugin.v1.IXwshunProvider;
import top.xdwa.xwshun.plugin.v1.PluginContract;
import top.xdwa.xwshun.plugin.v1.ProviderSessions;

/**
 * 最小的插件服务端。每个方法第一行核对调用方是不是信任的宿主（包名 + 证书），
 * 不在 onBind 挡人——谁都能拿到这个 Binder，但拿到了也调不动（PLG05）。
 *
 * <p>行为由构建参数 -Pbehavior 决定（见 build.gradle.kts），用来做 X03 的故障注入：
 * normal / slowopen（3 秒后才回报 active）/ stubborn（不理 closeSession，持续发事件）/
 * misbehave（发旧代次和伪造 handle 的事件）/ major2（只接受宿主 API major 2）。
 */
public final class EchoProviderService extends Service {
    private static final String TAG = "XwshunEcho";
    private CallerVerifier verifier;
    private String behavior;
    private final ProviderSessions<EchoSession> sessions = new ProviderSessions<>(8);
    private volatile IXwshunHost host;

    @Override
    public void onCreate() {
        super.onCreate();
        verifier = new CallerVerifier(
                this,
                getString(R.string.xwshun_trusted_host_package),
                Collections.singleton(getString(R.string.xwshun_trusted_host_sha256)));
        behavior = getString(R.string.xwshun_fixture_behavior);
        Log.i(TAG, "服务启动，行为=" + behavior);
    }

    @Override
    public IBinder onBind(Intent intent) {
        // 只记下对方在 Intent 里「自称」了什么，从不拿来判断身份。
        Bundle extras = intent.getExtras();
        Log.i(TAG, "onBind extras=" + (extras == null ? "[]" : extras.keySet()));
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

    private final IXwshunProvider.Stub stub = new IXwshunProvider.Stub() {
        @Override
        public String handshake(int hostApiMajor, int hostApiMinor, IXwshunHost callback) {
            int uid = requireHost("handshake");
            int accepted = "major2".equals(behavior) ? 2 : PluginContract.HOST_API_MAJOR;
            if (hostApiMajor != accepted) {
                Log.w(TAG, "handshake 拒绝：宿主 API major " + hostApiMajor + "，本插件只支持 " + accepted);
                throw new IllegalStateException("只支持宿主 API major " + accepted);
            }
            Log.i(TAG, "handshake 接受 uid=" + uid + " hostApi=" + hostApiMajor + "." + hostApiMinor);
            if (callback != null) {
                host = callback;
                watchHostDeath(callback, uid);
                new Thread(() -> afterHandshake(callback)).start();
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
            int uid = requireHost("openSession");
            if (stream == null) throw new IllegalArgumentException("缺少数据流");
            EchoSession session = new EchoSession(handle, generation, uid, stream, cols, rows);
            try {
                sessions.open(handle, uid, generation, session);
            } catch (RuntimeException e) {
                session.close();
                throw e;
            }
            Log.i(TAG, "openSession " + handle + " gen=" + generation + " " + cols + "x" + rows);
            boolean stubborn = "stubborn".equals(behavior);
            session.start(
                    "slowopen".equals(behavior) ? 3000 : 0,
                    () -> {
                        if ("misbehave".equals(behavior)) misbehave(session);
                    },
                    (s, state) -> {
                        // stubborn：宿主关了它那端也装作没事，不回报 closed、不清会话（PLG12）。
                        if (stubborn && "closed".equals(state)) {
                            Log.w(TAG, "会话 " + s.handle + "：宿主已关流，故意不回报 closed");
                            return;
                        }
                        sendSessionEvent(s, state);
                    },
                    () -> {
                        if (!stubborn) sessions.drop(handle);
                    });
        }

        @Override
        public void resizeSession(String handle, long generation, int cols, int rows) {
            int uid = requireHost("resizeSession");
            EchoSession session = sessions.require(handle, uid, generation);
            session.cols = cols;
            session.rows = rows;
            sendSessionEvent(session, "resized:" + cols + "x" + rows);
        }

        @Override
        public void closeSession(String handle, long generation) {
            int uid = requireHost("closeSession");
            if ("stubborn".equals(behavior)) {
                Log.w(TAG, "closeSession " + handle + "：故意不关，并继续发事件");
                EchoSession session = sessions.require(handle, uid, generation);
                keepSendingEvents(session);
                return;
            }
            EchoSession session = sessions.remove(handle, uid, generation);
            if (session != null) session.close(); // 读线程随即结束并回报 closed
        }
    };

    private void sendSessionEvent(EchoSession session, String state) {
        IXwshunHost callback = host;
        if (callback == null) return;
        try {
            callback.onSessionEvent(session.handle, session.generation, session.nextSequence(), state);
        } catch (RemoteException e) {
            Log.w(TAG, "回报 " + state + " 失败：宿主已不在");
        }
    }

    /** 故障注入：旧代次和伪造 handle 的事件，宿主必须丢弃（PLG06）。 */
    private void misbehave(EchoSession session) {
        IXwshunHost callback = host;
        if (callback == null) return;
        try {
            callback.onSessionEvent(session.handle, session.generation - 1, 99, "stale-generation");
            callback.onSessionEvent("forged-handle-0000", session.generation, 99, "forged-handle");
            Log.w(TAG, "已发出旧代次与伪造 handle 的事件");
        } catch (RemoteException ignored) {
            // 宿主已不在
        }
    }

    /** 故障注入：不理 close，每 500 ms 发一个事件，直到进程被杀（PLG12）。 */
    private void keepSendingEvents(EchoSession session) {
        new Thread(() -> {
            while (true) {
                sendSessionEvent(session, "still-running");
                try {
                    Thread.sleep(500);
                } catch (InterruptedException e) {
                    return;
                }
            }
        }, "stubborn-" + session.handle).start();
    }

    /** 宿主进程死了：它开的会话全部关掉（FD 关闭即停止回显），不等宿主来 close（PLG10）。 */
    private void watchHostDeath(IXwshunHost callback, int hostUid) {
        try {
            callback.asBinder().linkToDeath(() -> {
                List<EchoSession> dead = sessions.dropOwner(hostUid);
                for (EchoSession session : dead) session.close();
                host = null;
                Log.w(TAG, "宿主已退出，关闭 " + dead.size() + " 个会话");
            }, 0);
        } catch (RemoteException e) {
            Log.w(TAG, "宿主在握手途中就退出了");
        }
    }

    private void afterHandshake(IXwshunHost callback) {
        try {
            callback.onProviderEvent(1, 1, "ready");
            Log.i(TAG, "已向宿主回报 ready");
        } catch (RemoteException e) {
            Log.w(TAG, "回报 ready 失败：宿主已不在");
        }
        String leakTo = getString(R.string.xwshun_fixture_leak_host_binder_to);
        if (!leakTo.isEmpty()) leakHostBinder(callback, leakTo);
    }

    /** 测试专用：把宿主给的回调 Binder 转交给别的 App，看宿主会不会让它调进来。 */
    private void leakHostBinder(IXwshunHost callback, String target) {
        Intent intent = new Intent(PluginContract.ACTION_PROVIDER)
                .setComponent(new ComponentName(target, target + ".RogueProviderService"));
        boolean bound = bindService(intent, new ServiceConnection() {
            @Override
            public void onServiceConnected(ComponentName name, IBinder service) {
                new Thread(() -> {
                    try {
                        IXwshunProvider.Stub.asInterface(service).handshake(1, 0, callback);
                        Log.i(TAG, "已把宿主回调 Binder 转交给 " + target);
                    } catch (RemoteException | RuntimeException e) {
                        Log.w(TAG, "转交失败：" + e);
                    }
                }).start();
            }

            @Override
            public void onServiceDisconnected(ComponentName name) {}
        }, BIND_AUTO_CREATE);
        Log.i(TAG, "转交宿主 Binder：bind " + target + " -> " + bound);
    }

    private String readDescriptor() {
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
}
