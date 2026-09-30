# 17 UU / RustDesk远控provider

## 1. 产品边界

首版是手机作为控制端，设备卡片提供远控入口；不让手机成为被控端。SSH与远控是并列能力。远控入口不进入Ghostty，不索要SSH凭据，不修改现有VPN。外部App管理账号、媒体与连接，宿主不能承诺接管其SOCKS路线或关闭其远端会话。

## 2. UU：官方跨App协议

本轮raw文档基准为客户端>=4.42.0，调用端Android/iOS、被控目标Windows/macOS；不支持把Linux、Android或TV设备作为本协议目标。正式包名观察为`com.netease.uuremote`。这是绑定/启动协议，不是可嵌入Flutter的远控SDK。[S42](13-sources.md#s42) [S43](13-sources.md#s43)

设计入口：设备卡片 → 添加UU绑定 → 显式启动官方设备授权页 → 校验回调 → 用户确认关联。保存`UuBindingRef`及加密opaque标识，不能尝试解密其内部格式或用IP推算ID。失败/账号变化只将该绑定标为失效，不删SSH或Tailscale记录。

协议形态（字段使用前再次比对冻结的官方版本）：

```text
uuremote://external/device/authorize?callback=<encoded>&nonce=<random>
uuremote://external/device/control?anonymous_device_id=<encoded>&window_type=0|1[&callback=<encoded>]
```

当前raw：全屏不回调；小窗有传有效callback才回调。绑定成功返回匿名ID/nonce，控制小窗返回status/reason。不要套用搜索缓存中旧版全屏回调规则。[S42](13-sources.md#s42)

### 本产品的安全实现

用URI builder编码参数，不手拼可信scheme后追加任意外部URL。按官方scheme检测能力，再限制Intent到已验证包/签名；不能把未验证的resolveActivity结果当官方客户端。平台签名摘要来自可信发行制品，不在计划里猜值。

callback为本产品固定接收点，`nonce`或callback中保留的`state`使用随机、一次性、有限期值，绑定pending request + device record + action + expected provider。校验参数数目、长度、重复字段、成功与失败互斥；未知结果按保守状态显示。onCreate与onNewIntent走同一验证器。

自定义scheme可能被别的App接管；state仅防无关联/重放，不能视为UU签名回调或防恶意已安装应用的完整保证。能使用自有已验证App Link时优先评估；无域名时保留风险说明，接收绑定后必须由用户确认，不能回调即自动远控。[S58](13-sources.md#s58)

匿名ID在本产品按敏感opaque引用保护，禁止日志、普通导出和剪贴板自动复制。存储按provider/account context隔离；更换账号造成失效时要求重新绑定，不索要UU密码或读取UU私有数据库。

### 状态不能虚报

全屏launch成功只显示“已交给UU远程”，没有连接成功回调不能标Active。PiP回调成功显示“UU已报告小窗就绪（时间）”，不是持续在线证明。用户回到本App、Activity启动成功或桌面出现图标都不能更新为Connected。

一次只允许一个UU请求；并发串行/明确取消，迟到回调不覆盖新请求。用户确认弹窗可能延迟回调，本地等待结束仅标“结果未确认”，不伪造远端失败、不自动重试。PiP不支持时提供用户手动改全屏，不能自动切换后标成功。

### X06 固定的官方口径（2026-09-30）

**来源**：`netease-uuyc/uuremote-integration-guide` 提交 `be7d8109ad75e4b273b988c3c01f33b7fcbd8817`（2026-09-23，「add minimum version requirement (4.42.0)」，与当日 main 相同）。README sha256 `72f9017bc8979886f1bb23dd2f8074cb98932706ad7ca95907a14ad72a7bac45`（23363 字节）；官方 Android 示例的 `MainActivity.kt` 与 `AndroidManifest.xml` 一并存档。原件在仓库外 `../.toolchain/artifacts/uuremote-integration-guide-be7d8109-*`。重新下载后 sha256 变了就是官方改了协议，要重新核对下面各条。

| 项 | 官方口径 | X06 的做法 |
|---|---|---|
| 版本 | iOS、Android 客户端都从 4.42.0 起支持 | 装的 UU 版本低于 4.42.0 就不发请求，提示更新 |
| 安装检测 | Android 11+ 要在 `<queries>` 声明 `VIEW` + `uuremote` scheme；用 `resolveActivity(uuremote://external)` 判断；包名 `com.netease.uuremote`，「不建议仅通过包名查询代替 Deeplink 可用性检测」 | 两样都查：scheme 能解析到 `com.netease.uuremote`，且系统读出的证书是已核对的那张；请求用显式包名发出，别的 App 声明同一 scheme 也拿不到请求 |
| 签名证书 | **官方未给** | 从官方 APK 读出后固定在代码里（见下面「固定的官方证书」）；手机上的证书和固定的不同时，要用户看过证书后明确批准，证书再变就重新批准 |
| 绑定请求 | `uuremote://external/device/authorize?callback=<编码>&nonce=<随机>`；callback 必填、要有 scheme 和 host；nonce 可选、建议 UUID | 每次都带 nonce（UUID v4，来自安全随机数），callback 里再带一个自己的一次性 `state` |
| 回调 URL 的原参数 | 回调时保留 callback 原有查询参数，同名结果字段以本次为准 | `state` 放在 callback 里，靠这一条带回来 |
| 绑定结果 | 成功 `anonymous_device_id` + `nonce`；失败 `error` + `nonce`，两者互斥；nonce 没传时字段仍出现、值为空 | 两者都出现、都没有、重复出现一律拒收；nonce 必须和请求时的一致 |
| 绑定错误码 | `no_device`、`user_cancel`、`timeout`、`not_logined`、`superseded`、`logout`、`internal_error` | 未知错误码按「UU 报告失败」显示原文，不猜含义 |
| 等待时长 | 未登录排队最长 180 秒；设备列表 15 秒；「无可关联设备」弹窗要用户点了才回调 | 本地等待 10 分钟后自己作废，记「结果未确认」；用户随时可以结束等待。**实测和官方口径不一致**：没登录的真实 UU 没有在 180 秒后回报（见下面「真实 UU 4.42.0 实测」），所以界面不写「最长 3 分钟」 |
| 远控请求 | `…/device/control?anonymous_device_id=<编码>&window_type=0|1[&callback=<编码>]`，window_type 默认 0 | 全屏不带 callback（官方示例也不带）；小窗带 callback + `state` |
| 全屏结果 | 无论成功、失败、取消、超时都不回调 | 只显示「已交给 UU 远程」，不等回调、不标已连接 |
| 小窗结果 | 带 callback 时最终且只回调一次：`status=success`（不带 reason）或 `status=failure&reason=…`（reason 非空） | 同时出现 success 和 reason、failure 没有 reason 都拒收 |
| reason | 12 个：`busy`、`device_offline`、`device_not_found`、`pip_unsupported`、`login_timeout`、`network_unavailable`、`not_allowed`、`connect_timeout`、`connect_failed`、`user_cancel`、`invalid_request`、`internal_error`；未知的按 `connect_failed` 处理 | `device_not_found` 只把这条 UU 绑定标失效；`pip_unsupported` 给「改用全屏」按钮，不自动切；未知 reason 按连接失败显示并带原文 |
| 前置拦截 | 忙碌、设备不存在/离线、不允许被控：先在 UU 里弹窗，**用户点确认后才回调**，这条路径没有本地超时 | 本地等待留足 10 分钟；结束等待只标「结果未确认」 |
| 并发 | UU 同一时刻只处理一个第三方请求；被取代的绑定回调 `superseded` | 本 App 同时只允许一个等回调的请求，要先结束等待才能发下一个 |
| 账号 | anonymous_device_id 绑定生成它时登录的 UU 账号，换账号后返回 `device_not_found` | 只有小窗回调能让 App 知道失效；全屏模式下 UU 在它自己的界面里报错，App 不知道 |
| 官方 Android 示例的回调 | 自定义 scheme `uuremote-integration`、host `callback`，`VIEW` + `DEFAULT` + `BROWSABLE`，`singleTask`，onCreate 和 onNewIntent 都处理 | 用 `xwshun-uuremote://callback/bind`、`…/control`。不照官方示例让主 Activity 直接接，改由过路的 `UuCallbackActivity` 接（原因见下面「系统里留下什么」） |
| 回调是谁发的 | **官方未写**任何让第三方验证回调来源的办法 | 验证不了。state/nonce 只防没发过的请求和重放；另有 App 声明同一回调地址时不走回调（见下面「回调地址被抢」） |
| **官方未写** | UU 回调时怎么编码 anonymous_device_id；会不会校验 callback 的 scheme；anonymous_device_id 的长度和字符集 | 回调只做一次百分号解码，`+` 按字面处理（加密 ID 常见 base64，把 `+` 当空格会弄坏它）；长度上限 4096 字符；这些要等真实 UU 实测复核 |

**固定的官方证书**（2026-09-30）

| 项 | 值 |
|---|---|
| 来源 | 所有者从 uuyc.163.com 下载页下载的 Android 安装包（文件上没有浏览器留下的来源记录，出处是所有者说的）。原件存在仓库外 `../.toolchain/artifacts/uuremote-official-4.42.0-c85524fa.apk` |
| 文件 | 26886667 字节，sha256 `c85524fa2c850d9e18f051eae9118754170b5899a04c3f6b6ae313b7f8ec3e39` |
| 包 | `com.netease.uuremote`，versionName 4.42.0，versionCode 442000，只有 arm64-v8a |
| 证书 | 单签名（v2 + v3）。主体 `CN=LiZiQi, OU=netease, O=netease, L=China, ST=GZ`，2022-07-13 至 2047-07-07，RSA 2048 |
| 证书 SHA-256 | `bd6a3a04791d5ca2e08fb9d7bd82265893d25aa1cb0b6a205b5a2bb154874924`（固定在 `UuRemoteProtocol.officialSigners`） |
| 证书 SHA-1 / MD5 | `4880cf855dbbdd7e128649fa3d99c0d4e5320ca9` / `62c20504b3368cc813b80313c55800eb` |
| 旁证 | APKPure 上 `com.netease.uuremote` 3.16.0（2025-07-04）页面写 `Signature 62C20504B3368CC813B80313C55800EB`，和这张证书的 MD5 相同：一年多前流通的版本是同一张证书。找不到别的公开来源；网易没有公开过这张证书 |
| 怎么重读 | `$ANDROID_HOME/build-tools/36.0.0/apksigner verify --print-certs <apk>`（`keytool -printcert -jarfile` 读不了只有 v2/v3 签名的包） |

主体里的名字是签名的人自己填的，谁都能填 netease，所以靠的是「官网下载的包」加「和旧版本同一张」这两条，不是主体名。网易换签名时这里要重新读、重新核对。

**真实 UU 4.42.0 实测**（2026-09-30，项目模拟器 API 35，没有登录 UU 账号）

| 做了什么 | 看到的 |
|---|---|
| 本 App 探测 | 版本 4.42.0，证书和上表一致，页面写「签名证书和从官方下载的一致」，不用批准 |
| 请求去了哪 | 系统把 `uuremote://external/...` 交给 `com.netease.uuremote/com.remote.deeplink.ui.DeepLinkActivity` |
| 第一次打开 UU，绑定请求 | UU 先弹《用户须知》。点「拒绝」→「确定」：UU 退出，**不回调** |
| 同意《用户须知》后，绑定请求 | UU 停在手机号登录页。从 19:12:13 等到 19:18:27（6 分 14 秒），**没有任何回调**——官方文档写的是 180 秒后回 `error=timeout`。前一次（刚点完同意的那次）等了约 5 分钟，也没有 |
| 在 UU 登录页按返回键 | 回到本 App，**不回调**（又等了 20 秒） |
| 用 adb 直接发一条小窗远控请求（编造的设备标识，带 callback） | 同样停在登录页。19:19:48 发出，看到 19:24:03（4 分 15 秒），**不回调**——官方文档写的是 180 秒后回 `reason=login_timeout` |

看不到的：模拟器经这台 Mac 的代理上网，UU 连不连得上它自己的服务器没有验证；连不上会不会影响它的超时回调，不知道。

所以没登录时本 App 只会一直等，靠用户「结束等待」或本地 10 分钟到点作废收场。登录之后 UU 怎么回、真实回调里 `anonymous_device_id` 怎么编码，都还没见过（要真实账号，BLOCKED）。

**回调地址被抢**（模拟器 API 35，用 `plugins/out/fakeuu-hijack.apk` 实测）。另一个 App 也声明 `xwshun-uuremote://callback` 时，UU 回调会让系统弹「Open with」；用户选到它，它就拿到 state、nonce 和加密设备标识，还能把标识换成自己的、用显式包名转给本 App——校验全过。所以：

- 探测时查有没有别的包声明了回调地址（清单里为此多一条 `<queries>`）。有：页面说出包名，绑定和小窗不发；全屏不带回调，照常。
- 绑定成功的回调到达时再查一次（防请求发出后才装上的），有就作废，不给用户确认。
- 挡不住的：系统把那一次回调交给谁由用户在弹窗里选，选错了标识就被它拿走。没有「只让 UU 发给我」的办法——要么 UU 改用带签名校验的通道，要么用 App Links（https 域名归属验证），这两样官方协议都没有。

**系统里留下什么**（同一台模拟器实测）：

| 位置 | 有没有加密标识 | 说明 |
|---|---|---|
| logcat | 没有 | 系统的 `START` 行只打 `uuremote://external/...`、`xwshun-uuremote://callback/...`；本 App 和平台桥都不写日志 |
| 本 App 私有目录 | 没有明文 | `shared_prefs/xwshun_uuremote.xml` 的键和值都是密文；其他文件里搜不到 |
| `dumpsys activity` / 最近任务：本 App | 改后没有 | 改前：App 被回调冷启动时，整条回调地址被记成主 Activity 任务的基础 Intent。改由 `UuCallbackActivity`（不进最近任务、不留历史、收下就结束）接之后不再留 |
| `dumpsys activity` / 最近任务：UU | **有** | 本 App 发给 UU 的远控请求地址里带着标识（协议规定放在 URI 里），留在 UU 自己的任务记录上，bugreport 会带上。本 App 管不了 |

只在 API 35 上看过；更早的 Android 版本日志里打多少 URI 没有验证。

## 3. RustDesk：两级交付

### RDX-external：首版

通过验证过的RustDesk客户端scheme请求连接指定peer。当前代码支持连接URI；优先使用简单ID连接，不开放任意URI粘贴透传，不传密码，不调用config/password修改入口。Android manifest及URI处理应按安装版本复验。[S44](13-sources.md#s44) [S45](13-sources.md#s45)

用户先在RustDesk中配置自建ID/relay服务和认证；主App仅保存provider peer引用与显示名。包名、签名和自定义构建互相关联，用户选择自建客户端时建立新的可信provider配置，不能允许任意同scheme App抢占。

未获得真实状态回调的版本，只显示已发起，不能承诺连接/结束或撤销成功。失败不自动开启SSH或改远控服务器。主App的SSH SOCKS不自动作用于RustDesk；用户要求强制该路由时，本版拒绝外部调用或请用户明确另设远控网络策略。

### RDX-embedded：R38后续

若真正需要同一标签里显示桌面，可研究LobiShell RustDesk插件的AIDL + Surface模式。主App提供Android SurfaceView/PlatformView生命周期，插件持有native连接与画面；输入使用受限事件，不能用Dart逐帧Base64传整个视频。[S39](13-sources.md#s39) [S41](13-sources.md#s41)

先做单会话视频/输入PoC；选择、缩放、方向变化、鼠标键盘、IME、多显示器、音频等按实际能力逐步加。剪贴板、文件传输默认禁用，分别授权与测试。不继承整套RustDesk被控端/后台权限。

RustDesk核心及参考插件涉及AGPL，正式复用前审查来源、submodule、native依赖、修改源码提供、NOTICE及通信组合关系；拆APK不能自动豁免。LobiShell插件并不承诺兼容本产品，应实现本产品契约或合法fork后适配，不能伪装LobiShell包名调用它。[S39](13-sources.md#s39) [S56](13-sources.md#s56)

## 4. 设备聚合

`DeviceRecord`仅是用户组织对象：可关联一个或多个SSH HostRef、TailscaleDeviceRef、UuBindingRef、RustDeskPeerRef。相同hostname不证明同设备；跨provider不自动复制身份、密码、地址或在线状态。UU Windows限制应在入口上清楚显示；Linux设备可以继续SSH或另行实测RustDesk能力，不借UU绑定接口伪造兼容。
