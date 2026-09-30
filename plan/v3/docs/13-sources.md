# 13 来源与核查边界

核查日期：2026-09-29。分支网页会变化，本轮未取得完整可重建checkout，未构建App或运行插件。下面是实际阅读的原始资料。实施者须先冻结SHA、锁文件、native制品及协议版本。文档中的接口、任务、限制和测试是本产品设计。

<a id="s01"></a>
## S01 Netcatty README

https://raw.githubusercontent.com/kmh1145/Netcatty-mobile/main/README.md

功能与技术路线声明；不代替实际构建和回归。

<a id="s02"></a>
## S02 Netcatty LICENSE

https://raw.githubusercontent.com/kmh1145/Netcatty-mobile/main/LICENSE

GPL-3.0-or-later；正式分发需符合原许可。

<a id="s03"></a>
## S03 Netcatty pubspec

https://raw.githubusercontent.com/kmh1145/Netcatty-mobile/main/pubspec.yaml

观察版本1.4.7+26，dartssh2约束^2.22.3，xterm2为5.2.0；不是HEAD或完整锁文件。

<a id="s04"></a>
## S04 Netcatty SSH service

https://raw.githubusercontent.com/kmh1145/Netcatty-mobile/main/lib/infrastructure/ssh/ssh_service.dart

静态读取跳板、代理、字节解码、startup、取消及socket适配。仅为待复验线索。

<a id="s05"></a>
## S05 Netcatty session controller

https://raw.githubusercontent.com/kmh1145/Netcatty-mobile/main/lib/application/session_controller.dart

重连调用connect并传回原host；会话与引擎耦合。

<a id="s06"></a>
## S06 Netcatty host model

https://raw.githubusercontent.com/kmh1145/Netcatty-mobile/main/lib/domain/models/host.dart

hostChain、proxyProfileId、proxyConfig与原始Map模型。

<a id="s07"></a>
## S07 Netcatty architecture

https://raw.githubusercontent.com/kmh1145/Netcatty-mobile/main/docs/ARCHITECTURE.md

现有分层、会话及借用SSH能力的边界。

<a id="s08"></a>
## S08 Netcatty project structure

https://raw.githubusercontent.com/kmh1145/Netcatty-mobile/main/docs/PROJECT_STRUCTURE.md

本文代码落点的来源，不保证后续HEAD不变化。

<a id="s09"></a>
## S09 Netcatty security

https://raw.githubusercontent.com/kmh1145/Netcatty-mobile/main/docs/SECURITY.md

上游安全说明；仍需独立检查持久化、导出和同步。

<a id="s10"></a>
## S10 Conduit README

https://raw.githubusercontent.com/gwitko/Conduit/master/README.md

应用自身Apache-2.0；conduit_vt、tmux、FIDO及可选本地shell；第三方另有许可。

<a id="s11"></a>
## S11 Conduit SSH factory

https://raw.githubusercontent.com/gwitko/Conduit/master/lib/features/terminal/data/ssh_client_factory.dart

当前读取路径直接TcpSshSocket.connect；硬件键与host trust可复用。

<a id="s12"></a>
## S12 Conduit pubspec

https://raw.githubusercontent.com/gwitko/Conduit/master/pubspec.yaml

观察1.4.14+39；SSH与终端使用git fork；并非纯上游依赖。

<a id="s13"></a>
## S13 Conduit repositories

https://raw.githubusercontent.com/gwitko/Conduit/master/lib/features/terminal/data/routing_terminal_repository.dart

此routing用于SSH/Mosh/local选择，不应误称ProxyJump路由。

<a id="s14"></a>
## S14 NiceSSH README

https://raw.githubusercontent.com/imtaqin/NiceSSH/main/README.md

MIT；host-key验证与jump等仍列planned。README声明，不推断全树实现。

<a id="s15"></a>
## S15 Claude Carry README

https://raw.githubusercontent.com/Samuele95/claude-carry/master/README.md

MIT声明；Claude专用工作流、附件与工具栏；本方案不继承自动启动和跳过权限默认。

<a id="s16"></a>
## S16 elias8 libghostty repository

