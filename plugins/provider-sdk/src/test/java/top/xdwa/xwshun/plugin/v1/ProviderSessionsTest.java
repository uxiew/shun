package top.xdwa.xwshun.plugin.v1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import java.util.List;

import org.junit.Test;

/** PLG06（插件侧）：handle 与调用方 UID、generation 绑定。纯 JVM，不需要设备。 */
public class ProviderSessionsTest {
    private static final int HOST = 10207;
    private static final int OTHER = 10209;

    private static void expect(Class<? extends RuntimeException> type, Runnable call) {
        try {
            call.run();
            fail("应当抛 " + type.getSimpleName());
        } catch (RuntimeException e) {
            assertTrue(e.getClass().getSimpleName(), type.isInstance(e));
        }
    }

    @Test
    public void 别的UID拿着有效handle调不动也关不掉() {
        ProviderSessions<String> s = new ProviderSessions<>(4);
        s.open("h1", HOST, 1, "session");
        expect(SecurityException.class, () -> s.require("h1", OTHER, 1));
        expect(SecurityException.class, () -> s.remove("h1", OTHER, 1));
        assertEquals("session", s.require("h1", HOST, 1));
    }

    @Test
    public void 旧代次的调用被拒绝() {
        ProviderSessions<String> s = new ProviderSessions<>(4);
        s.open("h1", HOST, 2, "second");
        expect(IllegalStateException.class, () -> s.require("h1", HOST, 1));
        expect(IllegalStateException.class, () -> s.remove("h1", HOST, 1));
        assertEquals(1, s.size());
    }

    @Test
    public void 关闭幂等且关后同handle重开是新一代() {
        ProviderSessions<String> s = new ProviderSessions<>(4);
        s.open("h1", HOST, 1, "a");
        assertEquals("a", s.remove("h1", HOST, 1));
        assertNull(s.remove("h1", HOST, 1));
        s.open("h1", HOST, 2, "b");
        expect(IllegalStateException.class, () -> s.require("h1", HOST, 1));
    }

    @Test
    public void 不存在和是别人的给同样的错误() {
        ProviderSessions<String> s = new ProviderSessions<>(4);
        s.open("h1", HOST, 1, "a");
        String a = null;
        String b = null;
        try {
            s.require("nope", HOST, 1);
        } catch (SecurityException e) {
            a = e.getMessage();
        }
        try {
            s.require("h1", OTHER, 1);
        } catch (SecurityException e) {
            b = e.getMessage();
        }
        assertEquals(a, b);
    }

    @Test
    public void 句柄格式和数量有上限() {
        ProviderSessions<String> s = new ProviderSessions<>(2);
        expect(IllegalArgumentException.class, () -> s.open("../x", HOST, 1, "a"));
        expect(IllegalArgumentException.class, () -> s.open("h", HOST, 0, "a"));
        s.open("h1", HOST, 1, "a");
        expect(IllegalStateException.class, () -> s.open("h1", HOST, 2, "dup"));
        s.open("h2", HOST, 1, "b");
        expect(IllegalStateException.class, () -> s.open("h3", HOST, 1, "c"));
    }

    @Test
    public void 宿主死亡只清它自己的会话() {
        ProviderSessions<String> s = new ProviderSessions<>(4);
        s.open("h1", HOST, 1, "mine");
        s.open("h2", OTHER, 1, "theirs");
        List<String> dropped = s.dropOwner(HOST);
        assertEquals(List.of("mine"), dropped);
        assertEquals(1, s.size());
    }
}
