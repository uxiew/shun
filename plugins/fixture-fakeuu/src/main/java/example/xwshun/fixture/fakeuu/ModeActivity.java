package example.xwshun.fixture.fakeuu;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;

/** 设定下一次收到请求时怎么回。模式见 FakeUuActivity。只给测试脚本用。 */
public class ModeActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        String mode = getIntent().getStringExtra("mode");
        if (mode == null) mode = FakeUuActivity.DEFAULT_MODE;
        getSharedPreferences("fakeuu", MODE_PRIVATE).edit().putString("mode", mode).commit();
        Log.i(FakeUuActivity.TAG, "mode=" + mode);
        finish();
    }
}
