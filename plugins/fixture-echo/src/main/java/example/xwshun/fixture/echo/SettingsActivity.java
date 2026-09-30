package example.xwshun.fixture.echo;

import android.app.Activity;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.util.Log;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * 插件自己的设置页（X04 / SDK04 的测试用）。宿主用约定的 action 查出它、显式打开，不带任何 extras。
 *
 * <p>这里的设置只存在插件自己的偏好里，宿主看不到也不管——这正是要验证的「设置归属清楚」。
 * 打开时记一行日志，方便在 logcat 里确认是谁、带了什么打开的它。
 */
public final class SettingsActivity extends Activity {
    private static final String TAG = "XwshunEcho";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Bundle extras = getIntent().getExtras();
        Log.i(TAG, "设置页打开 action=" + getIntent().getAction()
                + " extras=" + (extras == null ? "[]" : extras.keySet()));

        SharedPreferences prefs = getSharedPreferences("echo_settings", MODE_PRIVATE);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = (int) (24 * getResources().getDisplayMetrics().density);
        root.setPadding(pad, pad, pad, pad);

        TextView title = new TextView(this);
        title.setText("Echo 测试插件自己的设置页");
        title.setTextSize(20);
        root.addView(title);

        TextView note = new TextView(this);
        note.setText("这里的设置存在插件自己的存储里，宿主看不到。");
        root.addView(note);

        CheckBox upper = new CheckBox(this);
        upper.setText("回显时转成大写（只是演示，echo 实际不读它）");
        upper.setChecked(prefs.getBoolean("upper", false));
        upper.setOnCheckedChangeListener((v, checked) -> {
            prefs.edit().putBoolean("upper", checked).apply();
            Log.i(TAG, "设置页：upper=" + checked);
        });
        root.addView(upper);
        setContentView(root);
    }
}
