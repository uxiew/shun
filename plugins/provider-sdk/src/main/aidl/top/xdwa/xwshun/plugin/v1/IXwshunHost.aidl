// 宿主回调接口（宿主实现，在 handshake 时交给插件）。
//
// 宿主在每个事务里核对调用方 UID 是不是当初批准并绑定的那个插件、证书是否仍是批准时的那张。
// 这个 Binder 被插件转交给别的 App 也没用：别的 App 调进来 UID 对不上，直接拒绝。
package top.xdwa.xwshun.plugin.v1;

interface IXwshunHost {
    // 插件状态事件。generation/sequence 单调，旧代次或不递增的事件被丢弃（docs/15 §5）。
    // event 是短的状态名（如 "ready"），不是任意负载；超过 64 字符直接拒绝。
    oneway void onProviderEvent(long generation, long sequence, String event);
}