https://github.com/elias8/libghostty

Dart绑定与Flutter flterm组件；不能据此声称实机已通过或等于桌面Ghostty渲染器。

<a id="s17"></a>
## S17 flterm pubspec

https://raw.githubusercontent.com/elias8/libghostty/main/packages/flterm/pubspec.yaml

观察0.0.5，Dart ^3.12.0，Flutter >=3.44.0，依赖libghostty ^0.0.12。

<a id="s18"></a>
## S18 libghostty pubspec

https://raw.githubusercontent.com/elias8/libghostty/main/packages/libghostty/pubspec.yaml

观察0.0.12与native hooks；平台声明不是实机验收。

<a id="s19"></a>
## S19 flterm controller

https://raw.githubusercontent.com/elias8/libghostty/main/packages/flterm/lib/src/controller/terminal_controller.dart

write(Uint8List)、onOutput、onResize、单view所有权、非重入与dispose契约。

<a id="s20"></a>
## S20 libghostty native provider

https://raw.githubusercontent.com/elias8/libghostty/main/packages/libghostty/lib/src/hook/library_provider.dart

预编译下载含hash验证；另有源码编译路径。不可关闭完整性检查。

<a id="s21"></a>
## S21 libghostty binary hashes

https://raw.githubusercontent.com/elias8/libghostty/main/packages/libghostty/lib/src/hook/asset_hashes.dart

观察releaseTag libghostty-v0.0.12，包含Android arm64/arm/x86_64清单。未下载执行二进制。

<a id="s22"></a>
## S22 Ghostty upstream pin

https://raw.githubusercontent.com/elias8/libghostty/main/packages/libghostty/ghostty.version

读取到349f026087d948f8f898dca3231ff91438f83ab8，这是Ghostty源码pin，不是elias8仓库HEAD。

<a id="s23"></a>
## S23 Tailscale trust credentials

https://tailscale.com/docs/reference/trust-credentials

最小设备读取scope是devices:core:read；devices:read属于legacy。

<a id="s24"></a>
## S24 Tailscale OAuth clients

https://tailscale.com/docs/features/oauth-clients

用户自有client凭据换取有范围短期token；不是已存在的第三方手机SSO授权流程。

<a id="s25"></a>
## S25 Tailscale API

https://tailscale.com/docs/reference/tailscale-api

普通控制台API token可能全权限；需角色授权，不能称天然只读。

<a id="s26"></a>
## S26 Tailscale SSH

https://tailscale.com/docs/features/tailscale-ssh

Tailnet网络身份、SSH权限与检查流程；普通OpenSSH不是同一认证模型。

<a id="s27"></a>
## S27 TermRover integration

https://termrover.sh/blog/termrover-tailscale-ssh-from-your-phone/

设备导入与SSH入口行为参考；其API key只读表述不作为权限依据。

<a id="s28"></a>
## S28 SOCKS5 RFC1928

https://www.rfc-editor.org/info/rfc1928/

CONNECT、地址、方法与错误码；没有单CONNECT多目标多路复用。

<a id="s29"></a>
## S29 SOCKS auth RFC1929

https://www.rfc-editor.org/info/rfc1929/

用户名密码子协商不自带加密。

<a id="s30"></a>
## S30 dartssh2 upstream

https://github.com/vicajilau/dartssh2

forwardLocal可作为内层SSH socket；历史TerminalStudio URL重定向。示例不替代锁定版本。

<a id="s31"></a>
## S31 dartssh2 client source

https://raw.githubusercontent.com/vicajilau/dartssh2/master/lib/src/ssh_client.dart

观察none尝试与onUserauthBanner等；不能假定pubspec所选2.22.x具备master所有新增API。

<a id="s32"></a>
## S32 Android 16KB pages

https://developer.android.com/guide/practices/page-sizes

实际APK/native ELF/设备兼容性验收；包含传递native依赖。

<a id="s33"></a>
## S33 Android foreground types

https://developer.android.com/develop/background-work/services/fgs/service-types

真实用途、类型与权限；不保证无限后台存活。

<a id="s34"></a>
## S34 GNU GPLv3

