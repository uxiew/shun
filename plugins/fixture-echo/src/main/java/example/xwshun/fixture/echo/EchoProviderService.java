package example.xwshun.fixture.echo;

import android.app.Service;
import android.content.ComponentName;
import android.content.Intent;
import android.content.ServiceConnection;
import android.os.Bundle;
import android.os.IBinder;
import android.os.RemoteException;
import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.Collections;

import top.xdwa.xwshun.plugin.v1.CallerVerifier;
import top.xdwa.xwshun.plugin.v1.IXwshunHost;
import top.xdwa.xwshun.plugin.v1.IXwshunProvider;
import top.xdwa.xwshun.plugin.v1.PluginContract;

/**
 * 最小的插件服务端。每个方法第一行核对调用方是不是信任的宿主（包名 + 证书），
 * 不在 onBind 挡人——谁都能拿到这个 Binder，但拿到了也调不动（PLG05）。
 */
public final class EchoProviderService extends Service {
    private static final String TAG = "XwshunEcho";
    private CallerVerifier verifier;

    @Override
    public void onCreate() {
        super.onCreate();
        verifier = new CallerVerifier(
                this,
                getString(R.string.xwshun_trusted_host_package),
                Collections.singleton(getString(R.string.xwshun_trusted_host_sha256)));
    }

    @Override
    public IBinder onBind(Intent intent) {
        // 只记下对方在 Intent 里「自称」了什么，从不拿来判断身份。
        Bundle extras = intent.getExtras();
        Log.i(TAG, "onBind extras=" + (extras == null ? "[]" : extras.keySet()));
        return stub;
    }

    private final IXwshunProvider.Stub stub = new IXwshunProvider.Stub() {
        @Override
        public String handshake(int hostApiMajor, int hostApiMinor, IXwshunHost host) {
            int uid;
            try {
                uid = verifier.requireTrustedCaller();
            } catch (SecurityException e) {
                Log.w(TAG, "handshake 拒绝：" + e.getMessage());
                throw e;
            }
            if (hostApiMajor != PluginContract.HOST_API_MAJOR) {
                throw new IllegalStateException("只支持宿主 API major " + PluginContract.HOST_API_MAJOR);
            }
            Log.i(TAG, "handshake 接受 uid=" + uid + " hostApi=" + hostApiMajor + "." + hostApiMinor);
            if (host != null) {
                new Thread(() -> afterHandshake(host)).start();
            }
            return readDescriptor();
        }

        @Override
        public long ping(long nonce) {
            try {
                verifier.requireTrustedCaller();
            } catch (SecurityException e) {
                Log.w(TAG, "ping 拒绝：" + e.getMessage());
                throw e;
            }
            return nonce;
        }
    };

    private void afterHandshake(IXwshunHost host) {
        try {
            host.onProviderEvent(1, 1, "ready");
            Log.i(TAG, "已向宿主回报 ready");
        } catch (RemoteException e) {
            Log.w(TAG, "回报 ready 失败：宿主已不在");
        }
        String leakTo = getString(R.string.xwshun_fixture_leak_host_binder_to);
        if (!leakTo.isEmpty()) leakHostBinder(host, leakTo);
    }

    /** 测试专用：把宿主给的回调 Binder 转交给别的 App，看宿主会不会让它调进来。 */
    private void leakHostBinder(IXwshunHost host, String target) {
        Intent intent = new Intent(PluginContract.ACTION_PROVIDER)
                .setComponent(new ComponentName(target, target + ".RogueProviderService"));
        boolean bound = bindService(intent, new ServiceConnection() {
            @Override
            public void onServiceConnected(ComponentName name, IBinder service) {
                new Thread(() -> {
                    try {
                        IXwshunProvider.Stub.asInterface(service).handshake(1, 0, host);
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
        try (InputStream in = getResources().openRawResource(R.raw.xwshun_plugin)) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] chunk = new byte[4096];
            int n;
            while ((n = in.read(chunk)) >= 0) out.write(chunk, 0, n);
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new IllegalStateException("读不出描述符");
        }
    }
}
