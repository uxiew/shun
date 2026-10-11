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
| 官方 Android 示例的回调 | 自定义 scheme `uuremote-integration`、host `callback`，`VIEW` + `DEFAULT` + `BROWSABLE`，`singleTask`，onCreate 和 onNewIntent 都处理 | 用 `shun-uuremote://callback/bind`、`…/control`。不照官方示例让主 Activity 直接接，改由过路的 `UuCallbackActivity` 接（原因见下面「系统里留下什么」） |
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

**回调地址被抢**（模拟器 API 35，用 `plugins/out/fakeuu-hijack.apk` 实测）。另一个 App 也声明 `shun-uuremote://callback` 时，UU 回调会让系统弹「Open with」；用户选到它，它就拿到 state、nonce 和加密设备标识，还能把标识换成自己的、用显式包名转给本 App——校验全过。所以：

- 探测时查有没有别的包声明了回调地址（清单里为此多一条 `<queries>`）。有：页面说出包名，绑定和小窗不发；全屏不带回调，照常。
- 绑定成功的回调到达时再查一次（防请求发出后才装上的），有就作废，不给用户确认。
- 挡不住的：系统把那一次回调交给谁由用户在弹窗里选，选错了标识就被它拿走。没有「只让 UU 发给我」的办法——要么 UU 改用带签名校验的通道，要么用 App Links（https 域名归属验证），这两样官方协议都没有。

**系统里留下什么**（同一台模拟器实测）：

| 位置 | 有没有加密标识 | 说明 |
|---|---|---|
| logcat | 没有 | 系统的 `START` 行只打 `uuremote://external/...`、`shun-uuremote://callback/...`；本 App 和平台桥都不写日志 |
| 本 App 私有目录 | 没有明文 | `shared_prefs/shun_uuremote.xml` 的键和值都是密文；其他文件里搜不到 |
| `dumpsys activity` / 最近任务：本 App | 改后没有 | 改前：App 被回调冷启动时，整条回调地址被记成主 Activity 任务的基础 Intent。改由 `UuCallbackActivity`（不进最近任务、不留历史、收下就结束）接之后不再留 |
| `dumpsys activity` / 最近任务：UU | **有** | 本 App 发给 UU 的远控请求地址里带着标识（协议规定放在 URI 里），留在 UU 自己的任务记录上，bugreport 会带上。本 App 管不了 |

只在 API 35 上看过；更早的 Android 版本日志里打多少 URI 没有验证。

## 3. RustDesk：两级交付

### RDX-external：首版

