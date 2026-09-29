package example.xwshun.fixture.rogue;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Intent;
import android.content.ServiceConnection;
import android.os.Bundle;
import android.os.IBinder;
import android.util.Log;

import top.xdwa.xwshun.plugin.v1.IXwshunHost;
import top.xdwa.xwshun.plugin.v1.IXwshunProvider;
import top.xdwa.xwshun.plugin.v1.PluginContract;

/**
 * 冒充宿主去调 echo 插件：Intent 里伪造「我是 top.xdwa.xwshun」，拿到 Binder 后逐个调用每个方法。
 * 结果打到 logcat（tag XwshunRogue），每个方法一行：ACCEPTED 就是插件鉴权有洞。
 *
 * adb shell am start -n example.xwshun.fixture.rogue/.ProbeActivity [--es target <插件包名>]
 */
public final class ProbeActivity extends Activity {
    private static final String TAG = "XwshunRogue";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        String target = getIntent().getStringExtra("target");
        if (target == null) target = "example.xwshun.fixture.echo";
        Intent intent = new Intent(PluginContract.ACTION_PROVIDER)
                .setComponent(new ComponentName(target, "example.xwshun.fixture.echo.EchoProviderService"))
                .putExtra("calling_package", "top.xdwa.xwshun")
                .putExtra(Intent.EXTRA_PACKAGE_NAME, "top.xdwa.xwshun")
                .putExtra("signing_sha256", "trust-me");
        ServiceConnection connection = new ServiceConnection() {
            @Override
            public void onServiceConnected(ComponentName name, IBinder service) {
                IXwshunProvider provider = IXwshunProvider.Stub.asInterface(service);
                new Thread(() -> {
                    probe("handshake", () -> provider.handshake(1, 0, new IXwshunHost.Stub() {
                        @Override
                        public void onProviderEvent(long generation, long sequence, String event) {}
                    }));
                    probe("ping", () -> provider.ping(42));
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