https://www.gnu.org/licenses/gpl.html

修改和分发义务依据；本文件不是对所有分发渠道的法律审查。

<a id="s35"></a>
## S35 TailSocks repository

https://github.com/bropines/tailsocks

外部用户态SOCKS5及可选TUN；本App只消费明确配置的SOCKS端点。

<a id="s36"></a>
## S36 LobiShell Mosh plugin README

https://github.com/secco04/saftssh-mosh-plugin

独立APK；README称bound service，但本轮Manifest/Provider显示二进制ContentProvider。以实际源码为准，不假设全插件共用统一SDK。

<a id="s37"></a>
## S37 LobiShell Mosh manifest

https://raw.githubusercontent.com/secco04/saftssh-mosh-plugin/main/app/src/main/AndroidManifest.xml

观察MoshBinaryProvider及normal级READ_BINARY权限；本轮manifest未声明Mosh bound service。

<a id="s38"></a>
## S38 LobiShell MoshBinaryProvider

https://raw.githubusercontent.com/secco04/saftssh-mosh-plugin/main/app/src/main/java/de/lobianco/saftssh/mosh/MoshBinaryProvider.kt

二进制交付接口的代码参考，不是本方案会话IPC实现，也不说明复制执行适合本产品。

<a id="s39"></a>
## S39 LobiShell RustDesk plugin README

https://github.com/secco04/rustdesk-plugin

独立APK，AIDL bound service，内含RustDesk客户端核心并声明AGPL-3.0；不隶属官方RustDesk。

<a id="s40"></a>
## S40 LobiShell RustDesk manifest

https://raw.githubusercontent.com/secco04/rustdesk-plugin/master/app/src/main/AndroidManifest.xml

导出会话Service、specialUse声明、作用域文件共享。商店合规需本产品独立复核。

<a id="s41"></a>
## S41 LobiShell RustDesk session service

https://raw.githubusercontent.com/secco04/rustdesk-plugin/master/app/src/main/java/de/lobianco/saftssh/rustdesk/RustDeskSessionService.kt

观察AIDL方法内UID映射包名检查及Surface参数；本方案加强为签名和授权记录校验，不声称上游存在已利用漏洞。

<a id="s42"></a>
## S42 UU远程官方接入协议 当前raw

https://raw.githubusercontent.com/netease-uuyc/uuremote-integration-guide/main/README.md

观察最低4.42.0；Windows/macOS目标；绑定nonce与opaque ID；全屏无回调，小窗可选callback。与搜索缓存旧版的全屏回调说法冲突，以本次raw为设计基准并要求实施前冻结版本。

X06（2026-09-30）已冻结到提交 `be7d8109`，README sha256 `72f9017b…7bac45`；口径与原件位置见 docs/17「X06 固定的官方口径」。

<a id="s43"></a>
## S43 UU远程官方接入仓库

https://github.com/netease-uuyc/uuremote-integration-guide

来源为netease-uuyc维护的接入说明。不是嵌入式画面SDK，也不是整个UU客户端源代码。

<a id="s44"></a>
## S44 RustDesk Android manifest

https://raw.githubusercontent.com/rustdesk/rustdesk/master/flutter/android/app/src/main/AndroidManifest.xml

观察rustdesk scheme及com.carriez.flutter_hbb标识；正式包/签名按实际发行渠道验证。

<a id="s45"></a>
## S45 RustDesk deep-link implementation

https://raw.githubusercontent.com/rustdesk/rustdesk/master/flutter/lib/common.dart

urlLinkToCmdArgs处理连接URI；移动端config/password敏感动作有额外开关。外部连接不默认传password或配置修改。

<a id="s46"></a>
## S46 OpenPGP API remote service

https://github.com/open-keychain/openpgp-api

AIDL + ParcelFileDescriptor、结果与需用户交互状态是可借鉴接口模式；并非本项目要集成PGP或复制整库。

<a id="s47"></a>
## S47 Termux API add-on

https://github.com/termux/termux-api

独立add-on及同签名授权先例；本产品独立签名插件不能照用same-signature条件后声称第三方即插即用。

<a id="s48"></a>
## S48 Flutter deferred components

