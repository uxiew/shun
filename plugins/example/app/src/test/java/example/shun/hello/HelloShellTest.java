// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 xwfe

package example.shun.hello;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.nio.charset.StandardCharsets;

import org.junit.Test;

/**
 * 不装宿主、不开模拟器，在电脑上直接测会话逻辑：{@code ./gradlew :app:testDebugUnitTest}。
 *
 * <p>喂进去的是终端原样的字节（宿主那边用户敲的键），断言的是要写回终端的字节。
 * 握手、认人、FD 这些接线测不了，那部分装到设备上用宿主的「会话测试」看。
 */
public class HelloShellTest {
    private final HelloShell shell = new HelloShell("example.hello_terminal", "0.1.0", 0, "h-1", 1, 80, 24);

    private String feed(String typed) {
        byte[] in = typed.getBytes(StandardCharsets.UTF_8);
        return new String(shell.feed(in, in.length), StandardCharsets.UTF_8);
    }

    @Test
    public void bannerShowsSizeAndPrompt() {
        String banner = new String(shell.banner(false), StandardCharsets.UTF_8);
        assertTrue(banner.contains("终端 80×24"));
        assertTrue(banner.endsWith(HelloShell.PROMPT));
    }

    @Test
    public void typedCharactersAreEchoedAndEnterRunsTheCommand() {
        assertEquals("size", feed("size"));
        assertEquals("\r\n终端大小：80 列 × 24 行\r\n" + HelloShell.PROMPT, feed("\r"));
    }

    @Test
    public void resizeIsVisibleToTheNextCommand() {
        shell.resize(100, 30);
        assertTrue(feed("size\r").contains("100 列 × 30 行"));
    }

    @Test
    public void crLfCountsAsOneEnter() {
        String out = feed("help\r\n");
        assertEquals(1, out.split(HelloShell.PROMPT, -1).length - 1);
    }

    @Test
    public void backspaceErasesOneCellOrTwoForWideCharacters() {
        feed("ab");
        assertEquals("\b \b", feed("\u007f"));
        feed("中");
        assertEquals("\b \b\b \b", feed("\u007f"));
        assertTrue(feed("\r").contains("不认识的命令：a"));
    }

    @Test
    public void escapeSequencesLikeArrowKeysAreSkipped() {
        assertEquals("", feed("\u001b[A\u001bOB"));
        assertEquals("x", feed("x"));
    }

    @Test
    public void exitEndsTheSessionAndIgnoresLaterInput() {
        assertFalse(shell.ended());
        assertTrue(feed("exit\r").contains("再见"));
        assertTrue(shell.ended());
        assertEquals("", feed("help\r"));
    }

    @Test
    public void ctrlDOnAnEmptyLineIsExit() {
        feed("\u0004");
        assertTrue(shell.ended());
    }

    @Test
    public void overlongLinesAreCappedWithABell() {
        StringBuilder longLine = new StringBuilder();
        for (int i = 0; i < HelloShell.MAX_LINE_BYTES + 5; i++) longLine.append('x');
        String out = feed(longLine.toString());
        assertTrue(out.endsWith("\u0007\u0007\u0007\u0007\u0007"));
    }
}
