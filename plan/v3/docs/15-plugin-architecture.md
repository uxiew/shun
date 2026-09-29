# 15 插件架构与强制契约

本文件为本产品新设计；不是已有可直接调用的SDK。首版实现真实provider闭环，不建设通用应用商店。

## 1. 两个维度：能力与部署

| 能力 | 拥有 | 不拥有 |
|---|---|---|
| DeviceCatalogProvider | 设备发现、刷新、来源身份 | SSH密码、路由、host-key自动信任 |
| TerminalSessionProvider | 终端会话的输入/输出/resize/关闭 | UI全部状态、整个Vault、其他会话 |
| RemoteDesktopProvider | 内嵌画面或外部远控启动 | SSH terminal流、SSH路由假继承 |
| RouteProvider（仅内置） | Direct/SOCKS/ProxyJump计划与拨号 | 第三方任意exec、远控App网络接管 |

| 部署类型 | 本版对象 | 可否独立更新 |
|---|---|---|
| bundled | SSH、Tailscale目录、Direct/SOCKS/ProxyJump、UU/RustDesk调用适配器 | 跟随主App |
| android-service | 真正安装的Mosh runtime APK；以后RustDesk embedded | 独立APK，必须通过签名与API兼容验证 |
| external-app | UU或RustDesk原客户端，bundled adapter发起调用 | 由外部应用负责；主App只声明已测协议/版本 |

不能把“安装了一个pub package”写成已实现可安装的第三方插件。也不为每个微小provider单独创建APK。

## 2. 结构

```text
Flutter 主App（Netcatty fork）
  设备 / 主机 / 会话 / 身份 / 插件管理
              │
       PluginRegistry + CapabilityPolicy
       ├─ bundled SSH ─ RoutePlan ─ dartssh2
       ├─ bundled Tailscale catalog ─ 受限HTTP
       ├─ UU / RustDesk external adapters ─ 显式Intent
       └─ AndroidProviderBridge（Kotlin，平台边界）
                    │ AIDL控制 + FD字节流
              独立Mosh插件APK/UID
                    │ 自带native运行时
                 UDP目标

TerminalSession → 原始VT字节 → flterm → libghostty
RemoteDesktopSession → 以后独立Surface接口，绝不走Ghostty
ExternalLaunchAttempt → 外部应用状态，不伪装成可观测SSH连接
```

新增Dart目录按现有分层组织：`domain/plugins`、`application/plugin_registry`、`infrastructure/plugins`、`presentation/plugins`；公共类型只抽出实际需双方共享的`packages/plugin_api`。Android端单个bridge插件/模块加薄AIDL契约；`plugins/mosh`是独立安装单元，不同applicationId、不同UID，不设置sharedUserId。

## 3. 最小描述符

记录pluginId、displayName、version、apiMajor/apiMinor、deployment、capabilities、supportedRoutes、minHostVersion、platforms、permissionDeclarations、license、sourceUrl。独立服务另有packageName/serviceClass/signingDigest；证书由系统读取并与信任记录比较，不能相信插件自报的digest。

pluginId是逻辑ID，不等于Android包名，也不天然获得官方权限。官方保留的ID与证书建立映射；同名第三方不得遮蔽内置SSH或另一个已信任provider。示例仅用`example.*`，产品正式命名由所有者决定。

配置JSON必须有版本，限定字段、大小、字符串长度和允许schema；拒绝任意脚本、Intent对象、shell模板或URL作为“插件能力”。示例在contracts/，均是契约草案，不是生成完成的SDK。

## 4. 安装发现与双向信任

只查询本产品action或明确包的`<queries>`，不申请QUERY_ALL_PACKAGES。候选元数据可展示，但不能在未授权前开始会话。主App读取安装包证书，用户批准`pluginId + package + signingDigest + capability`后显式绑定service组件。

