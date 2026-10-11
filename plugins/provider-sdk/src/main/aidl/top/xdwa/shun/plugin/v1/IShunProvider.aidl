// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 xwfe

// 插件服务端接口（插件 APK 实现，宿主绑定后调用）。API major 1。
//
// 规则（细节见 docs/plugin-authors/contract.md 第 3–6 节）：
// - 每个方法在执行任何动作之前，先用 Binder.getCallingUid() 核对调用方的实际包名和签名证书
//   （CallerVerifier.requireTrustedCaller）。不能只在 onBind 查，不能信 Intent 里自报的包名。
// - 只追加方法，不重排、不改已有方法的语义（minor 协商见 handshake）。
// - 这里没有、以后也不会有通用 execute/任意 JSON 命令、读文件、读保险库的方法。
package top.xdwa.shun.plugin.v1;

import top.xdwa.shun.plugin.v1.IShunHost;

interface IShunProvider {
    // 宿主告诉插件自己的 API 版本，并交出回调接口。
    // 返回插件描述符 JSON（必须与清单里的静态描述符是同一个 pluginId）。
    // 插件不接受宿主的 major 时抛 IllegalStateException，宿主据此判定不兼容。
    String handshake(int hostApiMajor, int hostApiMinor, IShunHost host);

    // 存活检查：原样返回 nonce。不带任何数据，不改变状态。
    long ping(long nonce);

    // ---- 以下为终端会话。v1.0 发布前补齐；发布后只在末尾追加，不改上面任何方法。----
    //
    // handle：宿主生成的不透明会话句柄（≤64 个字母数字或连字符）。插件把它和调用方 UID、generation 绑在一起，
    //         之后的 resize/close 三者都要对上；拿着别人的 handle 调不动。
    // generation：宿主为这次打开分配的代次，单调递增。旧代次的调用一律拒绝。
    // stream：宿主用 socketpair 建好、交给插件的那一端。终端字节只走这里，不经 Binder。
    //         插件读到的是用户输入，写进去的是终端输出；读到 EOF 表示宿主关了，插件随之清理。
    // 这三个方法都立即返回，长操作放到插件自己的线程；结果通过 IShunHost.onSessionEvent 回报。
    void openSession(String handle, long generation, int cols, int rows, in ParcelFileDescriptor stream);
    void resizeSession(String handle, long generation, int cols, int rows);
    // 幂等：已关或不存在的会话直接返回。
    void closeSession(String handle, long generation);

    // ---- Mosh 会话。只在末尾追加。----
    // 注意：不认识某个方法的旧插件被调到时，Binder 不报错——生成的代理不看 transact 的返回值，
    // 空回复读出来就是「没异常」，void 方法像是成功了、有返回值的拿到 null/0（读生成代码发现）。
    // 所以以后追加的方法，调用方要先按对方声明的 apiMinor 判断它有没有，不能靠调用失败来发现。
    //
    // 和 openSession 一样建会话，另带宿主这次 bootstrap（经 SSH 在服务器上启动 mosh-server）得到的临时材料：
    // udpHost：宿主按路由解析好的数字 IP（IPv4/IPv6 字面量）。插件不做 DNS，非数字直接拒绝。
    // udpPort：mosh-server 报的 UDP 端口，1–65535。
    // printableKey：mosh-server 报的 22 个 base64 字符（ASCII 字节）。是秘密：插件只放内存、只交给运行时，
    //               不写盘、不进日志、不进命令行参数，用完清零。宿主这边同样。
    // 只有声明了 own-session-ephemeral-secret 且被批准的插件，宿主才会调这个方法。
    void openMoshSession(String handle, long generation, int cols, int rows, in ParcelFileDescriptor stream,
            String udpHost, int udpPort, in byte[] printableKey);
}
