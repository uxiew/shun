package example.xwshun.hello;

import android.content.Context;
import android.os.ParcelFileDescriptor;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

/**
 * 一个会话：很小的行编辑「shell」，只认几条演示命令（help、size、color、info、exit）。
 *
 * <p>字节流的约定（宿主那边是终端，所以这里和写一个终端程序一样）：
 * <ul>
 *   <li>从 FD 读到的是用户的输入，原样的终端字节：回车是 {@code \r}，退格是 0x7f，方向键是 ESC 开头的序列；
 *   <li>往 FD 写的是终端输出：要换行写 {@code \r\n}，颜色用 ANSI 转义序列；
 *   <li>读到 EOF 表示宿主关了，插件随之清理、回报 closed。
 * </ul>
 * 读写都在这个会话自己的线程里。宿主不读输出时 write 会阻塞，读线程随之不再读输入——背压就这样传回宿主，不用另设队列。
 */
final class HelloSession {
    interface Events {
        void send(HelloSession session, String state);
    }

    private static final String PROMPT = "hello> ";
    /** 一行最多收这么多字节，再多的输入响铃丢掉：插件的内存要有上限。 */
    private static final int MAX_LINE_BYTES = 1024;

    final String handle;
    final long generation;
    private final Context context;
    private final ParcelFileDescriptor stream;
    private final int hostApiMinor;
    private final AtomicBoolean closed = new AtomicBoolean();
    private final AtomicLong sequence = new AtomicLong();
    private final ByteArrayOutputStream line = new ByteArrayOutputStream();
    private volatile int cols;
    private volatile int rows;
    /** 0：普通输入；1：刚收到 ESC；2：在 CSI 序列（ESC [ …）里。方向键之类样例不处理，整段跳过。 */
    private int escape;
    private boolean lastWasCr;

    HelloSession(Context context, String handle, long generation, ParcelFileDescriptor stream,
            int cols, int rows, int hostApiMinor) {
        this.context = context.getApplicationContext();
        this.handle = handle;
        this.generation = generation;
        this.stream = stream;
        this.cols = cols;
        this.rows = rows;
        this.hostApiMinor = hostApiMinor;
    }

    long nextSequence() {
        return sequence.incrementAndGet();
    }

    /** 改尺寸只记下新值，不往终端写字：这个方法在 Binder 线程上调，写 FD 可能阻塞。输入 size 能看到新值。 */
    void resize(int cols, int rows) {
        this.cols = cols;
        this.rows = rows;
    }

    void start(Events events, Runnable onEnd) {
        new Thread(() -> run(events, onEnd), "hello-" + handle).start();
    }

    private void run(Events events, Runnable onEnd) {
        // 先回报 active，宿主才把会话当成「可以收发了」。
        events.send(this, "active");
        String reason = "宿主关闭";
        try (FileInputStream in = new FileInputStream(stream.getFileDescriptor());
             FileOutputStream out = new FileOutputStream(stream.getFileDescriptor())) {
            out.write(banner());
            byte[] buffer = new byte[4096];
            int n;
            while ((n = in.read(buffer)) >= 0) {
                if (!onInput(buffer, n, out)) {
                    reason = "用户输入 exit";
                    break;
                }
            }
        } catch (IOException e) {
            // 被 close() 叫醒，或者宿主那端断了
        }
        Log.i(HelloProviderService.TAG, "会话 " + handle + " 结束：" + reason);
        // 先关流再回报 closed：最后写的字在 closed 之前到宿主。宿主读到 EOF 后等 300 ms，等到 closed 就记「已关闭」，
        // 等不到才记成「中断」。
        close();
        events.send(this, "closed");
        onEnd.run();
    }

    /** @return false 表示插件这边要结束会话（exit，或空行上按 Ctrl-D）。 */
    private boolean onInput(byte[] buffer, int n, FileOutputStream out) throws IOException {
        ByteArrayOutputStream echo = new ByteArrayOutputStream();
        for (int i = 0; i < n; i++) {
            int b = buffer[i] & 0xff;
            boolean cr = b == '\r';
            boolean lfAfterCr = b == '\n' && lastWasCr;
            lastWasCr = cr;
            if (escape == 1) {
                escape = (b == '[' || b == 'O') ? 2 : 0;
                continue;
            }
            if (escape == 2) {
                if (b >= 0x40 && b <= 0x7e) escape = 0; // CSI 的结尾字节
                continue;
            }
            if (lfAfterCr) continue; // 有的终端回车发 \r\n，只算一次
            switch (b) {
                case 0x1b:
                    escape = 1;
                    break;
                case '\r':
                case '\n': {
                    echo.write(bytes("\r\n"));
                    out.write(echo.toByteArray());
                    echo.reset();
                    String command = new String(line.toByteArray(), StandardCharsets.UTF_8).trim();
                    line.reset();
                    if (!runCommand(command, out)) return false;
                    out.write(bytes(PROMPT));
                    break;
                }
                case 0x7f:
                case 0x08:
                    int width = eraseLastChar();
                    for (int k = 0; k < width; k++) echo.write(bytes("\b \b"));
                    break;
                case 0x03: // Ctrl-C：丢掉这一行
                    line.reset();
                    echo.write(bytes("^C\r\n" + PROMPT));
                    break;
                case 0x04: // Ctrl-D：空行上等于 exit
                    if (line.size() == 0) {
                        out.write(echo.toByteArray());
                        return runCommand("exit", out);
                    }
                    break;
                default:
                    if (b < 0x20) break; // 别的控制字符不处理
                    if (line.size() >= MAX_LINE_BYTES) {
                        echo.write(0x07);
                        break;
                    }
                    line.write(b);
                    echo.write(b); // 本地回显：用户打的字原样显示
            }
        }
        out.write(echo.toByteArray());
        return true;
    }