每个外部AIDL事务在Stub方法内获取Binder调用UID，核对实际caller包与签名，再校验owner UID、session ID和generation。不能只在onBind检查，不能相信Intent的calling_package字符串。插件同样信任明确的宿主发行签名，不要求第三方作者共享私钥。独立签名插件走运行期证书授权；同签名产品可另加signature permission，但不能因此宣称不同签名插件无需适配。[S51](13-sources.md#s51) [S52](13-sources.md#s52) [S55](13-sources.md#s55)

初始支持：经过用户确认的独立签名provider。首次安装需主动启用；未知证书、换签、API major不符、provider身份冲突保持禁用。密钥轮换以系统可验证签名历史与产品允许清单审查，不能自动接受任意“新证书”字段。debug信任仅在明确开发构建中启用，不允许release接受所有debug包。

## 5. 控制面与数据面

AIDL使用小型类型化消息：descriptor、open、resize、close、state/error回调。避免通用`execute(method, arbitraryJson)`，更不能提供任意读取文件或SSH exec。

Mosh数据流通过`ParcelFileDescriptor`的pipe/socketpair通道；明确每端读写所有者、dup/close和EOF语义。不要逐字节Binder RPC，也不要把终端流编码成大型Base64消息。Kotlin桥可按有界chunk交给Dart，保序、背压、上限与取消必须实测；控制事件和输入流不能重复发送。[S53](13-sources.md#s53)

每次打开返回不透明SessionHandle。长操作不阻塞Binder线程；状态回调单调携带generation/sequence。输出缓冲预算与现有终端一致，溢出停止本地会话并显示原因，不能任意丢VT字节维持假画面。

## 6. 凭据授权

SSH由宿主完成主机核验与用户认证。Mosh插件只取得当次mosh bootstrap产生的临时材料，不取得SSH私钥、代理密码、Tailscale token或其他主机记录。bootstrap是宿主白名单操作，不是任意command字符串。

当前SDK不提供插件读取Vault、遍历主机、写known_hosts或读取剪贴板的API。provider确实需要新的敏感能力时，要新增明确授权与测试，不能扩大一个笼统storage/network权限。

插件会看到本会话数据，不能宣传零信任。独立APK具有自身Android权限，主App不能阻止已获INTERNET的恶意插件自行外连；supportedRoutes是兼容契约和受信实现要求，不是操作系统级防火墙。必须在授权页说明边界。

## 7. 会话与撤销

```text
Discovered → Incompatible / Untrusted / Disabled → Ready
Ready → Opening → Active → Closing → Closed
                     └→ Interrupted / ProviderDied / PermissionRevoked
```

停用插件阻止新操作并请求关闭其会话，不影响SSH/SFTP或其他provider。binder death、APK卸载/更新、签名变化让相关会话中断；旧回调不复活连接。只清除本App归属资料，不主动卸载外部App。关闭接口幂等。

宿主死亡时插件监测death recipient并按默认策略关闭本地native会话；不承诺远端进程绝不存活。对无响应提供方，宿主关闭自有FD、撤销授权并显示停止未确认；不能声称它已删除外部App里复制的秘密或已结束远端远控。

## 8. UI自由与兼容限度

首版允许provider声明受限配置schema，宿主渲染常用字段；复杂设置可显式打开插件自己的Activity。宿主不强制接管所有插件设置页。禁止下载Dart Widget、任意JS UI或加载未验证网页到带特权bridge的容器。

APK插件机制限Android；原有iOS仍保持可构建、必要时显示未支持。不能把Android AIDL写成Flutter跨平台能力已经全部实现。扩展SDK先冻结major=1；minor只追加可协商能力，调用前核对，发布后不重排既有事务语义。

## 9. v1 冻结记录（X00，2026-09-29）

以下已落成 `packages/plugin_api`（纯 Dart 类型与判定逻辑，27 条契约测试）和 `contracts/`（schema + 9 个负例）。这是判定口径，不是 IPC 实现：逐事务的 UID + 证书核对在 X02 落成 `plugins/provider-sdk` 的 `CallerVerifier`，session 级 owner/generation 在 X03。（契约测试数随后增加，当前数目以 `dart test` 为准。）

**版本**：宿主 API 1.0。插件 major 不等于 1 直接拒绝。插件 minor 比宿主新时，宿主不认识的能力名记为"忽略、不可调用"，整体不拒绝；同 minor 出现未知能力则拒绝。**未知权限一律拒绝**——宿主给不了的权限，插件不会按预期工作。静态 schema 只描述 1.0，所以"新 minor 的未知能力"这一条是 Dart 运行期校验器与 schema 的唯一有意差异。

**schema 本次补的两条**（原草案漏了，与 §1、docs/04 冲突）：`route` 能力只允许 `bundled`；`external-app` 的 `supportedRoutes` 只能是 `["provider-managed"]`。

**描述符硬限制**：≤16 KiB；字段集合封闭（多一个字段就拒绝，exec/intent/url 回调只能从这里混进来）；权限集合封闭，没有 Vault、私钥、口令、token、exec、文件、剪贴板。

**准入**：内置 ID 与 `builtin.` 前缀只属于宿主；单独安装的包自称 `bundled` 一律拒绝（X01 补：bundled 分支不走批准，原先可借此跳过授权）；所有者登记的官方 ID 绑定固定证书；已占用的 ID 或包名不能被第二个 provider 抢占；描述符自称的包名必须等于实际安装包；批准绑定 `pluginId + 包名 + 证书 + 能力` 四项，换签即禁用、能力扩大即重新批准；debug 证书只在开发构建可用。证书只认系统读出的值，描述符里没有签名字段。

**会话分型**：`TerminalSessionRef` / `RemoteDesktopSessionRef` / `ExternalLaunchAttempt` 三个类型互不兼容。外部拉起的状态里**没有"已连接"**，只有 `launchedUnverified` 和提供方明确回报的成功/失败。状态事件带 generation + sequence，旧代次或不递增的事件直接丢弃。

**路由判定**：UDP（Mosh）只允许 system-default，SOCKS/跳板在 bootstrap 前返回 UNSUPPORTED；provider-managed（外部 App）只允许 system-default，用户要求整次远控走代理时返回 UNSUPPORTED；字节流按声明判定。

**设备关联**：只有 `linkByUser` 一个入口；同名同 IP 不合并；同一 provider 的两条引用不能关联；解除关联不动各自引用。

### 已知协议局限（记录，未实测）

- **Mosh**：SSH 引导后切 UDP，SOCKS5 CONNECT 与 ProxyJump 的 direct-tcpip 都只转 TCP，承载不了；SSH 经 TailSocks 成功不代表 Mosh 可达。参考插件 saftssh-mosh-plugin 的 README 与 manifest 不一致（仅静态观察）。
- **UU 远程**：raw 协议基准为客户端 ≥4.42.0，被控端只有 Windows/macOS，不能声称支持 Linux/Android/TV 目标。全屏模式不回调，只有小窗且带有效 callback 才可能回调；nonce 只做一次性关联，**不等于签名认证**。匿名设备 ID 按敏感引用保护。
- **RustDesk**：首版只外部拉起，不传密码 URI，不开放任意 URI 透传；核心与参考插件涉及 AGPL，拆成独立 APK 不自动豁免许可义务。

### 真正未测

上面是 X00 时的纯逻辑测试。X02（2026-09-30）已在 arm64 模拟器 API 35 上实测：插件 APK 的安装发现、系统读出的证书、批准前不绑定、Binder 逐事务按 UID + 证书拒绝（插件侧与宿主回调侧）、同包名换签、调试证书进 release 宿主，见 evidence/X02.md。

仍没跑过：session 级 owner/generation 校验与 FD 数据面（X03）、provider 死亡/更新/卸载时的会话处理（X03/X04）、UU/RustDesk 真实客户端（X06/X07）、Mosh 运行时（X08–X10）、Android 7–10 上的发现与证书读取路径、任何真机。
