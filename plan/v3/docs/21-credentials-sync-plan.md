# 21 安全密钥、加密同步导出、安全设置：实施计划（F25、F23、F22）

2026-10-31 写，来源是 R26 第三批反馈。所有者当天定了第 7 节的前四条，任务已进 `tasks.json`（R58–R66）；进度看 [STATUS](../STATUS.md)。

证据分三档，读的时候注意：

- **实测**：在本仓库跑过。
- **源码 / 文档**：读过对方的源码或官方文档，没跑过。
- **未核实**：单独写明，开工时先验证。

## 1. 结论

| # | 做什么 | 任务 | 依赖谁 | 规模 |
|---|---|---|---|---|
| 0 | dartssh2 从 2.22.5 升到 4.1.0 | R58 | 无 | 中：代码改动小，回归大 |
| 1 | 安全密钥（F25 第二阶段） | R59 | 实现不依赖；真机验证要**所有者的钥匙** | 大 |
| 2 | 加密文件导出导入 | R60 | 无 | 小 |
| 3 | 打开云同步：WebDAV、S3 | R61 | 无（代码已有，要重新审查） | 中 |
| 4 | 可信主机密钥页 | R65 | 无 | 小 |
| 5 | 手机之间局域网互传 | R62 | 无 | 中 |
| 6 | 应用锁、sudo 密码键、按主机按键布局 | R46、R66、R45 | 无 | 中 |
| 7 | Google Drive、OneDrive（**低优先级，未来可做**） | R63、R64 | **所有者去两家注册应用** | 中，每家一批 |

规模：小 = 一次会话；中 = 几次；大 = 要分多批。都是粗估。

**语言怎么选**：Flutter + Kotlin，不用 Rust。原因不是偏好：Android 上碰 NFC 只能走系统的 `IsoDep`，USB 只能走 USB Host API，用 Rust 也还得写一层 Kotlin。而且 `AGENTS.md` 写明了不引入全局 Rust。

**和桌面的关系**：所有者不用桌面 Netcatty，同步只管手机之间，不用为互通让步。格式还沿用现有的 `{meta, payload}`，因为代码已经有了，再造一种没有好处。

## 2. 阶段 0：先升 dartssh2

已做完，实测数字和取舍见 [R58](../evidence/R58.md)。下面是当时的理由和风险，留着对照。

**为什么排第一**：

- 安全密钥要异步签名：钥匙碰上才出结果，而 2.22.5 的 `sign()` 是同步的（`ssh_key_pair.dart:66`、`ssh_client.dart:1294`）。3.0.0 加了 `SSHIdentity`，`sign()` 可以返回 `Future`，还带 `shouldProbe`（先问服务器收不收这把钥匙，收才让用户碰）。**不用 fork**。
- 3.1.0 才有严格密钥交换（`kex-strict-c-v00@openssh.com`，防 Terrapin 攻击），4.0.0 修了一批安全问题（MAC 常量时间比较、先验 MAC 再解析等）。不做安全密钥也该升。
- 所有者还没开始跑 R26 清单。REL04 要求每条结果对应同一个包，升级后 SSH 相关的结果都要对新包重来。

**代价**：

- 实测：临时副本里只换版本号，`dart analyze` 报 3 个错误，全在测试的假客户端（`close()` 要返回 `Future`），`lib/` 没有错误。**测试没跑，运行时行为未知。**
- 4.0.0 默认不再协商 `ssh-rsa` 主机签名、`diffie-hellman-group14-sha1`、`aes*-cbc`。只支持这些的老路由器、老 NAS 会连不上，报协商失败。shun 没有自己配 `SSHAlgorithms`，所以会直接吃到这个变化。先不开，真遇到再加按主机的「旧算法」开关。
- 3.2.0 起按服务器的 `methodsLeft` 决定下一步认证方法，F25 刚做的「密钥 + 密码」要靠 `twostep` 用户回归。
- 4.0.0 起 `onVerifyHostKey` 每条连接只调一次，rekey 时主机密钥变了会断开。要确认 `host_trust.dart` 的流程不受影响。
- `third_party/README.md` 记的「SSH 版本行被拆包就断开」没在 changelog 里看到修复，`SshBannerDeadlineSocket` 留着。