    /** 删掉行尾一个 UTF-8 字符，返回它在终端上占几格（中日韩文字 2 格）。 */
    private int eraseLastChar() {
        byte[] bytes = line.toByteArray();
        int end = bytes.length;
        if (end == 0) return 0;
        int start = end - 1;
        while (start > 0 && (bytes[start] & 0xc0) == 0x80) start--;
        String removed = new String(bytes, start, end - start, StandardCharsets.UTF_8);
        line.reset();
        line.write(bytes, 0, start);
        return removed.isEmpty() ? 1 : (isWide(removed.codePointAt(0)) ? 2 : 1);
    }

    private static boolean isWide(int cp) {
        return (cp >= 0x1100 && cp <= 0x115f) || (cp >= 0x2e80 && cp <= 0xa4cf)
                || (cp >= 0xac00 && cp <= 0xd7a3) || (cp >= 0xf900 && cp <= 0xfaff)
                || (cp >= 0xfe30 && cp <= 0xfe4f) || (cp >= 0xff00 && cp <= 0xff60)
                || (cp >= 0xffe0 && cp <= 0xffe6) || (cp >= 0x20000 && cp <= 0x3fffd);
    }

    /** @return false 表示结束会话。 */
    private boolean runCommand(String command, FileOutputStream out) throws IOException {
        switch (command) {
            case "":
                return true;
            case "help":
                out.write(bytes("help   看这份说明\r\n"
                        + "size   宿主告诉插件的终端大小（宿主改尺寸后会变）\r\n"
                        + "color  输出几种颜色，看宿主怎么显示 ANSI 转义序列\r\n"
                        + "info   插件、宿主 API 版本、这个会话的句柄和代次\r\n"
                        + "exit   插件这边结束会话（宿主会收到 closed）\r\n"));
                return true;
            case "size":
                out.write(bytes("终端大小：" + cols + " 列 × " + rows + " 行\r\n"));
                return true;
            case "color":
                out.write(bytes("\u001b[31m红\u001b[0m \u001b[32m绿\u001b[0m \u001b[34m蓝\u001b[0m "
                        + "\u001b[1m粗体\u001b[0m \u001b[7m反显\u001b[0m\r\n"));
                return true;
            case "info":
                out.write(bytes("插件 example.hello_terminal 0.1.0；宿主 API 1." + hostApiMinor + "\r\n"
                        + "会话句柄 " + handle + "，代次 " + generation + "\r\n"));
                return true;
            case "exit":
                out.write(bytes("再见。插件这边结束会话。\r\n"));
                return false;
            default:
                out.write(bytes("不认识的命令：" + command + "。输入 help 看能用的命令。\r\n"));
                return true;
        }
    }

    private byte[] banner() {
        boolean color = context.getSharedPreferences(SettingsActivity.PREFS, Context.MODE_PRIVATE)
                .getBoolean(SettingsActivity.KEY_COLOR_BANNER, true);
        String title = color ? "\u001b[1;36mHello 终端\u001b[0m" : "Hello 终端";
        return bytes(title + "：xwshun 插件样例\r\n"
                + "宿主 API 1." + hostApiMinor + " · 终端 " + cols + "×" + rows + " · 输入 help 看命令\r\n"
                + PROMPT);
    }

    private static byte[] bytes(String text) {
        return text.getBytes(StandardCharsets.UTF_8);
    }

    /** 幂等。先 shutdown 叫醒阻塞在 read/write 上的线程（只 close 叫不醒），再关 FD。 */
    void close() {
        if (!closed.compareAndSet(false, true)) return;
        try {
            Os.shutdown(stream.getFileDescriptor(), OsConstants.SHUT_RDWR);
        } catch (ErrnoException ignored) {
            // 对端已断
        }
        try {
            stream.close();
        } catch (IOException ignored) {
            // 已关
        }
    }
}
