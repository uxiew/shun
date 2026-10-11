package example.shun.fixture.rogue;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Intent;
import android.content.ServiceConnection;
import android.os.Bundle;
import android.os.IBinder;
import android.os.ParcelFileDescriptor;
import android.util.Log;

import top.xdwa.shun.plugin.v1.IShunHost;
import top.xdwa.shun.plugin.v1.IShunProvider;
import top.xdwa.shun.plugin.v1.PluginContract;

/**
 * 冒充宿主去调 echo 插件：Intent 里伪造「我是 top.xdwa.shun」，拿到 Binder 后逐个调用每个方法。
 * 结果打到 logcat（tag ShunRogue），每个方法一行：ACCEPTED 就是插件鉴权有洞。
 *
 * adb shell am start -n example.shun.fixture.rogue/.ProbeActivity [--es target <插件包名>] [--es service <服务类名>]
 *
 * 探 Mosh 插件：--es target top.xdwa.shun.mosh --es service top.xdwa.shun.mosh.MoshProviderService
 */
public final class ProbeActivity extends Activity {
    private static final String TAG = "ShunRogue";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        String target = getIntent().getStringExtra("target");
        if (target == null) target = "example.shun.fixture.echo";
        String service = getIntent().getStringExtra("service");
        if (service == null) service = "example.shun.fixture.echo.EchoProviderService";
        Intent intent = new Intent(PluginContract.ACTION_PROVIDER)
                .setComponent(new ComponentName(target, service))
                .putExtra("calling_package", "top.xdwa.shun")
                .putExtra(Intent.EXTRA_PACKAGE_NAME, "top.xdwa.shun")
                .putExtra("signing_sha256", "trust-me");
        ServiceConnection connection = new ServiceConnection() {
            @Override
            public void onServiceConnected(ComponentName name, IBinder service) {
                IShunProvider provider = IShunProvider.Stub.asInterface(service);
                new Thread(() -> {
                    probe("handshake", () -> provider.handshake(1, 0, new IShunHost.Stub() {
                        @Override
                        public void onProviderEvent(long generation, long sequence, String event) {}

                        @Override
                        public void onSessionEvent(String handle, long generation, long sequence, String state) {}
                    }));
                    probe("ping", () -> provider.ping(42));
                    probe("openSession", () -> {
                        ParcelFileDescriptor[] pair = ParcelFileDescriptor.createSocketPair();
                        try {
                            provider.openSession("rogue-0001", 1, 80, 24, pair[1]);
                            return "opened";
                        } finally {
                            pair[0].close();
                            pair[1].close();
                        }
                    });
                    probe("openMoshSession", () -> {
                        ParcelFileDescriptor[] pair = ParcelFileDescriptor.createSocketPair();
                        try {
                            provider.openMoshSession("rogue-0002", 1, 80, 24, pair[1], "127.0.0.1", 60001,
                                    "AAAAAAAAAAAAAAAAAAAAAA".getBytes(java.nio.charset.StandardCharsets.US_ASCII));
                            return "opened";
                        } finally {
                            pair[0].close();
                            pair[1].close();
                        }
                    });
                    probe("resizeSession", () -> {
                        provider.resizeSession("rogue-0001", 1, 80, 24);
                        return "resized";
                    });
                    probe("closeSession", () -> {
                        provider.closeSession("rogue-0001", 1);
                        return "closed";
                    });
                    runOnUiThread(() -> {
                        unbindService(this);
                        finish();
                    });
                }).start();
            }

            @Override
            public void onServiceDisconnected(ComponentName name) {}
        };
        boolean bound = bindService(intent, connection, BIND_AUTO_CREATE);
        Log.i(TAG, "bind " + target + "（Intent 里自称是宿主）-> " + bound);
        if (!bound) finish();
    }

    private interface Call {
        Object run() throws Exception;
    }

    private static void probe(String method, Call call) {
        try {
            Object value = call.run();
            Log.w(TAG, "PROBE " + method + " -> ACCEPTED (" + value + ")");
        } catch (SecurityException e) {
            Log.i(TAG, "PROBE " + method + " -> SecurityException: " + e.getMessage());
        } catch (Exception e) {
            Log.i(TAG, "PROBE " + method + " -> " + e.getClass().getSimpleName() + ": " + e.getMessage());
        }
    }
}
