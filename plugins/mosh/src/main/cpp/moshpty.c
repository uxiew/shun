// mosh 插件的 PTY / 子进程管理（JNI）。
//
// 为什么要 PTY：mosh-client 启动时 tcgetattr(stdin)，不是终端就退出；它还靠 SIGWINCH 知道窗口变了。
// 为什么要子进程：mosh-client 是完整程序（exit()、全局单例、信号处理），放进插件进程会让一个会话带走所有会话。
//
// 秘密（mosh 会话 key）经一根管道交给子进程：fork 之前把 22 个字节写进管道、关掉写端，子进程从继承的 fd 3 读
// （我们给 mosh-client 打的补丁 0002：MOSH_KEY_FD=3）。不用官方的 MOSH_KEY 环境变量，因为 mosh-client 读完虽然
// unsetenv，内核里那份初始环境块还在，整个进程活着期间 /proc/<pid>/environ 都读得到。也不进命令行参数（ps 看得到）、
// 不写文件、不进日志。管道里的字节被子进程读走就没了；父进程里那份 22 字节缓冲写完立刻清零。
#define _GNU_SOURCE  // pipe2
#include <jni.h>
#include <android/log.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#define TAG "XwshunMoshPty"
#define MAX_ENV 16
#define KEY_LEN 22   // mosh 的 key：16 字节 base64、去掉 "=="

static void throw_io(JNIEnv *env, const char *what, int err) {
    char msg[160];
    snprintf(msg, sizeof msg, "%s: %s", what, strerror(err));
    jclass cls = (*env)->FindClass(env, "java/io/IOException");
    if (cls) (*env)->ThrowNew(env, cls, msg);
}

static void throw_arg(JNIEnv *env, const char *msg) {
    jclass cls = (*env)->FindClass(env, "java/lang/IllegalArgumentException");
    if (cls) (*env)->ThrowNew(env, cls, msg);
}

// 只认数字形式的 IPv4/IPv6：插件不做 DNS，目标地址由宿主按路由解析好再给（docs/16 运行流程第 4 步）。
JNIEXPORT jboolean JNICALL
Java_top_xdwa_xwshun_mosh_MoshPty_isNumericAddress(JNIEnv *env, jclass cls, jstring jhost) {
    (void) cls;
    if (jhost == NULL) return JNI_FALSE;
    const char *host = (*env)->GetStringUTFChars(env, jhost, NULL);
    if (host == NULL) return JNI_FALSE;
    unsigned char buf[16];
    jboolean ok = (inet_pton(AF_INET, host, buf) == 1 || inet_pton(AF_INET6, host, buf) == 1) ? JNI_TRUE : JNI_FALSE;
    (*env)->ReleaseStringUTFChars(env, jhost, host);
    return ok;
}

// explicit_bzero 要 API 28；minSdk 24 上自己写，volatile 防止编译器把「写完就释放」的清零优化掉。
static void wipe(char *p, size_t n) {
    volatile char *v = p;
    while (n--) *v++ = 0;
}

static int is_key_char(unsigned char c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '+' || c == '/';
}

