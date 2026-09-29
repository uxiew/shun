# 04 ProxyJump、外部SOCKS5与复用语义

## 必须正确解释“复用”

使用已经运行的TailSocks、ssh -D或远程SOCKS服务，复用的是**代理服务以及它管理的上游隧道**。每个新的目标TCP连接仍建立独立SOCKS5 CONNECT；每个独立最终SSH client通常仍做自己的握手认证。标准CONNECT不提供一条已连接字节流上的任意多目标复用。[S28](13-sources.md#s28)

```text
本App ──新SOCKS CONNECT──> 已在运行的本地SOCKS服务 ──它管理的既有隧道──> 目标
```

App不重新执行外部ssh -D命令，也不重建外部TailSocks节点；但本App无法保证外部程序没有自行重拨，应只显示自身可观测的阶段。

## 支持矩阵

| 模式 | 手机直接建立物理socket到 | 后续解析发生在哪里 | 首版 |
|---|---|---|---|
| Direct | 目标 | 系统resolver | 是 |
| Existing SOCKS5 | 代理端点 | 目标名由SOCKS处理 | 是 |
| ProxyJump | 第一跳 | 后续目标由上一跳direct-tcpip处理 | 是，顺序最大3跳的产品初始上限 |
| SOCKS入口 + ProxyJump | 代理端点 | 首跳名给SOCKS，后续名给上一跳 | 高级明确模式，单独验收 |
| 中途再加另一个SOCKS/循环/嵌套未展开hostChain | 不执行 | 不猜测 | 明确拒绝 |

第一跳自己的隐含route不能递归应用；route快照是唯一真相，HostRef只取端点与身份。若旧数据含多处矛盾代理，在编辑器一次性选择，不能连接时忽略target配置。

## ProxyJump实现合同

复用dartssh2的`forwardLocal`作为下一层SSHSocket，逐跳建立SSH client；不是登录shell执行`ssh`，不需要把最终私钥拷贝到跳板，不默认开启agent forwarding。必须先验证每跳host key，再向该跳认证；最终目标同样验证。[S30](13-sources.md#s30)

跳板缺失、协议非SSH、循环、链过长、转发被拒绝都在可定位的阶段失败；不得尝试最终主机直连。失败与取消关闭半成品；日志标第几跳，不把代理认证与SSH密码混为一谈。

## SOCKS5合同

CONNECT-only；不宣称BIND/UDP/Mosh可用。支持无认证或UsernamePassword；要求密码时只能协商该方法，空secret与无认证是不同状态。地址按IPv4/IPv6/域名正确编码；域名IDNA策略在一个地方定义，控制字符/NUL/过长字段拒绝。只允许系统解析**代理端点**，不提前解析目标名。[S28](13-sources.md#s28) [S29](13-sources.md#s29)

保留现有cursor处理余留字节的正确思路，但加严格VER/RSV/ATYP/认证子版本/长度验证、总协商deadline、慢速半包取消、缓冲上限。SOCKS成功响应与SSH banner粘在同一packet时，banner必须完整交给SSH。[S04](13-sources.md#s04)

建议预算（待测设计值）：入口TCP 10s，SOCKS 10s，每跳SSH网络握手15s；人工host trust和外部check另有可取消等待，不复用短网络超时。整体尝试有上限，不能每字节重置计时无限等待。

## 远程代理安全

满足本次用户需求，允许远程host/port，不局限127.0.0.1。但普通SOCKS5用户名密码协商不加密；SSH保护目标SSH会话，不保护此前的SOCKS口令。非回环端点必须说明其实际保护路径（用户VPN/受信网/外部TLS封装），不自动声称安全。[S29](13-sources.md#s29)

本版不把socks5://伪装为SOCKS-over-TLS，不无证据保证当前VPN覆盖代理。首用远程端点给予一次明确风险确认，禁止打印含凭据URI。代理profile引用secretRef；本地代理也建议认证，因为回环地址不是进程身份。

## 不绕过当前VPN

Direct只意味着不使用App级代理，继续遵守OS网络策略。禁止`VpnService.protect`、绑定非VPN网络、静默更换VPN或自动打开官方Tailscale App来夺VPN。连接前检测以端口/协议测试为主，不试图识别所有品牌VPN。Google VPN阻断本地跨App连接时显示兼容性限制，不绕过它。

## 分阶段诊断

只检测指定目的地，不扫描整个Tailnet。不将SOCKS的host unreachable一律说成DNS失败。测试连接可停在SSH服务探测；涉及host trust和登录时明确显示目标，并且不运行startupCommand或创建tmux。

## V3：插件不能继承不存在的路由能力

每个会话声明byte-stream/UDP/provider-managed之一。仅SSH相关的字节流消费者能复用本文件RoutePlan。Mosh首版只接受显式Direct，含SOCKS或ProxyJump的选择在启动远端mosh-server前拒绝，绝不偷偷让UDP直连。外部UU/RustDesk使用自己的网络与账号，UI明确不继承SSH代理。若用户要求整次远控也必须经某SOCKS，当前外部适配器返回UNSUPPORTED，不用“已拉起”掩盖旁路。

Direct仅指应用不再添加代理，仍走系统默认网络/VPN。协议选择和路由选择是两维；不存在用户无感的自动协议切换。
