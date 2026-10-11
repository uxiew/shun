package example.shun.fixture.fakerustdesk;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.util.Log;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * 扮演 RustDesk：收下 rustdesk:// 链接，把收到的东西原样记进日志（X07 测试用）。
 *
 * <p>和真实 RustDesk 一样，它从不把任何结果告诉发起方——链接里本来就没有回调地址。
 * 日志写整条链接：测试要核对的正是「本 App 发出来的每一个字符」，RustDesk ID 在测试里是编的。
 * 每次收到一行，字段：via（冷启动还是已在运行）、uri、action、categories、extras 的键、flags、
 * newTask（是不是带着 FLAG_ACTIVITY_NEW_TASK 来的）、referrer（系统报告的来源 App）。
 */
public class FakeRustDeskActivity extends Activity {
    static final String TAG = "ShunFakeRd";

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
        String me = getPackageName();
        if (data == null) {
            text.setText("假 RustDesk（测试用）\n" + me + "\n等本 App 发链接。");
            Log.i(TAG, "opened without link via=" + via + " pkg=" + me);
            return;
        }
        List<String> extras = new ArrayList<>();
        if (intent.getExtras() != null) extras.addAll(intent.getExtras().keySet());
        Collections.sort(extras);
        List<String> categories = new ArrayList<>();
        if (intent.getCategories() != null) categories.addAll(intent.getCategories());
        Collections.sort(categories);
        Uri referrer = getReferrer();
        boolean newTask = (intent.getFlags() & Intent.FLAG_ACTIVITY_NEW_TASK) != 0;
        Log.i(TAG, "RECEIVED via=" + via
                + " pkg=" + me
                + " uri=" + data
                + " action=" + intent.getAction()
                + " categories=" + categories
                + " extras=" + extras
                + " flags=0x" + Integer.toHexString(intent.getFlags())
                + " newTask=" + newTask
                + " taskRoot=" + isTaskRoot()
                + " referrer=" + referrer);
        text.setText("假 RustDesk（测试用）\n" + me + "\n\n收到：\n" + data
                + "\n\n来自：" + referrer
                + "\n\n真实的 RustDesk 这时会开始连接。它不会把结果告诉发起的 App。");
    }
}