来源：[dartssh2 changelog](https://pub.dev/packages/dartssh2/changelog)、[ssh_identity.dart](https://raw.githubusercontent.com/vicajilau/dartssh2/main/lib/src/ssh_identity.dart)。

## 3. 安全密钥（FIDO2 / NFC / USB）

要的是 OpenSSH 的 `sk-ssh-ed25519@openssh.com` 和 `sk-ecdsa-sha2-nistp256@openssh.com`。说白了：私钥在钥匙里出不来，手机只存一个「句柄」，登录时把要签的内容交给钥匙，用户碰一下或插上按一下。

### 库怎么选

| 层 | 选 | 依据 |
|---|---|---|
| SSH 登录 | dartssh2 4.1.0 的 `SSHIdentity.custom` + `SSHRawHostKey` / `SSHRawSignature` | 源码：两个 Raw 类原样输出字节，可以塞 sk 格式 |
| 跟钥匙通信 | Kotlin 桥 + [yubikit-android](https://github.com/Yubico/yubikit-android) 3.1.0 的 `Ctap2Session`（Apache-2.0；3.2 起要 compileSdk 37，见 [R59](../evidence/R59.md)） | 文档：`enable` 只要普通 `Activity`，不用改 `MainActivity` 的基类。子代理读源码：3.3.0（2026-10-29），rpId 是普通字符串，NFC、USB 共用，USB 放开设备过滤后能用非 Yubico 钥匙 |
| 句柄文件解析、签名打包 | 自己写 Dart | 算法在 [PROTOCOL.u2f](https://raw.githubusercontent.com/openssh/openssh-portable/master/PROTOCOL.u2f)；可对照 [cbssh #146](https://github.com/connectbot/cbssh/pull/146) |

同路线的先例：[ConnectBot #1821](https://github.com/connectbot/connectbot/pull/1821)（YubiKit，NFC + USB，还是草稿）、[BisonHerdr #43](https://github.com/ToxicBakery/BisonHerdr/pull/43)（yubikit 3.2.1，已合并，开关默认关，作者没上过真机）。两个都还没正式发布，别当成熟方案看。

不选的：

| 方案 | 为什么不选 |
|---|---|
| Android Credential Manager / Play 服务 FIDO2 | `rp.id` 要是 App 的域名，SSH 用的 `ssh:` 不是域名（子代理读官方文档，我没复核） |
| Conduit 路线（`fido2 ^1.1.0` + `flutter_nfc_kit`） | 能跑（Conduit 已上架，Apache-2.0），但 `fido2` 2.x 改成了 Rust 后端，留在 1.x 等于冻结。**是备选**：Kotlin 桥走不通就换 |
| `dartssh2_conduit` | 子代理说它基于 2.18.0，比现在还旧；官方版本已有异步签名，不需要 |
| Rust crate（`ctap-hid-fido2` 等） | 传输层还得写 Kotlin。我搜不到它们在 Android 上的证据（**未核实**，但不影响结论） |

### 协议要点（写代码时照这个）

- 请求：`rpId` = 公钥里的 application（通常 `ssh:`，**别写死**，ConnectBot 踩过）；`clientDataHash` = SHA256(待签数据)；`allowList` = 句柄。
- 发给服务器：类型名 + 签名 + 1 字节 flags + 4 字节 counter。flags 取 authData 第 32 字节，counter 取 33–36（大端）。ECDSA 要把 DER 转成 mpint r、s。多一个字节 sshd 就拒绝。
- 句柄文件：公钥字段 + flags + key_handle + reserved。flags 里 0x01 要触摸、0x04 要 PIN（`verify-required`）、0x20 存在钥匙里（resident）。

### 三种钥匙来源，按这个顺序做

1. **导入** `ssh-keygen -t ed25519-sk` 生成的文件。最简单，桌面和手机用同一把。
2. **手机上生成**（CTAP `makeCredential`，rp 用 `ssh:`），把公钥给用户贴进 `authorized_keys`。
3. **从钥匙读出 resident**（相当于 `ssh-keygen -K`）：必须输 PIN。ConnectBot 报过一把钥匙两个 resident 只认出一个，要测。

保险库格式照桌面：`SSHKey.type` 用 `ED25519-SK` / `ECDSA-SK`，句柄放 `privateKey`（[桌面源码](https://raw.githubusercontent.com/binaricat/Netcatty/main/domain/models/connection.ts)、[PR #2823](https://github.com/binaricat/Netcatty/pull/2823)，10-17 合并）。桌面 `privateKey` 里是不是完整的 OpenSSH 句柄文件**未核实**，开工先对一份。

### 分步

| 步 | 做什么 | 怎么算过 |
|---|---|---|
| SK1 | Dart：解析句柄文件、打包签名、接 `SSHIdentity.custom`。测试用 Dart 写的软件认证器 | Docker 里真 OpenSSH（alpine 3.22）两种类型都登得进；改 flags、counter、application 都被拒。只能证明格式对，证明不了钥匙行为 |
| SK2 | Kotlin：`SecurityKeyChannel`（断言、取消、PIN）。只在等钥匙时开 NFC 读卡模式和 USB 监听 | 假 CTAP 连接 + 真 `Ctap2Session` 的单测（BisonHerdr 的做法）；release 包验 R8 没裁掉东西、APK 增量（**未测**） |
| SK3 | 界面：凭据页导入和生成、连接时的「碰钥匙」页（写清哪台主机、哪个用户）、PIN 框 | 页面测试 |
| SK4 | 真机：所有者的钥匙，NFC、USB 都走一遍，含跳板、取消、拔钥匙、PIN 输错 | **只有这步算真通过**。没钥匙就写 BLOCKED |

### 容易踩的坑

- **连接超时**：`ssh_service.dart:1226` 有 `authWait`，等碰钥匙的时间要从里面扣掉，不然用户还没碰就报超时。sshd 默认 `LoginGraceTime` 120 秒，等待上限定 60 秒。
- **自动恢复**：断线重连碰不了钥匙。不能静默重试，要停下来说「需要碰钥匙」。锁屏不弹（SEC07）。
- **跳板**：每一跳碰一次。BisonHerdr 记了两次触摸，ConnectBot 作者说 ProxyJump 下似乎不工作，要专门测。
- **USB**：拔插后留着旧设备引用会让 `requestConnection()` 永远卡住；同时只能有一个连接（ConnectBot）。
- **NFC**：要贴到签完。PIN 先输，再贴。
- **PIN**：不存；要做 NFC 规范化（ConnectBot）；输错时显示钥匙报的剩余次数，不自动重试，试光了钥匙会锁死。
- **授权边界**（R36 验收）：应用解锁不等于同意签名，每次签名都要钥匙自己的触摸或 PIN。不做 agent forwarding。
- **老 U2F 钥匙**：首版不支持，`Ctap2Session` 不替你转协议。
- **测不到的**：软件认证器模拟不了重试计数、PIN 锁定、传输层（桌面的 [验证文档](https://raw.githubusercontent.com/binaricat/Netcatty/main/docs/fido2-validation.md) 也这么写）。

## 4. 加密同步和导出（F23）

### 每个后端怎么做

| 后端 | 手机上怎么做 | 所有者要准备 |
|---|---|---|
| 文件导出导入（R60） | 现有导出加密码，走现有 `saveFile` | 无 |
| WebDAV、S3（R61） | 代码已有，打开开关，直连 `http` | 一个 HTTPS 的 WebDAV，或桶和密钥 |
| 局域网互传（R62） | 扫码传地址和一次性密钥 | 无 |
| Google Drive（R63，低优先级） | `google_sign_in` 7.x 拿令牌，`http` 调 Drive v3，放 `appDataFolder` | Cloud 项目、Android 客户端（包名 + SHA-1）、Web 客户端 |
| OneDrive（R64，低优先级） | `flutter_appauth` + PKCE，放 `approot` | Azure 账号、Entra 租户、应用注册 |

Gist 代码也在，但它的 `clientId` 默认值是上游的，要用得换成所有者自己的 GitHub OAuth App，先不开。

桌面版内置 `github`、`google`、`onedrive`、`webdav`、`s3`，没有 P2P，也没有加密文件导入（源码：[cloudProviderIds.ts](https://raw.githubusercontent.com/binaricat/Netcatty/main/domain/cloudProviderIds.ts)、[vaultImport.ts](https://raw.githubusercontent.com/binaricat/Netcatty/main/domain/vaultImport.ts)）。Drive 和 OneDrive 的应用目录按应用隔离（[Drive](https://developers.google.com/workspace/drive/api/guides/appdata)、[OneDrive](https://learn.microsoft.com/en-us/onedrive/developer/rest-api/concepts/special-folders-appfolder)），手机和官方桌面读不到对方的文件。所有者不用桌面，这条只是留个记录，以后要接桌面时别以为填个账号就通了。

### 分步

**F23a 加密文件导出导入（R60）**

- 格式直接用 `netcatty_crypto.dart` 的 `{meta, payload}`（PBKDF2-SHA256 60 万次 + AES-256-GCM），**带凭据**。不再造一种格式。
- 导出前要口令输两遍，少于 12 位不让过：文件离开手机后可以离线暴力破解。口令框防截屏（R44）。
- 导入走现有 `planVaultImport`，先解密再出预览。`knownHosts` 不收（现有规则）。
- 现有的明文导出留着，名字改清楚：不带凭据。
- 要测：同名长文件被短内容覆盖后不留尾巴。子代理提到 SAF 写入要用 `"wt"` 模式才截断，**未核实** `file_picker` 的行为；不行就加个小 Kotlin 桥。

**F23b 打开云同步（R61）**

- 把 `ForkFeatures.cloudSync` 打开，但默认不连任何后端，用户配了才外连（BAS02）。
- **要重新过 R28**：R28 审查时身份、TOTP 还没搬进安全存储（`e75bc98`），要确认它们照样进加密 payload、同步回来照样进安全存储、不落明文。
- 手机的 ETag 检查是先读再比，不是原子的，两台手机同时写可能后写覆盖。文档照实写，别说「防并发」。

**F23c 手机之间局域网互传（R62）**

一台出二维码（IP、端口、一次性 256 位密钥），另一台扫。用这个密钥加密传输，走现有 `planVaultImport`，用完关服务。密钥熵够，不需要 PAKE（配对口令协议）。

会撞的墙：

- 所有者的手机上 shun 走 v2rayNG 的 VPN（`evidence/R26.md`），局域网连接可能被导进 VPN，表现是扫完码连不上。要在真机上测。
- 路由器开了 AP 隔离也连不上，要报错说清楚。
- 清单里 `usesCleartextTraffic="false"` 管不管 `dart:io` **未核实**。

不选的：

| 方案 | 为什么不选 |
|---|---|
| [iroh](https://docs.iroh.computer/languages/kotlin) | 没有 Dart 绑定，Android 要用 NDK 自己编，第三方报告 JNA 版在 Android 上异步调用不返回（未核实）；还要外连中继。为一个文件不值 |
| [LocalSend 协议](https://raw.githubusercontent.com/localsend/protocol/main/README.md) | 只有传输层加密，PIN 放在 URL 查询参数里，桌面也不认 |
| WebRTC、libp2p、Nearby Connections | 要信令或 Play 服务，桌面都不认。子代理这部分回报被截断，版本和细节**未核实**，不影响结论 |
| [OpenDAL](https://github.com/apache/opendal) | Dart 绑定才 0.0.1，Android 支持没查到。两家也就几个 REST 调用，不值得带 Rust |
| 系统文件选择器直连 Drive / OneDrive App（SAF，不用 OAuth） | 不用注册，很诱人。但 [KeePassDX 的 issue](https://github.com/Kunzisoft/KeePassDX/issues/1096) 和[讨论](https://www.github.com/Kunzisoft/KeePassDX/discussions/1089)里有授权被收回、写 0 字节的报告（多是 2019–2021 年的）。用来手动导出可以，当同步后端不行 |

**F23d Google Drive（R63，低优先级）**

- `google_sign_in` 7.x 底层是 Credential Manager，要 Play 服务。Google 已不支持 Android 上的自定义 scheme，回环地址也弃用了（[官方](https://developers.google.com/identity/protocols/oauth2/native-app)），`flutter_appauth` 走不了。
- 配错 SHA-1 时可能只报 `canceled`，看着像用户取消，实际是配置错（子代理读文档）。
- 设备上拿不到 refresh token，access token 1 小时过期，再次 `authorize()` 静默续（[官方](https://developer.android.com/identity/authorization)）。接口要 `Activity`，**后台自动同步不一定行**（未核实），首版只做前台同步。
- Play 服务是闭源库。R36 要求不忽略 GPL 条件，单独做一个 flavor（构建变体），现在的包不带它。

**F23e OneDrive（R64，低优先级）**

- `flutter_appauth`（BSD-3）+ PKCE，重定向 `msauth://top.xdwa.shun/<签名哈希>`，scope `Files.ReadWrite.AppFolder offline_access`。它的文档没提 `msauth://`，**未核实**，跑不通换 `msal_auth`。
- 注册应用要 Azure 账号和租户，账号类型选「仅个人账号」（[官方](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app)）。
- 令牌存 `flutter_secure_storage`，不进保险库、不进导出。

## 5. 安全设置（F22）

| 项 | shun 现在 | 怎么做 | 建议 |
|---|---|---|---|
| 可信主机密钥页 | 记录在 `extras.knownHosts`，只有连接时的弹框，没有管理页 | 新页面：主机:端口、类型、指纹、接受时间，能删一条（相当于 `ssh-keygen -R`） | **做**，小 |
| 粘贴 known_hosts | 没有；而且 `security.md` 第 3 节规定指纹只从手机上的核对框来 | 解析后逐条预览，用户确认才写入；哈希行（`\|1\|…`）首版跳过并说明 | **要所有者定**，改的是安全规则 |
| `@cert-authority` | dartssh2 4.1.0 主机算法表没有 `*-cert-v01`（[源码](https://raw.githubusercontent.com/vicajilau/dartssh2/main/lib/src/algorithm/ssh_hostkey_type.dart)） | 要 fork 改密钥交换 | **不做**，等真有 CA 再说（R51） |
| 应用锁（R46） | 没有 | 自己写 Kotlin 桥，用系统 `android.hardware.biometrics.BiometricPrompt`（API 28+），24–27 用 `KeyguardManager`。锁定间隔、连着不锁、直接 PIN、允许弱生物识别都照 LobiShell | **做**，中 |
| sudo 密码键 | 没有 | 快捷键栏加一个键，发当前主机存的密码，**默认每次过生物识别** | **做**，排在应用锁后面 |
| 按主机按键布局（R45） | 全局一套 | 照 R45 | **做**，中 |
| IME 无痕 | 终端输入、密码框已关学习（R44），有「系统安全键盘」；大输入框默认会学习（为了中文联想） | 给大输入框加个开关 | 可选 |
| 允许截图 | 敏感页一律防截屏，终端从不（R44） | 加开关放开 | 不做，R44 是所有者验过的 |
| Bracketed paste 开关 | 远端开了 DEC 2004 就包裹，这是标准行为 | 加「从不包裹」 | 不做，真遇到出问题的程序再加 |
| 会话通知 | 已有（`SshKeepAliveService`） | 无 | 不用做 |

三个实现细节：

- **应用锁不用 `local_auth`**：3.0.2 要 `FlutterFragmentActivity`，而 `MainActivity` 重写了引擎归属、Intent 清洗、返回键。换基类要重测 R22 那一整套，为一个弹窗不值。系统的 `BiometricPrompt` 不要求 Fragment。
- **sudo 键放在会话控制器层**：终端适配器按设计拿不到凭据（SEC09），不能破这个边界。密码不走 bracketed paste，也不进日志。按错的后果要写清：不在密码提示符时按，密码会明文显示在屏幕上。
- `host_trust.dart` 开头注释说 `knownHosts`「和桌面端同步」，和 `security.md`、`retainLocalDeviceData` 不一致，后者才对。做可信主机密钥页时顺手改掉。

## 6. 全局约束

- 每个用户能看到的改动都同步使用手册，界面字要少（`docs/dev/ui-text.md`）。
- 外连都要用户先配置（BAS02）。令牌、PIN、口令不进日志和普通导出（`log_scrub`、SEC 系列）。
- 真机、真钥匙、真账号没跑过的写 NOT_RUN 或 BLOCKED，软件认证器和假服务器只算前期证据。
- 每次装包、每次正式签名都要所有者当次同意。
- 盘只剩 6.5 GiB（10-31），R39 的脚本要求至少 12 GiB，设备测试前要清理。

## 7. 决定

**所有者 10-31 定的**：

1. dartssh2：没影响终端表现就升（对比结果见 [R58](../evidence/R58.md)）。
2. 安全密钥：先实现，后续真机测。
3. 不需要桌面 Netcatty；能做的先做，其余留在计划里。
4. Google Drive、OneDrive：落实到计划，优先级低，未来可做。

**所有者还没定的，先不做**：

- **粘贴 known_hosts**：要改 `security.md` 第 3 节「指纹只从手机上的核对框来」。我建议做，预览确认算核对。
- **F22 的三个开关**（大输入框无痕、允许截图、bracketed paste）：我建议都不做。
- **按主机的「旧算法」开关**：升级后只认 CBC、SHA-1 的老设备连不上。没人碰到就不做。
