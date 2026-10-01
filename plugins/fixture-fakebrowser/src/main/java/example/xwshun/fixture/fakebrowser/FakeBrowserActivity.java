package example.xwshun.fixture.fakebrowser;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.util.Log;
import android.widget.TextView;

/**
 * 扮演浏览器：收下链接，原样记进日志、显示在屏幕上，不打开、不联网（R14 测试用）。
 *
 * <p>日志写整条链接：测试要核对本 App 交出来的就是 banner 里那条，链接里的 token 是 fixture 随机编的。
 */
public class FakeBrowserActivity extends Activity {
    static final String TAG = "XwshunFakeBrowser";

    private TextView text;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        text = new TextView(this);
        text.setPadding(48, 96, 48, 48);
        text.setTextSize(18);
        setContentView(text);
        handle(getIntent(), "onCreate");
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        handle(intent, "onNewIntent");
    }

    private void handle(Intent intent, String via) {
        Uri data = intent == null ? null : intent.getData();
        if (data == null) {
            text.setText("假浏览器（测试用）\n等别的 App 交链接过来。");
            return;
        }
        Log.i(TAG, "RECEIVED via=" + via
                + " uri=" + data
                + " action=" + intent.getAction()
                + " categories=" + intent.getCategories()
                + " referrer=" + getReferrer());
        text.setText("假浏览器（测试用）\n\n收到：\n" + data
                + "\n\n来自：" + getReferrer()
                + "\n\n真实浏览器这时会打开这个页面，让你登录 Tailscale 并确认。这里什么都不做。");
    }
}
