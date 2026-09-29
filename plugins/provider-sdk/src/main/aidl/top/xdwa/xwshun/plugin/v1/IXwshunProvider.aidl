// 插件服务端接口（插件 APK 实现，宿主绑定后调用）。API major 1。
//
// 规则（docs/15 §4–§5）：
// - 每个方法在执行任何动作之前，先用 Binder.getCallingUid() 核对调用方的实际包名和签名证书
//   （CallerVerifier.requireTrustedCaller）。不能只在 onBind 查，不能信 Intent 里自报的包名。
// - 只追加方法，不重排、不改已有方法的语义（minor 协商见 handshake）。
// - 这里没有、以后也不会有通用 execute/任意 JSON 命令、读文件、读保险库的方法。
package top.xdwa.xwshun.plugin.v1;

import top.xdwa.xwshun.plugin.v1.IXwshunHost;

interface IXwshunProvider {
    // 宿主告诉插件自己的 API 版本，并交出回调接口。
    // 返回插件描述符 JSON（必须与清单里的静态描述符是同一个 pluginId）。
    // 插件不接受宿主的 major 时抛 IllegalStateException，宿主据此判定不兼容。
    String handshake(int hostApiMajor, int hostApiMinor, IXwshunHost host);

    // 存活检查：原样返回 nonce。不带任何数据，不改变状态。
    long ping(long nonce);
}
