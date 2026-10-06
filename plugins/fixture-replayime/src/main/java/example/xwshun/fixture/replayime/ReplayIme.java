package example.xwshun.fixture.replayime;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Color;
import android.inputmethodservice.InputMethodService;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.inputmethod.InputConnection;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.List;

/**
 * 回放输入法（R18，只用于测试）。收到广播
 * {@code adb shell am broadcast -a example.xwshun.fixture.replayime.RUN -p example.xwshun.fixture.replayime --es script <名字>}
 * 后，按脚本对当前输入连接做和真实输入法一样的调用，每一步打一行日志（tag ReplayIme）。
 *
 * <p>脚本里的位置都从「开始时光标前有多少字」算起：终端编辑区开头有一个哨兵空格，提交后的字也留在
 * 编辑区里，所以不能写死。脚本最后提交一个 Ctrl-C（0x03）：测试在远端用 dd 逐字节收，
 * 收到 Ctrl-C 结束。
 */
public final class ReplayIme extends InputMethodService {
    static final String TAG = "ReplayIme";
    static final String ACTION = "example.xwshun.fixture.replayime.RUN";

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final BroadcastReceiver receiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            run(intent.getStringExtra("script"));
        }
    };

    @Override
    public void onCreate() {
        super.onCreate();
        IntentFilter filter = new IntentFilter(ACTION);
        if (Build.VERSION.SDK_INT >= 33) {
            // adb shell 发的广播要能进来。
            registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED);
        } else {
            registerReceiver(receiver, filter);
        }
    }

    @Override
    public void onDestroy() {
        unregisterReceiver(receiver);
        super.onDestroy();
    }

    @Override
    public View onCreateInputView() {
        TextView view = new TextView(this);
        view.setText("Replay IME（xwshun 测试用，只认 adb 广播）");
        view.setGravity(Gravity.CENTER);
        view.setBackgroundColor(Color.DKGRAY);
        view.setTextColor(Color.WHITE);
        view.setHeight((int) (200 * getResources().getDisplayMetrics().density));
        return view;
    }

    /** 一步：多少毫秒后做什么。 */
    private interface Op {
        void apply(InputConnection ic, int start);
    }

    private static final class Step {
        final int delayMs;
        final String name;
        final Op op;

        Step(int delayMs, String name, Op op) {
            this.delayMs = delayMs;
            this.name = name;
            this.op = op;
        }
    }

    private void run(String script) {
        InputConnection ic = getCurrentInputConnection();
        if (ic == null || script == null) {
            Log.w(TAG, "SKIP " + script + "：没有输入连接");
            return;
        }
        CharSequence before = ic.getTextBeforeCursor(10000, 0);
        int start = before == null ? 0 : before.length();
        List<Step> steps = steps(script);
        if (steps == null) {
            Log.w(TAG, "SKIP 不认识的脚本 " + script);
            return;
        }
        Log.i(TAG, "START " + script + " start=" + start);
        int at = 0;
        for (Step step : steps) {
            at += step.delayMs;
            handler.postDelayed(() -> {
                InputConnection current = getCurrentInputConnection();
                if (current == null) {
                    Log.w(TAG, "LOST " + script + " " + step.name);
                    return;
                }
                Log.i(TAG, "STEP " + script + " " + step.name);
                step.op.apply(current, start);
            }, at);
        }
        handler.postDelayed(() -> Log.i(TAG, "DONE " + script), at + 50);
    }

    private static List<Step> steps(String script) {
        List<Step> s = new ArrayList<>();
        switch (script) {
            case "wechat_voice": {
                // R04 真机日志：每次更新识别结果先结束组字（组字区清掉、文字不变，.758），2 ms 后把组字区
                // 圈回刚出现的那段字（.760），紧接着改写（.761）。「文字不变地结束组字」在 Flutter 的 delta
                // 模式下有编辑记录，finishComposingText 没有（见 finish_only），所以这里用同样的字再提交一次。
                String[] versions = {"你", "你好，", "你好，你谁", "你好啊，你谁", "你好啊，你是谁？", "你好啊，你是谁？在一"};
                for (int i = 0; i < versions.length; i++) {
                    String version = versions[i];
                    if (i > 0) {
                        int previous = versions[i - 1].length();
                        s.add(new Step(100, "re-mark " + previous,
                                (ic, start) -> ic.setComposingRegion(start, start + previous)));
                    }
                    s.add(new Step(i > 0 ? 2 : 100, "compose " + version,
                            (ic, start) -> ic.setComposingText(version, 1)));
                    s.add(new Step(i < versions.length - 1 ? 100 : 600, "end composing " + version,
                            (ic, start) -> ic.commitText(version, 1)));
                }
                break;
            }
            case "finish_only": {
                // 用 finishComposingText 结束组字：Flutter 的 delta 模式只给一个空的编辑列表。
                s.add(new Step(50, "compose 你好", (ic, start) -> ic.setComposingText("你好", 1)));
                s.add(new Step(100, "finish", (ic, start) -> ic.finishComposingText()));
                break;
            }
            case "pinyin": {
                // Gboard 拼音：组字打 nihao，点候选「你好」；再打 ceshi 删光；组字空了再退格删「好」；混排。
                for (String p : new String[] {"n", "ni", "nih", "niha", "nihao"}) {
                    s.add(new Step(50, "compose " + p, (ic, start) -> ic.setComposingText(p, 1)));
                }
                s.add(new Step(50, "commit 你好", (ic, start) -> ic.commitText("你好", 1)));
                for (String p : new String[] {"c", "ce", "ces", "cesh", "ceshi", "cesh", "ces", "ce", "c", ""}) {
                    s.add(new Step(50, "compose '" + p + "'", (ic, start) -> ic.setComposingText(p, 1)));
                }
                s.add(new Step(50, "finish", (ic, start) -> ic.finishComposingText()));
                s.add(new Step(50, "delete 1", (ic, start) -> ic.deleteSurroundingText(1, 0)));
                s.add(new Step(50, "commit ' ok'", (ic, start) -> ic.commitText(" ok", 1)));
                break;
            }
            case "rewrite": {
                // 输入法把已经上屏的字圈回组字区改掉一个字。
                s.add(new Step(50, "commit ab", (ic, start) -> ic.commitText("ab", 1)));
                s.add(new Step(100, "re-mark ab", (ic, start) -> ic.setComposingRegion(start, start + 2)));
                s.add(new Step(2, "compose ac", (ic, start) -> ic.setComposingText("ac", 1)));
                s.add(new Step(100, "finish", (ic, start) -> ic.finishComposingText()));
                break;
            }
            case "emoji": {
                s.add(new Step(50, "commit a👍", (ic, start) -> ic.commitText("a👍", 1)));
                s.add(new Step(100, "delete 2 code units", (ic, start) -> ic.deleteSurroundingText(2, 0)));
                break;
            }
            case "empty_backspace": {
                s.add(new Step(50, "delete 1", (ic, start) -> ic.deleteSurroundingText(1, 0)));
                s.add(new Step(100, "delete 1", (ic, start) -> ic.deleteSurroundingText(1, 0)));
                break;
            }
            case "enter": {
                // 回车键事件之后马上接着打字：这时编辑区刚被清空，输入法的下一次提交还是按它旧的编辑区算的。
                s.add(new Step(50, "commit echo", (ic, start) -> ic.commitText("echo R18-ENTER", 1)));
                s.add(new Step(100, "enter key", (ic, start) -> {
                    ic.sendKeyEvent(new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER));
                    ic.sendKeyEvent(new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER));
                }));
                s.add(new Step(10, "commit x", (ic, start) -> ic.commitText("x", 1)));
                break;
            }
            case "enter_newline": {
                // 回车键事件之后，有的输入法还补一个换行编辑。
                s.add(new Step(50, "commit echo", (ic, start) -> ic.commitText("echo R18-N", 1)));
                s.add(new Step(100, "enter key", (ic, start) -> {
                    ic.sendKeyEvent(new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER));
                    ic.sendKeyEvent(new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER));
                }));
                s.add(new Step(10, "commit newline", (ic, start) -> ic.commitText("\n", 1)));
                break;
            }
            case "type_c":
                // 软键盘打一个 c，不带结尾的 Ctrl-C：配合快捷键栏的 Ctrl 测「Ctrl+软键盘字母」，远端按时限收。
                s.add(new Step(50, "commit c", (ic, start) -> ic.commitText("c", 1)));
                return s;
            default:
                return null;
        }
        s.add(new Step(800, "ctrl-c", (ic, start) -> ic.commitText("\u0003", 1)));
        return s;
    }
}