https://docs.flutter.dev/perf/deferred-components

Android deferred components仍随整个AAB共同构建上传，不是任意第三方Dart包运行期插件机制。

<a id="s49"></a>
## S49 Android dynamic code loading

https://developer.android.com/privacy-and-security/risks/dynamic-code-loading

动态载入的风险；不能把签名/hash当作消除同进程代码权限或商店分发规则。

<a id="s50"></a>
## S50 Google Play device/network abuse

https://support.google.com/googleplay/android-developer/answer/16559646?hl=en

Play分发的远程可执行代码下载约束与前台服务要求；发布时需复核，不保证独立APK方案自动获批。

<a id="s51"></a>
## S51 Android AIDL

https://developer.android.com/develop/background-work/services/aidl

多应用IPC、线程/方法兼容、DeadObjectException；本方案的typed契约为新设计。

<a id="s52"></a>
## S52 Android bound services

https://developer.android.com/develop/background-work/services/bound-services

显式绑定、服务生命周期与Binder基础。

<a id="s53"></a>
## S53 Android ParcelFileDescriptor

https://developer.android.com/reference/android/os/ParcelFileDescriptor

FD跨进程传递及pipe/socketpair能力；具体所有权与限流需测试。

<a id="s54"></a>
## S54 Android API29 execution changes

https://developer.android.com/about/versions/10/behavior-changes-10

应用可写目录exec限制；native runtime应随APK合法打包，不靠复制下载二进制到files目录执行。

<a id="s55"></a>
## S55 Android service caller security

https://developer.android.com/agents/skills/security/android-intent-security/SKILL

官方安全指导：实际Binder事务校验、显式组件、签名与Intent不可信；不将网页skill当本任务工具指令。

<a id="s56"></a>
## S56 GNU licensing FAQ

https://www.gnu.org/licenses/gpl-faq.html

插件/通信方式的组合判断不能仅凭进程分离决定；许可和正式分发需个案审核。

<a id="s57"></a>
## S57 Mosh official

https://mosh.org/

SSH引导与独立UDP传输；Mosh并非SOCKS CONNECT中继续传输的SSH字节流。

<a id="s58"></a>
## S58 Android custom links

https://developer.android.com/training/app-links/create-deeplinks

自定义scheme可能冲突；nonce只能关联请求，不提供强发送者认证。

<a id="s59"></a>
## S59 dart_mosh README

https://raw.githubusercontent.com/gwitko/dart_mosh/master/README.md

Conduit使用的Dart Mosh UDP组件，不含SSH或终端UI；已有packet、ack、resize和rehoming声明。作为X08候选，不由README推导完整协议/安全兼容。

<a id="s60"></a>
## S60 dart_mosh LICENSE

https://raw.githubusercontent.com/gwitko/dart_mosh/master/LICENSE

包声明Apache-2.0；其来源、加密依赖及组合许可仍在X08审查，不把重实现自述视为独立审计。

<a id="s61"></a>
## S61 Tailscale API OpenAPI spec (pinned by sha256)

https://api.tailscale.com/api/v2?outputOpenapiSchema=true

R11 固定的官方口径：openapi 3.1.0、info.version v2、官方声明 unstable 且无日期，只能按内容固定 sha256 b416d98eaf58a5e2b974a8c9424f1f33849866eb45344ecba59e95d6140a742d（246351 字节，ETag 同值）。原件在仓库外 .toolchain/artifacts。列设备不分页；sshEnabled 只在 fields=all；无 401/Retry-After/重定向说明。

<a id="s62"></a>
## S62 Tailscale key prefixes

https://tailscale.com/docs/reference/key-prefixes

tskey-api 是 API access token，tskey-client 是 OAuth client secret；OAuth 换来的 token 前缀无明确说明。前缀只用于展示，不据此判断权限。

<a id="s63"></a>
## S63 tailscale/tailscale issue #16911

https://github.com/tailscale/tailscale/issues/16911

官方仓库未关闭 issue：OAuth client 换来的 token 列设备看不到共享进来的外部设备，普通 API token 能看到。是缺陷报告，不是文档承诺。
