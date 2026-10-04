package top.xdwa.xwshun.mosh;

import java.io.IOException;

/** libmoshpty.so 的薄壳。实现和「为什么」见 src/main/cpp/moshpty.c。 */
final class MoshPty {
    static {
        System.loadLibrary("moshpty");
    }

    private MoshPty() {}

    /** 只认数字形式的 IPv4/IPv6（inet_pton），不做 DNS。 */
    static native boolean isNumericAddress(String host);

    /**
     * 开 PTY、fork、exec。返回 {pid, PTY 主端 fd}。key 是 22 个 base64 字符的字节，调用方用完自己清零。
     * 环境变量和参数都不能含秘密（ps / 日志能看到参数）。
     */
    static native int[] spawn(String path, String[] argv, String[] env, byte[] key, int rows, int cols)
            throws IOException;

    static native void setWindowSize(int fd, int rows, int cols);

    /** 阻塞到子进程退出；返回退出码，被信号杀死时 128 + 信号号。 */
    static native int waitFor(int pid) throws IOException;
}
