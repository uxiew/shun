package example.xwshun.fixture.fakeuu;

import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.widget.TextView;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.List;

/**
 * 扮演 UU 远程：收下 uuremote://external/device/{authorize,control} 请求，按设定的模式回调（X06 测试用）。
 *
 * <p>回调照官方文档的说法拼：在对方给的 callback 后面追加结果字段，保留 callback 原有参数。
 * 日志只写参数名、长度和加密 ID 的哈希前缀，不写 ID 原文——测试要在 logcat 里搜本 App 有没有泄露它。
 *
 * <p>绑定模式（authorize 请求）：
 * bind_ok、bind_ok_b（另一个 ID）、bind_ok_raw（ID 里的 + 不编码）、bind_error:&lt;错误码&gt;、
 * bind_wrong_nonce、bind_dup（nonce 出现两次）、bind_twice（同一回调 1.5 秒后再发一次）、bind_long、bind_none、
 * bind_late:&lt;秒&gt;（延迟回调，测冷启动）。
 * <p>小窗模式（window_type=1 的 control 请求）：
 * pip_success、pip_failure:&lt;reason&gt;、pip_twice、pip_late:&lt;秒&gt;、pip_none。
 * <p>全屏（window_type=0）：和官方一样从不回调。
 */
public class FakeUuActivity extends Activity {
    static final String TAG = "XwshunFakeUu";
    static final String DEFAULT_MODE = "bind_ok";

    static final String ID_A = "Zm9v+YmFy/YmF6==";
    static final String ID_B = "QmFy+Rm9v/QmF6==";
    static final String ID_RAW = "cmF3+cGx1cw==";

