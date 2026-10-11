// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 xwfe

package example.shun.hello;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;

/**
 * 样例的「shell」本身：字节进、字节出，不碰任何 Android 类。
 *
 * <p>拆出来是为了不装宿主也能测：{@code app/src/test} 里的 {@code HelloShellTest} 在电脑上用 JVM 直接跑它
 * （{@code ./gradlew :app:testDebugUnitTest}）。你的插件也照这样把「收到什么、回什么」写成纯 Java，
 * 和 FD、Binder 这些接线分开，逻辑在电脑上就能测完。
 *
 * <p>输入是终端原样的字节：回车是 {@code \r}（有的终端发 {@code \r\n}），退格是 0x7f 或 0x08，方向键是 ESC 开头的序列。
 * 输出要换行写 {@code \r\n}，颜色用 ANSI 转义序列。只在一个线程里用（会话的读线程），不加锁。
 */
final class HelloShell {
    static final String PROMPT = "hello> ";
    /** 一行最多收这么多字节，再多的输入响铃丢掉：插件的内存要有上限。 */
    static final int MAX_LINE_BYTES = 1024;

    private final String pluginId;
    private final String version;
    private final int hostApiMinor;
    private final String handle;
    private final long generation;
    private final ByteArrayOutputStream line = new ByteArrayOutputStream();
    private volatile int cols;
    private volatile int rows;
    /** 0：普通输入；1：刚收到 ESC；2：在 CSI 序列（ESC [ …）里。方向键之类样例不处理，整段跳过。 */
    private int escape;
    private boolean lastWasCr;
    private boolean ended;

    HelloShell(String pluginId, String version, int hostApiMinor, String handle, long generation,
            int cols, int rows) {
        this.pluginId = pluginId;
        this.version = version;
        this.hostApiMinor = hostApiMinor;
        this.handle = handle;
        this.generation = generation;
        this.cols = cols;
        this.rows = rows;
    }

    /** 宿主改了终端尺寸。可以在别的线程调（Binder 线程）：只记下新值，输入 size 时能看到。 */
    void resize(int cols, int rows) {
        this.cols = cols;
        this.rows = rows;
    }

    /** 用户要结束会话了（exit，或空行上按 Ctrl-D）：调用方写完最后的输出就关流。 */
    boolean ended() {
        return ended;
    }

    byte[] banner(boolean color) {
        String title = color ? "\u001b[1;36mHello 终端\u001b[0m" : "Hello 终端";
        return bytes(title + "：shun 插件样例\r\n"
                + "宿主 API 1." + hostApiMinor + " · 终端 " + cols + "×" + rows + " · 输入 help 看命令\r\n"
                + PROMPT);
    }

    /** 喂进一段用户输入，返回要写回终端的字节。结束之后再喂的东西不处理。 */
    byte[] feed(byte[] buffer, int n) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        for (int i = 0; i < n && !ended; i++) {
            int b = buffer[i] & 0xff;
            boolean lfAfterCr = b == '\n' && lastWasCr;
            lastWasCr = b == '\r';
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
                    write(out, "\r\n");
                    String command = new String(line.toByteArray(), StandardCharsets.UTF_8).trim();
                    line.reset();
                    runCommand(command, out);
                    if (!ended) write(out, PROMPT);
                    break;
                }
                case 0x7f:
                case 0x08:
                    int width = eraseLastChar();
                    for (int k = 0; k < width; k++) write(out, "\b \b");
                    break;
                case 0x03: // Ctrl-C：丢掉这一行
                    line.reset();
                    write(out, "^C\r\n" + PROMPT);
                    break;
                case 0x04: // Ctrl-D：空行上等于 exit
                    if (line.size() == 0) runCommand("exit", out);
                    break;
                default:
                    if (b < 0x20) break; // 别的控制字符不处理
                    if (line.size() >= MAX_LINE_BYTES) {
                        out.write(0x07);
                        break;
                    }
                    line.write(b);
                    out.write(b); // 本地回显：用户打的字原样显示
            }
        }
        return out.toByteArray();
    }

    private void runCommand(String command, ByteArrayOutputStream out) {
        switch (command) {
            case "":
                return;
            case "help":
                write(out, "help   看这份说明\r\n"
                        + "size   宿主告诉插件的终端大小（宿主改尺寸后会变）\r\n"
                        + "color  输出几种颜色，看宿主怎么显示 ANSI 转义序列\r\n"
                        + "info   插件、宿主 API 版本、这个会话的句柄和代次\r\n"
                        + "exit   插件这边结束会话（宿主会收到 closed）\r\n");
                return;
            case "size":
                write(out, "终端大小：" + cols + " 列 × " + rows + " 行\r\n");
                return;
            case "color":
                write(out, "\u001b[31m红\u001b[0m \u001b[32m绿\u001b[0m \u001b[34m蓝\u001b[0m "
                        + "\u001b[1m粗体\u001b[0m \u001b[7m反显\u001b[0m\r\n");
                return;
            case "info":
                write(out, "插件 " + pluginId + " " + version + "；宿主 API 1." + hostApiMinor + "\r\n"
                        + "会话句柄 " + handle + "，代次 " + generation + "\r\n");
                return;
            case "exit":
                write(out, "再见。插件这边结束会话。\r\n");
                ended = true;
                return;
            default:
                write(out, "不认识的命令：" + command + "。输入 help 看能用的命令。\r\n");
        }
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

    private static void write(ByteArrayOutputStream out, String text) {
        byte[] b = bytes(text);
        out.write(b, 0, b.length);
    }

    static byte[] bytes(String text) {
        return text.getBytes(StandardCharsets.UTF_8);
    }
}