// 返回 int[]{pid, masterFd}。argv、env 是非秘密的固定串；key 是 22 个 base64 字符（字节，不是 String，用完调用方清零）。
JNIEXPORT jintArray JNICALL
Java_top_xdwa_xwshun_mosh_MoshPty_spawn(JNIEnv *env, jclass cls, jstring jpath, jobjectArray jargv,
                                       jobjectArray jenv, jbyteArray jkey, jint rows, jint cols) {
    (void) cls;
    if (rows <= 0 || cols <= 0 || rows > 1000 || cols > 1000) { throw_arg(env, "窗口尺寸越界"); return NULL; }
    jsize argc = (*env)->GetArrayLength(env, jargv);
    jsize envc = (*env)->GetArrayLength(env, jenv);
    if (argc < 1 || argc > 8 || envc > MAX_ENV - 2) { throw_arg(env, "参数个数越界"); return NULL; }
    if ((*env)->GetArrayLength(env, jkey) != KEY_LEN) { throw_arg(env, "key 长度不对"); return NULL; }

    // 先把要用的东西都在父进程里准备好：fork 之后（多线程进程里）只能调异步信号安全的函数。
    char *path = NULL, *argv[9] = {0}, *envp[MAX_ENV] = {0};
    char key[KEY_LEN];
    char keyfd_var[] = "MOSH_KEY_FD=3";
    int master = -1, ok = 0, keypipe[2] = {-1, -1};
    const char *s = (*env)->GetStringUTFChars(env, jpath, NULL);
    path = strdup(s);
    (*env)->ReleaseStringUTFChars(env, jpath, s);
    for (jsize i = 0; i < argc; i++) {
        jstring a = (jstring) (*env)->GetObjectArrayElement(env, jargv, i);
        s = (*env)->GetStringUTFChars(env, a, NULL);
        argv[i] = strdup(s);
        (*env)->ReleaseStringUTFChars(env, a, s);
        (*env)->DeleteLocalRef(env, a);
    }
    for (jsize i = 0; i < envc; i++) {
        jstring a = (jstring) (*env)->GetObjectArrayElement(env, jenv, i);
        s = (*env)->GetStringUTFChars(env, a, NULL);
        envp[i] = strdup(s);
        (*env)->ReleaseStringUTFChars(env, a, s);
        (*env)->DeleteLocalRef(env, a);
    }
    (*env)->GetByteArrayRegion(env, jkey, 0, KEY_LEN, (jbyte *) key);
    for (int i = 0; i < KEY_LEN; i++) {
        if (!is_key_char((unsigned char) key[i])) { throw_arg(env, "key 含非 base64 字符"); goto out; }
    }
    envp[envc] = keyfd_var;

    // 先写好、关掉写端：子进程读到 22 字节后就是 EOF，不会卡住；22 字节远小于管道缓冲，write 不会阻塞。
    if (pipe2(keypipe, O_CLOEXEC) != 0) { throw_io(env, "pipe2", errno); goto out; }
    if (write(keypipe[1], key, KEY_LEN) != KEY_LEN) { throw_io(env, "write key", errno); goto out; }
    close(keypipe[1]);
    keypipe[1] = -1;
    wipe(key, sizeof key);
    if (keypipe[0] <= 3) { throw_io(env, "key pipe fd", EBADF); goto out; }  // 下面要 dup2 到 3，不能和 0–3 撞

    master = open("/dev/ptmx", O_RDWR | O_CLOEXEC | O_NOCTTY);
    if (master < 0) { throw_io(env, "open /dev/ptmx", errno); goto out; }
    if (grantpt(master) != 0 || unlockpt(master) != 0) { throw_io(env, "grantpt/unlockpt", errno); goto out; }
    char slave_name[64];
    if (ptsname_r(master, slave_name, sizeof slave_name) != 0) { throw_io(env, "ptsname_r", errno); goto out; }
    struct winsize ws = {.ws_row = (unsigned short) rows, .ws_col = (unsigned short) cols};
    ioctl(master, TIOCSWINSZ, &ws);
    // 输入按 UTF-8 处理（行规程删字时按字符删）；mosh-client 起来后会自己切成 raw。
    struct termios tio;
    if (tcgetattr(master, &tio) == 0) {
        tio.c_iflag |= IUTF8;
        tcsetattr(master, TCSANOW, &tio);
    }
    struct rlimit rl;
    int maxfd = (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur != RLIM_INFINITY && rl.rlim_cur < 65536)
                ? (int) rl.rlim_cur : 4096;

    pid_t pid = fork();
    if (pid < 0) { throw_io(env, "fork", errno); goto out; }
    if (pid == 0) {
        // 子进程：新会话、PTY 从端当控制终端和 0/1/2，其余 fd 全关（不能把插件的 socket、Binder 漏给 mosh-client）。
        sigset_t all;
        sigfillset(&all);
        sigprocmask(SIG_UNBLOCK, &all, NULL);
        for (int sig = 1; sig < NSIG; sig++) signal(sig, SIG_DFL);
        setsid();
        int slave = open(slave_name, O_RDWR);
        if (slave < 0) _exit(127);
        ioctl(slave, TIOCSCTTY, 0);
        dup2(slave, 0);
        dup2(slave, 1);
        dup2(slave, 2);
        dup2(keypipe[0], 3);  // dup2 出来的 fd 不带 CLOEXEC，exec 后 mosh-client 从 3 读 key
        for (int fd = 4; fd < maxfd; fd++) close(fd);
        execve(path, argv, envp);
        _exit(127);
    }
    ok = 1;
    jintArray result = (*env)->NewIntArray(env, 2);
    jint vals[2] = {pid, master};
    (*env)->SetIntArrayRegion(env, result, 0, 2, vals);
    __android_log_print(ANDROID_LOG_INFO, TAG, "spawned pid=%d", pid);  // 只记 pid，不记参数和环境
out:
    wipe(key, sizeof key);
    if (keypipe[0] >= 0) close(keypipe[0]);  // 父进程不留读端：子进程那份读完、关掉，管道就没了
    if (keypipe[1] >= 0) close(keypipe[1]);
    free(path);
    for (int i = 0; argv[i]; i++) free(argv[i]);
    for (int i = 0; i < MAX_ENV && envp[i]; i++) if (envp[i] != keyfd_var) free(envp[i]);
    if (!ok) {
        if (master >= 0) close(master);
        return NULL;
    }
    return result;
}

JNIEXPORT void JNICALL
Java_top_xdwa_xwshun_mosh_MoshPty_setWindowSize(JNIEnv *env, jclass cls, jint fd, jint rows, jint cols) {
    (void) env; (void) cls;
    if (rows <= 0 || cols <= 0 || rows > 1000 || cols > 1000) return;
    struct winsize ws = {.ws_row = (unsigned short) rows, .ws_col = (unsigned short) cols};
    ioctl(fd, TIOCSWINSZ, &ws);  // 内核随之给前台进程组（mosh-client）发 SIGWINCH
}

// 阻塞到子进程退出。返回退出码；被信号杀死返回 128 + 信号号。
JNIEXPORT jint JNICALL
Java_top_xdwa_xwshun_mosh_MoshPty_waitFor(JNIEnv *env, jclass cls, jint pid) {
    (void) cls;
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) { throw_io(env, "waitpid", errno); return -1; }
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -1;
}
