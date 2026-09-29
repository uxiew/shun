package top.xdwa.xwshun.plugin.v1;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * 插件侧的会话表：把宿主给的 handle 和「谁打开的（调用方 UID）」「第几代」绑在一起（X03，PLG06）。
 *
 * <p>用法：openSession 里先 {@code CallerVerifier.requireTrustedCaller()} 拿到 uid，再 {@link #open}；
 * resize/close 里同样先认人，再 {@link #require} / {@link #remove}。
 *
 * <p>为什么认过人还要查 owner：插件可能同时服务多个宿主实例（比如宿主被杀后重启，UID 相同但旧会话已属于上一个进程），
 * 也为了防止 handle 泄露后被同 UID 的另一段代码拿去关别人的会话。generation 让「关掉后又用同一个 handle 重开」
 * 时，旧那一代迟到的调用不会作用到新会话上。
 *
 * <p>线程安全：所有方法 synchronized，Binder 线程和插件自己的线程都可以调。
 */
public final class ProviderSessions<T> {
    private static final Pattern HANDLE = Pattern.compile("^[A-Za-z0-9-]{1,64}$");

    private static final class Entry<T> {
        final int ownerUid;
        final long generation;
        final T value;

        Entry(int ownerUid, long generation, T value) {
            this.ownerUid = ownerUid;
            this.generation = generation;
            this.value = value;
        }
    }

    private final Map<String, Entry<T>> sessions = new HashMap<>();
    private final int maxSessions;

    public ProviderSessions(int maxSessions) {
        this.maxSessions = maxSessions;
    }

    /** handle 格式不对、已存在或会话数到上限时抛 IllegalArgumentException / IllegalStateException。 */
    public synchronized void open(String handle, int ownerUid, long generation, T value) {
        if (handle == null || !HANDLE.matcher(handle).matches()) {
            throw new IllegalArgumentException("会话句柄格式无效");
        }
        if (generation <= 0) throw new IllegalArgumentException("generation 必须为正");
        if (sessions.containsKey(handle)) throw new IllegalStateException("会话句柄已在使用");
        if (sessions.size() >= maxSessions) throw new IllegalStateException("会话数已到上限");
        sessions.put(handle, new Entry<>(ownerUid, generation, value));
    }

    /** handle、owner、generation 三者都对上才返回；否则抛 SecurityException（不存在、别人的）或 IllegalStateException（旧代次）。 */
    public synchronized T require(String handle, int callerUid, long generation) {
        Entry<T> entry = sessions.get(handle);
        if (entry == null || entry.ownerUid != callerUid) {
            // 不区分「不存在」和「是别人的」：否则可以拿它探测别人的 handle 是否有效。
            throw new SecurityException("没有这个会话");
        }
        if (entry.generation != generation) throw new IllegalStateException("会话代次不符（旧的调用）");
        return entry.value;
    }

    /** 幂等：不存在返回 null。存在但 owner/generation 不对照样拒绝，不能借 close 关别人的会话。 */
    public synchronized T remove(String handle, int callerUid, long generation) {
        Entry<T> entry = sessions.get(handle);
        if (entry == null) return null;
        if (entry.ownerUid != callerUid) throw new SecurityException("没有这个会话");
        if (entry.generation != generation) throw new IllegalStateException("会话代次不符（旧的调用）");
        sessions.remove(handle);
        return entry.value;
    }

    /** 插件自己清理（读到 EOF、宿主死亡）时用，不做 owner 检查。 */
    public synchronized T drop(String handle) {
        Entry<T> entry = sessions.remove(handle);
        return entry == null ? null : entry.value;
    }

    /** 宿主某个 UID 的进程死了：它开的会话全部移出并返回，由插件关掉各自的 FD 和 native 对象。 */
    public synchronized List<T> dropOwner(int ownerUid) {
        List<T> out = new ArrayList<>();
        sessions.entrySet().removeIf(e -> {
            if (e.getValue().ownerUid != ownerUid) return false;
            out.add(e.getValue().value);
            return true;
        });
        return out;
    }

    public synchronized int size() {
        return sessions.size();
    }
}