    private final Handler main = new Handler(Looper.getMainLooper());
    private TextView text;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        text = new TextView(this);
        text.setPadding(48, 96, 48, 48);
        text.setTextSize(18);
        setContentView(text);
        handle(getIntent());
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        handle(intent);
    }

    private void handle(Intent intent) {
        Uri data = intent == null ? null : intent.getData();
        if (data == null) {
            text.setText("假 UU 远程（测试用）。等本 App 发请求。");
            return;
        }
        String raw = data.toString();
        String path = data.getPath();
        String callback = param(raw, "callback");
        SharedPreferences prefs = getSharedPreferences("fakeuu", MODE_PRIVATE);
        String mode = prefs.getString("mode", DEFAULT_MODE);
        if ("/device/authorize".equals(path)) {
            String nonce = param(raw, "nonce");
            Log.i(TAG, "request authorize params=" + names(raw)
                    + " callback=" + describe(callback)
                    + " nonceIsUuid=" + (nonce != null && nonce.matches("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"))
                    + " mode=" + mode);
            text.setText("假 UU：收到绑定请求\n模式 " + mode);
            if (!mode.startsWith("bind_")) mode = DEFAULT_MODE;
            bind(callback, nonce, mode);
        } else if ("/device/control".equals(path)) {
            String id = param(raw, "anonymous_device_id");
            String window = param(raw, "window_type");
            String rawId = rawParam(raw, "anonymous_device_id");
            Log.i(TAG, "request control params=" + names(raw)
                    + " window_type=" + window
                    + " idHash=" + hash(id)
                    + " idRawHasPlus=" + (rawId != null && rawId.contains("+"))
                    + " callback=" + describe(callback)
                    + " mode=" + mode);
            text.setText("假 UU：收到远控请求 window_type=" + window + "\n模式 " + mode);
            if ("1".equals(window) && callback != null) {
                if (!mode.startsWith("pip_")) mode = "pip_success";
                pip(callback, mode);
            } else {
                Log.i(TAG, "fullscreen or no callback: no reply (as the official protocol says)");
            }
        } else {
            Log.i(TAG, "request unknown path=" + path);
        }
    }

    private void bind(String callback, String nonce, String mode) {
        if (callback == null) {
            Log.i(TAG, "authorize without callback: no reply");
            return;
        }
        String n = nonce == null ? "" : nonce;
        if (mode.equals("bind_none")) {
            Log.i(TAG, "reply none");
            return;
        }
        if (mode.startsWith("bind_error:")) {
            send(append(callback, "error", mode.substring("bind_error:".length()), "nonce", n), 0);
            return;
        }
        if (mode.startsWith("bind_late:")) {
            // 延迟回调：测试脚本趁这段时间强杀本 App，看回调把它冷启动起来后还能不能对上请求。
            long seconds = Long.parseLong(mode.substring("bind_late:".length()));
            send(append(callback, "anonymous_device_id", ID_A, "nonce", n), seconds * 1000);
            return;
        }
        switch (mode) {
            case "bind_ok_b":
                send(append(callback, "anonymous_device_id", ID_B, "nonce", n), 0);
                break;
            case "bind_ok_raw":
                // + 故意不编码：看本 App 是不是把它按字面收下（而不是当成空格）。
                send(callback + "&anonymous_device_id=" + ID_RAW.replace("=", "%3D") + "&nonce=" + Uri.encode(n), 0);
                break;
            case "bind_wrong_nonce":
                send(append(callback, "anonymous_device_id", ID_A, "nonce", "00000000-0000-4000-8000-000000000000"), 0);
                break;
            case "bind_dup":
                send(append(callback, "anonymous_device_id", ID_A, "nonce", n) + "&nonce=" + Uri.encode(n), 0);
                break;
            case "bind_long":
                send(append(callback, "anonymous_device_id", repeat('a', 5000), "nonce", n), 0);
                break;
            case "bind_twice": {
                String cb = append(callback, "anonymous_device_id", ID_A, "nonce", n);
                send(cb, 0);
                send(cb, 1500);
                break;
            }
            default:
                send(append(callback, "anonymous_device_id", ID_A, "nonce", n), 0);
        }
    }

    private void pip(String callback, String mode) {
        if (mode.equals("pip_none")) {
            Log.i(TAG, "reply none");
            return;
        }
        if (mode.startsWith("pip_failure:")) {
            send(append(callback, "status", "failure", "reason", mode.substring("pip_failure:".length())), 0);
            return;
        }
        if (mode.startsWith("pip_late:")) {
            long seconds = Long.parseLong(mode.substring("pip_late:".length()));
            send(append(callback, "status", "success"), seconds * 1000);
            return;
        }
        String cb = append(callback, "status", "success");
        send(cb, 0);
        if (mode.equals("pip_twice")) send(cb, 1500);
    }

    /** 回调：隐式 VIEW Intent，由系统交给声明了这个 scheme 的 App（正常情况就是本 App）。 */
    private void send(String callback, long delayMs) {
        main.postDelayed(() -> {
            Log.i(TAG, "reply " + describeReply(callback));
            Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse(callback));
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            getApplicationContext().startActivity(intent);
            finish();
        }, delayMs + 300);
    }

    /** 在 callback 后面追加结果字段，值编码一次（照官方示例的 Uri.encode）。 */
    private static String append(String callback, String... pairs) {
        StringBuilder out = new StringBuilder(callback);
        for (int i = 0; i < pairs.length; i += 2) {
            out.append(out.indexOf("?") >= 0 ? '&' : '?')
                    .append(pairs[i]).append('=').append(Uri.encode(pairs[i + 1]));
        }
        return out.toString();
    }

    /** 查询参数原文（未解码）。 */
    private static String rawParam(String uri, String key) {
        int q = uri.indexOf('?');
        if (q < 0) return null;
        for (String part : uri.substring(q + 1).split("&")) {
            int eq = part.indexOf('=');
            if (eq > 0 && part.substring(0, eq).equals(key)) return part.substring(eq + 1);
        }
        return null;
    }

    /** 解一次百分号编码，+ 按字面（Uri.decode 不把 + 当空格）。 */
    private static String param(String uri, String key) {
        String raw = rawParam(uri, key);
        return raw == null ? null : Uri.decode(raw);
    }

    private static String names(String uri) {
        int q = uri.indexOf('?');
        List<String> out = new ArrayList<>();
        if (q >= 0) {
            for (String part : uri.substring(q + 1).split("&")) {
                int eq = part.indexOf('=');
                out.add(eq < 0 ? part : part.substring(0, eq));
            }
        }
        return out.toString();
    }

    /** callback 只记 scheme://host/path、它自带的参数名和 state 长度，不记 state 本身。 */
    private static String describe(String callback) {
        if (callback == null) return "null";
        Uri cb = Uri.parse(callback);
        String state = cb.getQueryParameter("state");
        return cb.getScheme() + "://" + cb.getHost() + cb.getPath()
                + " own=" + names(callback)
                + " stateLen=" + (state == null ? 0 : state.length());
    }

    private static String describeReply(String callback) {
        Uri cb = Uri.parse(callback);
        return cb.getScheme() + "://" + cb.getHost() + cb.getPath() + " params=" + names(callback)
                + " status=" + cb.getQueryParameter("status")
                + " reason=" + cb.getQueryParameter("reason")
                + " error=" + cb.getQueryParameter("error")
                + " idHash=" + hash(param(callback, "anonymous_device_id"));
    }

    static String hash(String value) {
        if (value == null) return "null";
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8));
            StringBuilder hex = new StringBuilder();
            for (int i = 0; i < 6; i++) hex.append(String.format("%02x", digest[i]));
            return hex.toString();
        } catch (Exception e) {
            return "?";
        }
    }

    private static String repeat(char c, int n) {
        char[] chars = new char[n];
        java.util.Arrays.fill(chars, c);
        return new String(chars);
    }
}
