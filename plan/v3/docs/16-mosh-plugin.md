# 16 Mosh 独立运行时插件

## 首版范围

Mosh是独立Android APK提供的TerminalSessionProvider。宿主继续使用flterm显示终端；插件运行Mosh客户端并产出VT字节。不是把UDP包直接交给libghostty，也不是在宿主里再装一套终端UI。

Mosh使用SSH引导后切到独立UDP通道；因此“SSH经TailSocks成功”不证明Mosh可达。[S57](13-sources.md#s57)

| 选择路由 | 本版行为 |
|---|---|
| Direct（服从系统现有VPN） | 有UDP目标可达条件时验收支持 |
| SOCKS5 CONNECT，包括TailSocks | 启动前拒绝为UNSUPPORTED_UDP_ROUTE，不直连UDP |
| ProxyJump | 启动前拒绝；TCP direct-tcpip不承载Mosh UDP |
| SOCKS + ProxyJump | 同样拒绝 |
| 后续UDP代理/专用datagram provider | R34独立设计；只有真实端到端UDP证据才声明支持 |

这意味着用户当前“Google VPN + TailSocks”路径的默认仍为SSH + tmux，不因装Mosh插件而切成Mosh。协议不支持是兼容结论，不是连接失败后可偷偷换路由的理由。

## 运行流程

1. 用户选择Mosh和明确Direct路线。先检查插件安装、签名、API、ABI和目标route capability；不满足时不启动远端进程。
2. 宿主通过既有SSH适配器核验host key并认证，探测远端mosh-server是否存在。不存在时给说明，不自动安装或使用sudo。所有者 2026-10-17 同意：说明里可以带【安装…】，用户在确认框里点了以后，新开一次性 SSH 标签执行写死的安装命令一次，sudo 密码由用户在终端里输入、不经 App（R42；卸载与清理见 docs/user/mosh.md）。
3. 宿主执行受控bootstrap，限制命令参数、输出和超时，解析端口与临时会话key。启动服务是用户选择Mosh带来的已说明副作用，不能作为后台健康检查反复执行。
4. 将临时key、确定的目标地址/UDP端口、初始行列和本次授权handle通过经过认证的IPC交给插件。材料不落盘，不放URL、通知、诊断或命令行可见参数。
5. 插件worker通过选定客户端处理UDP协议及已验证的输出能力；宿主读VT流、写输入、发送resize。确认适配器不会同时再编码一遍输入。
6. 用户关闭、插件崩溃、宿主死亡分别走清理路径。不得自动重启mosh-server冒充恢复同会话；保留用户重新连接入口并提示可能存在远端旧进程。

## 运行时选择：先复用，不预设必须native

Conduit当前使用的`dart_mosh`是Dart Mosh UDP组件，不含SSH连接和终端UI，包声明Apache-2.0。它值得优先做小规模互操作实验；但独立APK要额外打包自身AOT/FlutterEngine并接Kotlin Service/FD桥，不能把宿主内引入pub依赖当作可安装插件已经完成。[S59](13-sources.md#s59) [S60](13-sources.md#s60)

X08对比两条路径：Dart复用与官方native客户端封装。前者检查协议完整性、坏包/重传/重放边界、nonce/key处理、输出重绘与后台engine资源；后者检查JNI/PTY、信号、exit、构建和许可。两者都必须与实际mosh-server互操作。Conduit的使用是参考，不是本产品安全证明。通过同一功能/移动/安全门禁后只选择一套生产运行时；只因更易编译或许可较宽松而跳过协议验证不可接受。

### 选择native时额外需要证明

从合法来源构建Mosh运行时，随插件APK打包。优先评估JNI/library wrapper或系统允许的已打包native执行方式；Mosh不是现成Android SDK，main/exit、PTY、信号、线程和多会话隔离要以实际代码验证。不能未经试验宣称将main放在线程就安全。

不照搬LobiShell二进制交付方案到宿主可写目录执行；Android对可写目录exec有限制。[S54](13-sources.md#s54) 保留许可证、源码/patch与可重建说明，native ABI、16KiB、release打包与生命周期都纳入验收。

首个APK至少完成一个Mosh会话；多会话未通过就限制并发并显示限制，不伪造多个可用标签。远端历史/本地预测与普通SSH不同，需测试滚动及输入回显，不能承诺完整SSH scrollback等价。

## 安全与故障

临时Mosh key同样是秘密。malformed bootstrap、端口超界、注入字符、SSH取消和超时必须失败关闭；解析代码不信任远端提供的本地执行路径。Mosh插件不暴露对所有应用开放的本地TCP代理或终端端口。

网络变化后可让存活的Mosh会话自行恢复，不主动因网络通知重建bootstrap。若运行时实例确已退出，显示原会话丢失，不自动重放任何键盘输入。插件本身已经接收过的输入可能处于协议传输中，不能承诺网络意义上的exactly-once；保证的是宿主不额外重放。
