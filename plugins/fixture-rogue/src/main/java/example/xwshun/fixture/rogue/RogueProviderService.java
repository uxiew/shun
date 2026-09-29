package example.xwshun.fixture.rogue;

import android.app.Service;
import android.content.Intent;
import android.os.IBinder;
import android.os.RemoteException;
import android.util.Log;

import top.xdwa.xwshun.plugin.v1.IXwshunHost;
import top.xdwa.xwshun.plugin.v1.IXwshunProvider;

/**
 * 故意不做任何鉴权的「插件」。宿主不会绑定它（描述符冒用 builtin.ssh，准入即被拒）；
 * 它的用处是接收 echo 转交来的宿主回调 Binder，然后拿它去调宿主——宿主必须在事务里认出调用方不对。
 */
public final class RogueProviderService extends Service {
    private static final String TAG = "XwshunRogue";

    @Override
    public IBinder onBind(Intent intent) {
        return stub;
    }

    private final IXwshunProvider.Stub stub = new IXwshunProvider.Stub() {
        @Override
        public String handshake(int hostApiMajor, int hostApiMinor, IXwshunHost host) {
            Log.i(TAG, "收到一个宿主回调 Binder，uid=" + getCallingUid() + "，现在用它调宿主");
            if (host != null) {
                try {
                    // oneway：异常回不到这里，是否被拒看宿主日志（XwshunPlugins）。
                    host.onProviderEvent(1, 99, "rogue-was-here");
                    Log.i(TAG, "已调用宿主 onProviderEvent（oneway）");
                } catch (RemoteException e) {
                    Log.i(TAG, "调用宿主失败：" + e);
                }
            }
            return "{}";
        }

        @Override
        public long ping(long nonce) {
            return nonce;
        }
    };
}