通过验证过的RustDesk客户端scheme请求连接指定peer。当前代码支持连接URI；优先使用简单ID连接，不开放任意URI粘贴透传，不传密码，不调用config/password修改入口。Android manifest及URI处理应按安装版本复验。[S44](13-sources.md#s44) [S45](13-sources.md#s45)

用户先在RustDesk中配置自建ID/relay服务和认证；主App仅保存provider peer引用与显示名。包名、签名和自定义构建互相关联，用户选择自建客户端时建立新的可信provider配置，不能允许任意同scheme App抢占。

未获得真实状态回调的版本，只显示已发起，不能承诺连接/结束或撤销成功。失败不自动开启SSH或改远控服务器。主App的SSH SOCKS不自动作用于RustDesk；用户要求强制该路由时，本版拒绝外部调用或请用户明确另设远控网络策略。

### X07 固定的 RustDesk 口径（2026-09-30）

RustDesk 没有给第三方 App 的接入文档，下面每一条都是从源码读出来的。
**来源**：`rustdesk/rustdesk` tag `1.4.9`，提交 `6c578292e8ebbbec708b76986ba8c4bc7c509747`（2026-07-06 发布，当天最新的正式版；1.5.0 还是预发布）。原件存在仓库外 `../.toolchain/artifacts/`：

| 文件 | sha256 |
|---|---|
| `rustdesk-1.4.9-6c578292-AndroidManifest.xml`（`flutter/android/app/src/main/AndroidManifest.xml`） | `93c8be2bbade069f89662bc23b8bd75a161bfe066e18009717097d9903a47d92` |
| `rustdesk-1.4.9-6c578292-flutter-lib-common.dart`（`flutter/lib/common.dart`，链接处理在 `urlLinkToCmdArgs`） | `530a14c6dc5a8ea34c6d0a8f4eafe7c6821990e660f421c22d26a5fc56969438` |
| `rustdesk-hbb_common-7e1c392c-src-lib.rs`（子模块 `hbb_common` 提交 `7e1c392c`，自定义 ID 规则 `is_valid_custom_id`） | `71fe3406431ff01d8b2c2282028da99936d321787e2147db6fa999663c9f4b49` |
| `rustdesk-hbb_common-7e1c392c-src-config.rs`（自动 ID 怎么生成 `get_auto_id`） | `318790aa53dee4a8c52d6384338ef184ebb9e7a877b0f0f8a3e753c601a1654f` |

| 项 | 源码里是怎样的 | X07 的做法 |
|---|---|---|
| 包名 | `com.carriez.flutter_hbb` | 默认只认这个包名；别的包要用户明确信任（见下面「发给谁」） |
| 谁接链接 | `MainActivity`（`singleTop`），intent-filter 是 `VIEW` + `DEFAULT` + `BROWSABLE`、`scheme="rustdesk"`，不限 host | `<queries>` 里声明 `rustdesk` scheme（另加一条带 host 的，原因同 X06）；请求用显式包名发 |
| 连接链接 | 三种写法都会连：`rustdesk://connect/<ID>`、`rustdesk://<ID>`、`rustdesk://connection/new/<ID>`（兼容旧写法） | 只发 `rustdesk://connect/<ID>`。`rustdesk://<ID>` 把 ID 放在主机名的位置：URI 解析会把它转成小写，而且 ID 恰好叫 `config`、`password`、`terminal` 时会被当成命令 |
| 别的动作 | `play`、`file-transfer`、`view-camera`、`port-forward`、`rdp`、`terminal`、`terminal-admin` | 都不发。首版只做远程桌面 |
| 查询参数 | `password`（1.4.0 的移动端不理它，1.4.5 起认：带着它就直接用这个密码连）、`key`、`relay`、`switch_uuid`，键名不分大小写 | 一个都不带。密码由用户在 RustDesk 里输 |
| ID 里的特殊写法 | `ID@服务器`、`ID?key=…`：改用另一台 ID 服务器；结尾 `/r` 或 `\r`：强制走中继 | 不接受。用哪台服务器、走不走中继，只在 RustDesk 里配 |
| 改配置的链接 | `rustdesk://config/<配置串>` 导入服务器配置；`rustdesk://password/<密码>` 改这台手机被控时的固定密码 | 从不构造；平台层发送前再按白名单核一次，只放行 `rustdesk://connect/<ID>` |
| ID 怎么从链接里取 | `uri.path.substring(1)`，**不做百分号解码** | 不编码。接受的字符本来就不需要编码 |
| ID 格式 | 自动生成的是纯数字（桌面端由网卡地址算出，最大 536870911；手机端 10 位）；自定义 ID 是 `^[a-zA-Z][\w-]{5,15}$`。RustDesk 界面把数字 ID 每三位加空格显示，连接前自己去掉空格 | 纯数字 1–16 位（先去掉空格）；或字母开头、共 6–16 位的字母、数字、下划线、连字符。只收 ASCII（RustDesk 的 `\w` 还包括各国文字，那种 ID 这一版填不了）。按 IP 或域名直连也不收 |
| 拉起之后 | 移动端直接进远控页开始连接，不再问一次 | 只在用户点「用 RustDesk 远控」时发；保存 ID、打开页面都不发 |
| 结果回报 | **没有**。链接里没有回调地址这种东西，RustDesk 不会把连上、失败、断开告诉发起方 | 只显示「已交给 RustDesk」和时间，任何情况下都不写「已连接」「已断开」 |

**版本**（同一个函数逐个 tag 对比：1.2.3、1.2.4、1.2.6、1.2.7、1.3.0、1.3.9、1.4.0、1.4.5–1.4.9、1.5.0；中间没抽到的 tag 没看）

| 版本 | 源码里的情况 | X07 怎么对待 |
|---|---|---|
| 1.2.3 及更早 | 清单里没有 `rustdesk` scheme | 「版本太旧」，不发 |
| 1.2.4 – 1.4.6 | 认 `rustdesk://connect/<ID>`。`config`、`password` 两种链接**不设防**：任何 App 或网页发一条链接，就能改这台手机上 RustDesk 的服务器配置和固定密码 | 可用，页面提醒更新到 1.4.7 以上（这是 RustDesk 自己的问题，本 App 发不发都在） |
| 1.4.7 – 1.5.0 | `config`、`password` 链接要构建时打开内置选项（`allow-deep-link-server-settings`、`allow-deep-link-password`）才执行，默认只弹一个 `Failed`。1.4.7、1.4.8、1.4.9、1.5.0 的链接处理函数一字不差 | 可用 |
| 高于 1.5.0 | 没看过 | 可用，页面写明「这个版本没核对过」，链接仍按上面的写法发，不猜新写法 |

**发给谁**

| 手机上的情况 | X07 的做法 |
|---|---|
| `com.carriez.flutter_hbb`，证书是下表两张之一 | 直接可用 |
| `com.carriez.flutter_hbb`，别的证书（应用商店重签的、自己编译的、冒牌的，本 App 分不出来） | 显示证书，要用户批准；批准后证书再变就停下重新核对 |
| 别的包名也声明 `rustdesk://`（改了包名的自建客户端，或者碰巧/故意占这个 scheme 的 App） | 默认不发给它，只列出来。用户点「信任并改用」、看过包名和证书后才发给它；之后它换了证书同样停下 |
| 多张证书共同签名 | 不支持 |

**固定的证书**

| 渠道 | 证书 SHA-256 | 从哪读的 |
|---|---|---|
| GitHub 发行版 | `e92d44ba9b65003c7340683b0a9234f617c1b23a1dd90e89f7d04170b72bfc86`（`CN=zhou huabing, OU=IT, O=carriez, L=singapore`，RSA 2048） | `rustdesk-1.4.9-aarch64-signed.apk`，26871021 字节，sha256 `285b4f0735c000e5155b9a6f087b57744e46c960f4332963f51add1804982102`（和 GitHub 发行页 API 给的 digest 一致），versionCode 2067。存档在 `../.toolchain/artifacts/rustdesk-official-1.4.9-aarch64-285b4f07.apk`。旁证：1.2.7（2024-07-23 发布，sha256 `7d435aac…b5e3a6`）是同一张 |
| F-Droid | `85366b10ecadff33e10c53250444a125203908285363c27fc62a561f9660fa48`（`CN=FDroid, OU=FDroid, O=fdroid.org`） | `f-droid.org/repo/com.carriez.flutter_hbb_104090002.apk`（arm64，sha256 `c5f3ba33…87bd1ada`）和 `…_104090003.apk`（x86_64，sha256 `f0b7f222…4565463`），两个都是 1.4.9、同一张证书。F-Droid 自己编译、用它给这个包专用的密钥签，所以和 GitHub 版不是同一张。这两个文件读完证书就删了 |

Google Play 等其他渠道的证书没有核对过，装的是那些版本时走「要用户批准」。重新读证书：`$ANDROID_HOME/build-tools/36.0.0/apksigner verify --print-certs <apk>`。

**真实 RustDesk 1.4.9 实测**（2026-10-01，项目模拟器 API 35，所有者同意安装；装的是上面那个 GitHub 发行版 APK，没登录账号、没给录屏等被控权限，测完已卸载）

ID 用的是 `shun-x07-none`：字母开头的自定义 ID 写法。RustDesk 自动分配的 ID 都是纯数字，所以不会撞上别人的电脑；实测服务器回的也是「离线或不存在」。

| 做了什么 | 看到的 |
|---|---|
| 本 App 探测 | 包名 `com.carriez.flutter_hbb`、1.4.9，页面写「签名证书和 GitHub 官方发行版的一致」「这个版本的连接链接按源码核对过」，不用批准 |
| 第一次点「用 RustDesk 远控」（RustDesk 从没打开过） | 系统交给 `com.carriez.flutter_hbb/.MainActivity`，在它自己的任务里（`flg=0x10000000`）。RustDesk 没有任何引导页，直接进全屏远控页开始连，约 4 秒后弹「Connection error: Failed to connect: the target device is offline or does not exist」 |
| 点 OK、按返回 | 回到本 App，页面只有「已交给 RustDesk…」和「交给了：com.carriez.flutter_hbb 1.4.9」，没有任何别的变化 |
| RustDesk 进程还活着，再点一次 | 它又开始连同一个 ID，同样的报错。按 Home 让它停在自己主界面再点：走的是已开着的那条路（日志 `A uri was received: …`），也照连 |
| 卸载 RustDesk | 页面变「没有装 RustDesk」，这台主机的 ID 还在，远控按钮变灰 |

**RustDesk 自己会把整条链接打进日志**：冷启动时 `I flutter : initialLink: rustdesk://connect/<ID>`，已开着时 `I flutter : A uri was received: rustdesk://connect/<ID>. handleByFlutter true`（核对过进程号，是 RustDesk 的进程，不是本 App）。所以 logcat 里能看到 RustDesk ID，这是 RustDesk 的行为，本 App 管不了；本 App 自己的进程没打过。
系统的 `ActivityTaskManager: START` 行只有 `dat=rustdesk://connect/...`；RustDesk 任务的记录（`dumpsys activity recents`，bugreport 会带上）里是完整的 `dat=rustdesk://connect/<ID>`。本 App 的任务记录里没有。

没测到的：真的连上一台电脑之后 RustDesk 怎么样（要一台被控电脑，这轮所有者没提供）；自建 ID 服务器、中继没配好时的样子；Android 11 以下的包可见性。

### RDX-embedded：R38后续

若真正需要同一标签里显示桌面，可研究LobiShell RustDesk插件的AIDL + Surface模式。主App提供Android SurfaceView/PlatformView生命周期，插件持有native连接与画面；输入使用受限事件，不能用Dart逐帧Base64传整个视频。[S39](13-sources.md#s39) [S41](13-sources.md#s41)

先做单会话视频/输入PoC；选择、缩放、方向变化、鼠标键盘、IME、多显示器、音频等按实际能力逐步加。剪贴板、文件传输默认禁用，分别授权与测试。不继承整套RustDesk被控端/后台权限。

RustDesk核心及参考插件涉及AGPL，正式复用前审查来源、submodule、native依赖、修改源码提供、NOTICE及通信组合关系；拆APK不能自动豁免。LobiShell插件并不承诺兼容本产品，应实现本产品契约或合法fork后适配，不能伪装LobiShell包名调用它。[S39](13-sources.md#s39) [S56](13-sources.md#s56)

## 4. 设备聚合

`DeviceRecord`仅是用户组织对象：可关联一个或多个SSH HostRef、TailscaleDeviceRef、UuBindingRef、RustDeskPeerRef。相同hostname不证明同设备；跨provider不自动复制身份、密码、地址或在线状态。UU Windows限制应在入口上清楚显示；Linux设备可以继续SSH或另行实测RustDesk能力，不借UU绑定接口伪造兼容。
