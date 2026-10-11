// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 xwfe

package example.shun.hello;

import android.app.Activity;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * 插件自己的设置页（可选）。宿主详情页点「打开插件的设置页」时用显式组件打开它，不带任何参数。
 *
 * <p>设置存在插件自己的存储里，宿主看不到也不管：要什么设置、存在哪，由插件自己决定。
 * 这个页面是导出的，任何 App 都能打开它，所以别在这里放只该给宿主看的东西，也别信打开它的 Intent 里带的任何参数。
 */
public final class SettingsActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        SharedPreferences prefs = getSharedPreferences(HelloSession.PREFS, MODE_PRIVATE);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = (int) (24 * getResources().getDisplayMetrics().density);
        root.setPadding(pad, pad, pad, pad);

        TextView title = new TextView(this);
        title.setText("Hello 终端（样例）的设置");
        title.setTextSize(20);
        root.addView(title);

        TextView note = new TextView(this);
        note.setText("这里的设置存在插件自己的存储里，宿主看不到。改了之后，下一次打开的会话生效。");
        root.addView(note);

        CheckBox color = new CheckBox(this);
        color.setText("欢迎语用彩色");
        color.setChecked(prefs.getBoolean(HelloSession.KEY_COLOR_BANNER, true));
        color.setOnCheckedChangeListener((view, checked) ->
                prefs.edit().putBoolean(HelloSession.KEY_COLOR_BANNER, checked).apply());
        root.addView(color);

        setContentView(root);
    }
}
