# 安全与隐私：开发者须知

要动凭据、主机指纹、终端输入输出、插件，或者要加「在服务器上执行命令」的功能，先读对应那一节。
这里只写安全上的边界：**代码现在怎么做、边界在哪、改了会怎样**。数据怎么流、一次连接怎么建起来见[架构](architecture.md)；用户看到的行为见[使用手册](../user/README.md)和[Mosh 使用指南](../user/mosh.md)；插件接口见[插件作者文档](../plugin-authors/README.md)。这里不重复，只链接过去。

路径都相对仓库根（`shun/`）。只写文件、类名、函数名，不写行号：代码一改行号就对不上。

## 先记住六条底线

出处是 `plan/v3/AGENTS.md`，下面每一节都在落实这六条。哪个改动要破其中一条，先问所有者。

1. 凭据（密码、私钥、私钥口令、代理口令、各种 token 和 API Key）只进系统安全存储，不进日志、普通文件、导出文件和系统备份。
2. 选了代理或跳板，失败就报错，不退回直连。
3. 服务器指纹第一次要用户核对；变了就断开，没有「仍然连接」。
4. 服务器发来的字节只能改屏幕：不能读写手机剪贴板，不能打开链接，不能替用户往 shell 里回话。
5. 不暗中在服务器上执行：断线恢复不重跑启动命令、不重放用户输入；会在服务器上执行东西的入口都要用户自己点。
6. 插件拿不到保险库；Mosh 的一次性 key 只交给证书登记过的 `shun.mosh`。

## 1. 敏感数据放在哪

先说清两个词：

- **安全存储**：`flutter_secure_storage` 9.2.4。Android 上开了 `encryptedSharedPreferences`，数据是 App 私有目录里一份加密的偏好文件，解密用的密钥在 Android Keystore（系统保管密钥的地方，密钥导不出这台设备）。iOS 上是钥匙串，`first_unlock_this_device`：开机后解锁过一次才读得到，不随备份去别的设备。
- **普通偏好**：`shared_preferences`，不加密。

| 数据 | 存在哪 | 键名 | 代码 |
|---|---|---|---|
| 主机密码、Telnet 密码、主机自带代理的口令 | 安全存储，文件名 `FlutterSecureStorage` | `host.<id>.password`、`host.<id>.telnetPassword`、`host.<id>.proxyPassword` | `VaultRepository`（`lib/infrastructure/storage/vault_repository.dart`） |
| 私钥、私钥口令 | 同上 | `key.<id>.private`、`key.<id>.passphrase` | 同上 |
| 可复用代理的口令 | 同上 | `proxy.<id>.password` | 同上 |
| 云同步主密码 | 同上 | `shun.sync.masterPassword` | 同上 |
| 云端凭据（WebDAV 密码、S3 secret、GitHub token） | 同上 | `sync.provider.secret`、`sync.provider.sessionToken` | 同上；`SyncConnection.toJson` 不含这两项 |
| AI API Key | 同上 | `shun.ai.apiKey`；多服务商配置（各带 Key）在 `shun.ai.workspace.*` | `VaultRepository.aiWorkspace` |
| 保险库其余内容：主机、分组、路线、片段、主机指纹 | 普通偏好 | `shun_vault_v1` | 写之前过 `vaultWithoutSecrets`（`lib/domain/vault_secrets.dart`） |
| 存过哪些凭据（只有键名，没有值） | 普通偏好 | `shun_secret_index_v1` | 见 1.2 |
| 云同步的地址、用户名、bucket，版本检查点，没传完的恢复副本 | 普通偏好 | `shun_sync_v1`、`shun_sync_version_v1`、`shun_pending_sync_v2` | 恢复副本是用主密码加密过的整份，见第 2 节 |
| Tailscale 的 OAuth client | 安全存储，文件名 `shun_tailscale_catalog` | `tailscale.catalog.<来源ID>.oauth.clientId` / `.clientSecret` | `TailscaleCatalogSecretStore`；粘贴的 token 读完就丢，不存 |
| UU 的加密设备标识、RustDesk ID | 安全存储，文件名 `shun_uuremote`、`shun_rustdesk` | — | `SecureProviderBackend`（`lib/application/external_remote.dart`） |
| AI 命令行的检测设置、最近工作 | 安全存储，文件名 `shun_ai_cli` | `discovery.<scope>`、`recent.<scope>` | `lib/infrastructure/storage/ai_cli_*.dart` |
| 插件批准记录 | 普通偏好 | `shun.plugins.approvals.v1`、`shun.plugins.disabled.v1` | `PluginApprovalStore`，只有公开的证书摘要 |
| Mosh 会话 key | 只在内存，用完清零 | — | 第 7 节 |
| 终端画面、大输入框的草稿 | 只在内存 | — | App 被杀就没了 |
| 剪贴板 | 用户点「粘贴」时才读 | — | `lib/presentation/widgets/terminal_paste_sheet.dart` |

**不算凭据、却明文存着的**：主机的「连接后执行命令」（`startupCommand`）和环境变量（`environmentVariables`）。`vaultWithoutSecrets` 不去掉它们，`shun_vault_v1` 和导出文件里都有。别在界面上引导用户往里放 token；真要当凭据处理，`vaultWithoutSecrets` 和 `VaultRepository` 两处一起改，同步改 `test/vault_secrets_test.dart`。

### 1.1 每个 FlutterSecureStorage 都要写 sharedPreferencesName

flutter_secure_storage 9.2.4 的 Android 端，只要某次调用带了非空文件名就切过去，之后不再切回默认文件。以前保险库没写文件名：同一次运行里先碰过 UU、RustDesk 或 Tailscale 目录的存储，保险库的密码就写进了它们的文件，重启后保险库在自己的文件里读不到，界面报「无法解密」（R14 在模拟器上撞到）。所以 `vaultSecureStorage` 显式写了 `sharedPreferencesName: 'FlutterSecureStorage'`，也就是原来的默认名，老数据照常读。

新增存储漏写文件名，`test/secure_storage_file_names_test.dart` 的「lib 里每一处 FlutterSecureStorage 都显式写了文件名」会红。文件名定了就别改：改了等于换一份空存储，旧数据全读不到。

### 1.2 凭据解不开时

Keystore 主密钥失效（系统恢复、锁屏被重置）时，flutter_secure_storage 9.2.4 不报错，而是悄悄换一份新存储，以前存的全读成空。光看读出来的值，分不出「没存过」和「解不开」，所以：

- `VaultRepository` 在 `shun_secret_index_v1` 记下存过非空值的键名。清单里有、读出来却是空，和读的时候抛异常一样，记进 `unreadableSecrets`。
- 解不开的那条不删：`_writeSecret` 碰到空值时跳过 `unreadableSecrets` 里的键，用户重新填了才覆盖；整台主机、整把私钥被删时才一起删。
- 用到解不开凭据的连接在拨号前拒绝，写明是哪一跳、哪种凭据（`unreadableCredentialProblem`，`lib/application/credential_availability.dart`）。
- 读失败时不带平台异常的原文：里面有解密细节。

测试：`test/vault_unreadable_secrets_test.dart`。

### 1.3 内存里的副本

- 保险库启动时整份读进内存，一直在。没有应用锁（使用手册第 12 节写明了）。
- 每个标签为断线恢复冻结一份路线，里面有凭据。App 在后台满 `credentialLease`（10 分钟，`lib/application/connection_lifecycle.dart`）就调 `ActiveTerminalSession.forgetSecrets` 清掉。光靠 Timer 不够：手机睡着时 Timer 不走（LIFE07 真机锁屏 31 分钟 CPU 只醒了 2 分钟），所以 `SessionController._checkLease` 在每次醒来用路线时按墙上时钟再核一次。
- 还连着的连接清不掉：dartssh2 的客户端在连接存续期间一直引用登录用过的私钥。

### 1.4 系统备份和换机迁移

`android/app/src/main/AndroidManifest.xml` 里 `allowBackup="false"`、`fullBackupContent="false"`，另指定 `res/xml/data_extraction_rules.xml`：云备份和设备间迁移两节，9 个数据域全部 `exclude path="."`。

为什么光写 `allowBackup="false"` 不够：Android 12 起，部分厂商设备上它只关云备份，关不掉换机迁移（文件注释里有出处）。不排除的话，凭据的密钥虽然留在 Keystore，保险库的主机、跳板、代理配置连同那份密文都会被搬走。

## 2. 导出、导入、云同步

### 2.1 导出

`VaultExportService.export` 只写 `vaultWithoutSecrets` 之后的 JSON（文件名 `shun-export.json`）：没有密码、私钥、私钥口令、代理口令。主机名、用户名、路线、指纹记录、启动命令、环境变量都在里面，所以导出文件也别进仓库。测试：`test/vault_secrets_test.dart`「导出文件里没有任何凭据」、`test/vault_export_service_test.dart`。

### 2.2 导入

逻辑在 `lib/application/vault_import.dart`，用户看到的确认框写在[使用手册第 12 节](../user/README.md#12-导出导入与凭据)。开发上要知道两条：

- **凭据只在「要发往的地方」没变时沿用**（`keepLocalSecrets`）：主机按 协议 + 地址 + 端口 + 用户名比，代理按 类型 + 地址 + 端口 + 用户名比。不这样的话，一个改了地址的导入文件就能让本机存的密码发给另一台机器。文件自带凭据的以文件为准。
- **指纹记录**：合并时同一台（按 `trustHostName` 规范化后的名字 + 端口）以本机为准；文件里本机没有的那些直接加进来，替换模式整份用文件里的。也就是说，**导入文件里的指纹会被当成已核对过**，用户不会再看到核对框。改导入逻辑时别扩大这一点。

### 2.3 云同步（默认关）

`ForkFeatures.cloudSync` 默认 `false`（`lib/application/fork_features.dart`），设置页看不到入口，本地残留的 `autoSyncEnabled=true` 也不会启动同步。下面是打开以后的行为。

加密在 `NetcattyCrypto`（`lib/infrastructure/sync/netcatty_crypto.dart`），格式和桌面端互通：

| 项 | 值 |
|---|---|
| 口令变密钥（KDF，故意算得慢，猜口令的人每猜一次也得算这么久） | PBKDF2-HMAC-SHA256，600 000 次，输出 256 位 |
| 盐 | 32 字节，每次加密用 `Random.secure()` 重新生成 |
| 加密 | AES-256-GCM（加密同时带校验，被改一个字节就解不开）；IV 12 字节，每次重新生成；16 字节校验标签接在密文后面，一起 base64 |
| 解密失败 | 统一报「同步密码错误或云端文件已损坏」 |

**密文里有凭据。** `AutoSyncController` 同步前先把凭据读进内存（代码注释「Always hydrate credentials」），主机密码、私钥都在加密的 payload 里。主密码一旦泄露，云端那份就等于明文。

**不上传的**：`knownHosts`（`retainLocalDeviceData` 把本机的接回来）和 `lastConnectedAt`（`_syncJson` 删掉）。`sanitizeVaultForSync` 只做这件事，**名字像脱敏，其实不去凭据**，别拿它当脱敏函数用。

**云端看得到的**：

- `meta` 是明文：`version`、`updatedAt`、`deviceId`（`shun_device_id_v1` 里的 UUID）、`deviceName`（固定 `shun`）、`appVersion`、`iv`、`salt`、`algorithm`、`kdf`、`kdfIterations`，新格式多一个 `syncSchemaVersion`。
- 文件名 `netcatty-vault.json`；GitHub 上是私有 Gist，描述是 `Netcatty Encrypted Vault (DO NOT EDIT MANUALLY)`。
- 存储服务本来就看得到的：文件大小、修改时间、请求来源 IP、哪个账号。

**传输**：

- WebDAV 必须是 https，不是就报「WebDAV 必须使用 HTTPS 地址」。
- S3 默认也要 https。用户勾了「不安全连接」（`SyncConnection.allowInsecure`）就允许 http，而且**接受任何证书**（`S3SyncClient` 里 `badCertificateCallback` 直接返回 true）。这时只剩 payload 本身的加密在保护内容。
- GitHub 走 device flow（到 github.com 输一次性码授权），scope 是 `gist read:user`。`GitHubAuthService.clientId` 默认值写在代码里，可用 `--dart-define=GITHUB_OAUTH_CLIENT_ID` 换；它是公开值，device flow 用不到 client secret，**也别往代码里加**。
- 下载超过 8 MiB 拒收（`maxResponseBytes`），单个请求 25 秒超时。

**防误删**：`assertSafeSyncShrink`（`lib/infrastructure/sync/sync_safety.dart`）发现某类条目少了 10 个及以上，或者少了 3 个及以上且达到原来的一半，就拒绝上传，要用户手动确认。自动同步从不替用户确认。

**改了会怎样**：改算法、迭代次数或字段名，桌面端就解不开。`test/netcatty_crypto_test.dart` 有一条用桌面端 Node/WebCrypto 生成的密文当夹具，改坏了它会红。另外 `decrypt` 直接用云端 `meta.kdfIterations`，没有上下限：被改成很大的数，手机会一直算下去。

## 3. 主机指纹

指纹是服务器公钥的摘要，用来确认「这次连的还是上次那台」。规则全在 `lib/application/host_trust.dart`，弹框在 `lib/presentation/widgets/host_key_dialogs.dart`，两者由 `hostKeyVerifier`（`lib/presentation/widgets/connection_prompts.dart`）接起来。用户怎么核对见[使用手册第 5 节](../user/README.md#5-服务器指纹)。

- **什么时候查**：dartssh2 2.22.5 在握手阶段拿到服务器公钥后调 `onVerifyHostKey`，给的是 OpenSSH 写法的 SHA256 指纹；没通过就在发任何登录信息之前断开。每一跳（包括跳板）各查各的，Mosh 的那段 SSH 也一样。
- **三种结果**（`verifyHostKeyWithKnownHosts`）：已信任且一致，直接放行；第一次见，弹框让用户核对，点「接受并记住」才写记录；变了，弹「服务器指纹已变化，已阻止连接」，只有「删除旧指纹」和「关闭」两个按钮，**无论点哪个这次都返回 false**，删了旧的也要重连、重新核对。
- **记在哪、按什么比**：保险库 `extras.knownHosts`，按**逻辑主机名 + 端口**记，不按实际拨出去的地址：经代理或跳板时拨的是代理端口或 127.0.0.1，按那个记就张冠李戴。名字比之前过 `trustHostName`：去首尾空白、IPv6 方括号、结尾的点，IP 按标准写法，域名转小写。只做写法上的等价，**不做 DNS 解析**：两个名字指向同一个 IP 也各自核对。
- **弹框所在页面没了**（`context.mounted` 为 false）一律按拒绝处理。
- 同步不上传指纹（第 2.3 节）；导入会带进来（第 2.2 节）。

测试：`test/host_trust_test.dart`，其中「指纹变了：只有「删除旧指纹」和「关闭」，没有任何继续连接的按钮」钉死了第三种情况。

**别做**：给「指纹变了」加「确认更新」「仍然连接」之类一点就过的按钮——用户会养成不看就点的习惯，拦了等于没拦。也别因为地址是 100.x、在 tailnet 里就自动信任。

## 4. 终端：服务器发来的字节能做什么

终端引擎是 Ghostty（`third_party/libghostty`，Dart 侧是 flterm 和 libghostty 两个包）。App 里只有 `GhosttyTerminalAdapter`（`lib/infrastructure/terminal/ghostty_terminal_adapter.dart`）和 Ghostty 视图认识它们。

服务器能发「控制序列」：以 ESC 开头的一串字节，让终端做事，比如 OSC 52（`ESC ] 52 ;` 开头）让终端读写剪贴板。防护的办法很简单：**适配器只接 `onOutput` 和 `onResize` 两个回调，其余效果回调一个都不接**。flterm 和 libghostty 在回调为 null 时根本不往原生层注册，请求就没人执行。不是编译期关掉，所以别人一接上就生效。

| 服务器发的 | 结果 | 靠什么 |
|---|---|---|
| OSC 52 读、写剪贴板 | 不读、不写、不回 | 不设 `onClipboardRead` / `onClipboardWrite` |
| 桌面通知（OSC 9、777）、进度（OSC 9;4）、改标题 | 不执行 | 对应回调都是 null |
| 标题回报（`CSI 21 t`） | 不回 | libghostty 的 `setTitleReports` 默认关，App 从不打开 |
| 工作目录（OSC 7） | flterm 内部记下，App 不读 | — |
| Kitty 图像、APC 数据 | 直接丢 | `ghosttyTerminalConfig` 里 `kittyImageStorageLimit: 0`、`apcBufferLimit: 0` |
| iTerm2、Sixel 图像 | 不显示 | App 层没有处理代码，测试只核对不触发平台调用、后面的字照常显示 |
| 设备属性、光标位置、颜色（OSC 10/11/12）等查询 | 回答 | flterm 回；只回给当前代次的连接（见下） |

其他上限：滚动区 `scrollbackMaxLines: 5000`、`scrollbackMaxBytes: 8 MiB`。很长、一直不结束的控制序列，App 和 flterm 都没设上限，靠 Ghostty 原生层；`test/terminal_remote_effects_test.dart` 喂三段各 16 MiB，断言内存涨幅小于 64 MiB。

**改了会怎样**：给 controller 接上 `onClipboardRead`，服务器就能读走剪贴板里刚复制的密码、验证码。想加「允许服务器写剪贴板」这类功能，先问所有者，并在 `terminal_remote_effects_test.dart` 补断言。升级 libghostty 时核对 `setTitleReports` 的默认值：变成默认开，服务器可以先把标题设成一条命令、再要求回报，回报的内容就进了 shell 的输入行；`test/terminal_vt_corpus_test.dart` 的回话用例会发现。

**输入只给当前代次**：「代次」是标签每换一条连接加一的编号。`TerminalSessionAdapterBase.bind`（`lib/infrastructure/terminal/terminal_session_adapter.dart`）每次绑定换掉输出口，`emitInput` 没有绑定就丢。换代时 `onRebind` 写一个 CAN（0x18）打断上一代没写完的控制序列，否则新 shell 的输出会被当成那段序列吞掉。`SessionController.pasteInto` 用 `targetProblem` 核对目标还是不是用户动手那一刻的连接，不是就抛 `TerminalTargetChangedException`：不改发、不补发。

**链接**：`TerminalLinkReview`（`lib/domain/terminal_link.dart`）只开 http、https；`@` 前带用户名的、带空白或控制字符的、超过 2048 字符的不给开；显示文字和地址不同、域名有非 ASCII 字符或 `xn--` 的只提醒。视图不给 flterm `onActivate`，点一下不会打开。

**粘贴**：`PasteReview.of`（`lib/domain/terminal_paste.dart`）把 `\r\n` 和 `\r` 统一成 `\n`、去掉末尾换行、去掉 Tab 和换行以外的 C0 控制字符、DEL、C1；零宽和改文字方向的字符只计数提醒。`needsReview` 为真才弹预览：多行、末尾有换行、去掉过控制字符、有隐形字符，或 `text.length > 4096`（按 Dart 字符串长度，也就是 UTF-16 码元算）。之后 flterm 的 `paste` 按服务器的 bracketed paste（粘贴标记：开着时 shell 把整段当一次输入）状态包上标记，再把 ESC 等换成空格。

- 走 `PasteReview` 的：剪贴板粘贴、命令片段（`SessionController.send`）。
- **不走**的：AI 助手的命令（直接 `pasteInto`，见第 8 节）、mosh 安装命令的「填进 SSH 标签」、SFTP 的「在终端中打开当前目录」。新加入口按粘贴发，别按打字发。
- SFTP 那条用 `pasteInto` 发 `sftpTerminalCdCommand`（`lib/infrastructure/ssh/sftp_service.dart`）拼的 `cd '路径'`：单引号只防得住 shell，控制字符先到终端和 readline，在那里是按键，所以目录名里有 C0、DEL、C1（含 Tab、换行）就整条不发。以前按打字发、不查控制字符，服务器上一个叫 `a<Ctrl-C>touch x<回车>` 的目录，点一下就执行 `touch x`。测试：`test/sftp_terminal_usability_test.dart`「SFTP terminal cd refuses folder names with control characters」。

**插件的输出**也喂进同一个 `GhosttyTerminalAdapter`（`lib/application/plugin_terminal.dart`），上面的防护对它同样有效；但没有专门测插件这一路的用例。

测试：`test/terminal_remote_effects_test.dart`、`test/ghostty_terminal_adapter_test.dart`、`test/terminal_session_adapter_test.dart`、`test/terminal_layering_test.dart`（「终端适配层拿不到网络、凭据和存储」）、`test/terminal_links_test.dart`、`test/terminal_paste_review_test.dart`、`test/terminal_paste_test.dart`；设备上是 `integration_test/r19_terminal_test.dart`。

## 5. 日志、报错和崩溃报告

**现状**：

- `lib/` 里没有 `print`、`debugPrint`、`dart:developer` 的 `log`，也没用日志库。`lib/main.dart` 没装 `FlutterError.onError`、`runZonedGuarded`；依赖里没有 Sentry、Crashlytics、Firebase 这类崩溃上报。没捕获的异常按 Flutter 框架的默认方式处理，App 自己不往外发任何崩溃信息。
- 报错文本会显示在界面上，用户截图时会跟着出去，所以下面的规矩针对的是「报错」和「toString」，不只是日志。

**写新代码照这几条做**：

1. **带秘密的对象重写 `toString`**。现有的：`HostProfile`（只给 id、名称、协议）、`PastedAccessToken` 和 `OAuthClientCredential`（`<redacted>`）、`MoshBootstrapResult`（`key: <已隐藏>`）、`CheckLinkBanner`（只给域名，Tailscale check 链接里有一次性 token）、`TailscaleCheckPrompt`、`ProxyEntry`（只给类型和地址）。
2. **异常只带固定的人话**，不带原始输入、原始输出：`MoshBootstrapException` 只说是哪类问题（远端输出里可能有 key），`ProxyHandshakeException` 不含代理口令，SSH 报错是「谁（地址）哪一步：原因」。
3. **服务器回来的错误文本可能回显你发过去的东西**。Tailscale API 的 `_serverMessage`（`lib/infrastructure/tailscale/tailscale_api.dart`）去控制字符、把这次用过的 token 和 secret 原文换成 `<redacted>`、截到 200 字。S3 的报错（`S3SyncClient._ensureSuccess`）直接带服务器给的 Code、Message，GitHub 登录的报错直接带服务器的 `error_description`，都没有抹回显。
4. **第三方库的调试输出不放出去**。dartssh2 的 `printDebug` 接到 `SshLoginWatch.debug`，它只认 `SSHClient._authWithNone` 这一句（用来识别 none 认证），其余丢掉：调试文字里可能有 banner 原文，也就是 check 链接。

**碰不得的**：

- `HostProfile.toJson()`、`SshKeyProfile.toJson()`、`ProxyConfig.toJson()` 原样含凭据，只有 `toString` 是安全的。别把 `jsonEncode(x.toJson())` 拼进报错、日志或诊断。
- `SshService._describeSshError` 认不出的异常走兜底 `'$error'`，原文会进界面上的报错。新接的错误类型在这里加一条固定说法。
- `redactAiText`（`lib/infrastructure/ai/ai_workspace.dart`）是尽力而为：只认 PEM 私钥块、`authorization: bearer`、`api_key=`、`token=`、`password=`、`secret=` 后面的值、`sk-` 和 `ghp_` 这类前缀，以及主机名、用户名、标签；不认 `tskey-`、`AKIA…`。界面上写着「不能识别所有敏感内容，发送前请预览」，别在别处把它当成保证。

**Android 侧**：主 App 自己写的 Kotlin 里只有 `PluginBridge.kt` 打日志（TAG `ShunPlugins`），只记两类：被丢掉的会话事件、身份核对没过的插件回调。`UuRemoteBridge.kt` 注释写明不打日志：回调地址里有 UU 的加密设备标识。Mosh 插件（TAG `ShunMosh`）只记 pid、退出码和拒绝原因，不记 key。

**防截屏**：没有 `FLAG_SECURE`。填密码、私钥的页面能被截屏，也会出现在最近任务的缩略图里。这是计划里的 R44，还没做。

**测试**：`test/vault_secrets_test.dart`（「HostProfile.toString 只有 id、名称、协议」「连不上时的报错不带密码和代理口令」）、`test/socks5_hardening_test.dart`（「口令错误：说清是认证失败，报错里没有口令」「ProxyEntry 打印出来不含口令」）、`test/mosh_bootstrap_test.dart`（「错误信息从不带原始输出和 key」）、`test/tailscale_catalog_test.dart`、`test/ai_phase_one_test.dart`（「redaction masks identity, credentials and private key blocks」）。

**设备上的明文扫描**（需要模拟器，怎么跑见各脚本开头）：`tool/fixture-environment/r40_check_secrets.py` 在私有目录 `shared_prefs`、`files` 和 logcat 的 `flutter` 标签里搜测试环境的密码，只打印 PASS 和文件数；`tool/r39-device.py` 的 `scan_storage` 搜 R39 的特征串；`tool/sec05/seed_main.dart` 写一份带特征串的假凭据，再去备份产物、私有目录、日志里搜，做法记在 `plan/v3/evidence/R09.md`。

## 6. 插件信任

插件是另外安装的 App，经 Binder（Android 的跨进程调用）和宿主说话。接口、能力、签名的细节在 [contract.md](../plugin-authors/contract.md)、[capabilities.md](../plugin-authors/capabilities.md)、[compatibility.md](../plugin-authors/compatibility.md)；这里只写宿主这边的信任链。

1. **发现**：只查声明了 `top.xdwa.shun.plugin.action.PROVIDER_V1` 的服务，不申请 `QUERY_ALL_PACKAGES`。批准前只读描述符，不启动插件的任何代码。
2. **准入**：`AdmissionPolicy`（`packages/plugin_api/lib/src/admission.dart`），宿主的口径在 `pluginRegistryProvider`（`lib/application/plugin_registry.dart`）：
   - `builtin.` 开头和内置的 ID 只给宿主自己，外部包占用直接「已拒绝」；
   - `OfficialPlugins.reserved`（`lib/domain/plugins/official_plugins.dart`）里登记的 ID 只认登记的证书。现在只登记了 `shun.mosh`，别的证书签的包自称它，直接「已拒绝」，没有批准按钮；
   - Android 调试证书签的插件只在 `kDebugMode` 下放行（`allowDebugSigners: kDebugMode`），profile、release 一律拒：每台开发机都有调试证书，谁都能拿来签。
3. **用户批准**：`PluginApprovalStore` 存 pluginId、包名、证书摘要、能力。放普通偏好：被人改了也只会让插件变「待批准」或「已拒绝」。**不存权限**，所以插件新版本多申请一项权限不会回到待批准——这是 compatibility.md 里写的已知缺口。
4. **每次连接**：`PluginBridge.connect`（`android/app/src/main/kotlin/top/xdwa/shun/PluginBridge.kt`）绑定前再读一次系统里的证书，必须**恰好等于**批准的那一张（多张证书签的包因此批不了），用显式组件绑定那个类；握手返回的描述符里 `pluginId` 要和批准的一致。
5. **每次回调**：`IShunHost` 的两个方法第一行都调 `verifier.requireTrustedCaller()`。`CallerVerifier`（`plugins/provider-sdk`）按 `Binder.getCallingUid()` 查包名、每次重新读证书、不缓存。所以插件把这个 Binder 转交给别的 App，对方也调不进宿主。插件那头反过来核对宿主证书，写法见 contract.md 第 4 节。

**插件拿得到什么**：只有它自己会话的字节流；Mosh 插件另外拿到这次会话的 IP、UDP 端口和 key。拿不到保险库、私钥、密码、别的主机和别的会话。想给插件开新能力或权限，先改 capabilities.md 和 contract.md，再动代码。

**换 Mosh 插件的签名**（包括以后换正式签名）必须同步改 `OfficialPlugins.moshTestAuthorCertSha256`，不然真插件会被当成冒充者拒掉。证书从安装包读：`$ANDROID_HOME/build-tools/36.0.0/apksigner verify --print-certs plugins/mosh/build/outputs/apk/release/mosh-release.apk`。现状有两点：

- 登记的是测试作者证书，这把钥匙（仓库外 `../.toolchain/plugin-keys/fixture-author.jks`）同时给 `plugins/fixture-*` 测试插件签名。用它签、又自称 `shun.mosh` 的包能过这道关（文件注释写明的局限），挡得住的只是别的钥匙签的冒充者。
- 这把钥匙 2026-10-15 在本机重新生成过，2026-10-17 所有者决定改认新钥匙：登记的证书从 `ffb53d5a…` 换成 `7feb5825…`。用旧钥匙签的 Mosh 插件包从此被当成冒充者拒掉。

## 7. Mosh

为什么选官方 mosh-client、为什么做成独立插件，见[Mosh 运行时选择](../decisions/mosh-runtime-decision.md)；连接的整个流程见[架构第 3 节 Mosh](architecture.md#mosh)；用户侧见[Mosh 使用指南](../user/mosh.md)。这里只讲路线限制和 key 怎么保管。

**只走直连**：`moshRouteProblem`（`lib/domain/plugins/mosh_route.dart`）。Mosh 先用 SSH 在服务器上拉起 mosh-server，之后整个会话走 UDP；SOCKS5 和 HTTP 代理的 CONNECT、跳板机的端口转发都只转 TCP，承载不了这段 UDP。所以不是直连就在任何网络动作之前拒绝：编辑器不让保存，连接时抛 `MoshRouteUnsupported`，一个连接都不拨，也不改成直连绕过用户选的路线。

**UDP 发去哪**：`SshService.bootstrapMosh` 取这次 SSH socket 的对端 IP（`MoshBootstrapOutcome.udpHost`）。主机名只由系统解析一次，SSH 和 UDP 去的是同一台；命令里的 `-s` 让 mosh-server 也只在这个地址上收。插件不做 DNS，Dart 侧的桥收到非数字 IP 直接拒。

**引导命令**：`MoshBootstrap.command`（`lib/domain/plugins/mosh_bootstrap.dart`）拼成 `sh -c '<写死的脚本>' shun '<端口范围>' '<mosh-server 路径或 auto>' '<locale>'`。用户能影响的只有这三个位置参数：路径必须 `/` 或 `~/` 开头、每段只有字母数字和 `._+-`、不能是 `.` 或 `..`、最长 200；locale 必须是 UTF-8 的写法；端口 1–65535。不装软件、不用 sudo、不重试；无 PTY，20 秒超时，输出最多 64 KiB。

**解析输出**：`MoshBootstrap.parse` 按字节解析，不转成字符串——Dart 字符串清不掉，key 进了字符串就一直留在堆里。必须**恰好一行**完整的 `MOSH CONNECT <端口> <22 个 base64 字符>`：两行都像就都不用（可能是 motd 或恶意服务器夹带的），端口不在请求的范围、key 不是规范的 base64、行中间夹 `\r`（能把后半行盖到前面伪装）都拒绝。报错只说类别。

**key 的路径**（每一站用完都清零）：

| 一站 | 做什么 | 代码 |
|---|---|---|
| SSH 输出缓冲 | 解析完 `fillRange` 清零 | `SshService.bootstrapMosh` |
| 宿主 Dart | `PluginMoshRuntime` 只找 `shun.mosh`，要已批准、声明了终端会话和「本会话的临时凭据」权限、支持直连；`PluginSessionManager.open` 再查一次权限，`finally` 里 `wipe()` | `lib/application/mosh_session.dart`、`plugin_sessions.dart` |
| 平台通道 | Dart 侧查 IP 是数字、key 是 22 字节；Kotlin 每条出错分支和 `always` 里 `key.fill(0)` | `android_plugin_bridge.dart`、`PluginBridge.kt` |
| 插件 Java | 校验后交给 `MoshSession.start`，`finally` 清零 | `plugins/mosh/src/main/java/top/xdwa/shun/mosh/` |
| 插件原生层 | 写进管道、关掉写端、清零缓冲；mosh-client 从继承的 fd 3 读 | `plugins/mosh/src/main/cpp/moshpty.c`，补丁 `plugins/mosh/native/patches/0002-key-from-inherited-fd.patch` |

不用官方的 `MOSH_KEY` 环境变量：mosh-client 读完虽然 `unsetenv`，进程活着期间 `/proc/<pid>/environ` 照样读得到。也不进命令行参数（`ps` 看得见）、不写文件、不进日志。清不到的：mosh-client 自己内存里那份（它要用）、dartssh2 解密用的缓冲（`_runBounded` 的注释写了），以及平台通道编码时的中间缓冲。

测试：`test/mosh_bootstrap_test.dart`（「toString 不带 key；wipe 之后 key 全 0、再取报错」）、`test/official_plugins_test.dart`、`test/mosh_session_test.dart`；真 mosh-server 上的是 `test/mosh_fixture_test.dart`，要先 `tool/mosh-fixture/up.sh`。

## 8. 会在服务器上执行命令的功能

**通用做法**，新加这类功能照着来：

- 走 exec 通道（SSH 里单独执行一条命令的通道，不开交互 shell，不进 shell 历史），不往用户正在用的终端里打字。
- 脚本写死，用户能影响的只有位置参数：`sh -c '<脚本>' shun '<参数>' …`。参数先过白名单再加单引号；脚本本身不能有单引号、`!`、连续两个反斜杠、换行和回车（`isPortableScript`：登录 shell 可能是 fish、csh，这些字符在那里会被改写）。
- 名字这类自由文本从 stdin 传，不进命令行。
- 输出有上限、有期限；失败了不换个法子凑合（不按名字找替身、不改用 home 目录）。

| 功能 | 在服务器上做什么 | 谁来点 | 边界 |
|---|---|---|---|
| 启动命令 | 新连接时往 shell 写一次 `命令\n` | 用户自己填的 | 只在 `ConnectionPurpose.fresh` 且不是 AI 启动时写；恢复、测试连接都不写 |
| 断线恢复 | 开新 shell | 自动，只对网络错误（[手册第 7 节](../user/README.md#7-断线后台与恢复)） | 恢复期间的输入直接丢；断线前发过输入就标 `inputResultUnknown`（界面「结果未知」），用户点「已核查」才清 |
| 测试连接 | 带 PTY 的 exec 跑一次 `tty`，再只读查一次 tmux | 用户点 | `SshService.probe` 不开 shell、不跑启动命令 |
| tmux 面板 | `lib/infrastructure/tmux/tmux_protocol.dart` 里的固定脚本 | 结束会话、改鼠标要确认 | 按会话 ID（`$3`）定位，先核对 uid、socket、server 代次；新名字不收 `#`（tmux 会执行 `#(命令)`）；附着走带 PTY 的 exec |
| AI 命令行检测 | `exec /bin/sh -s`，脚本从 stdin 进 | 打开工具面板 | 只做文件检查、读相邻 package.json，**不执行发现的工具**（连 `--version` 都不跑）；10 秒、64 KiB、最多 64 个 |
| AI 命令行启动 | 新标签里带 PTY 的 exec：`cd` 目录、核对可执行、`exec` 工具 | 「新建终端」要填目录确认 | 不往已有终端写字节；每个请求 ID 只能用一次；15 秒内等不到就绪标记就算失败 |
| Mosh 引导 | 第 7 节的固定脚本 | 点连接 | 不装、不 sudo |
| 缺 mosh-server | `head -c 4096 /etc/os-release` | 引导失败时自动 | 远端内容只用来在写死的表里选命令（`mosh_install_hint.dart`），一个字都不进命令 |
| 安装 mosh | 新开一次性 SSH 标签，把写死的安装命令当启动命令跑一次（用户侧见 [Mosh 使用指南第 2 节](../user/mosh.md#2-在服务器上装-mosh-server)） | 「安装…」再过确认框 | 2026-10-17 所有者同意加的；非 root 用户的命令带 `sudo`，密码用户在那个终端里自己输；一次性标签恢复不重跑、App 被杀后不放回 |
| AI 助手（默认关） | 往打开助手时那条连接粘贴 AI 给的命令 | 「执行」要过确认框 | 拒 Tab、换行、回车以外的 C0 控制字符和 DEL，拒脱敏占位符；只粘贴不执行时还拒多行；不走 `PasteReview` |
| 命令片段 | 往当前标签按粘贴发 | 点片段就发 | 过 `PasteReview.of`；勾了「自动运行」才回车 |

AI 命令行的「按会话 ID 继续」「同项目新建」点一下就启动，不再弹确认框。AI 助手的终端上下文默认不发（`aiIncludeTerminalContext` 默认 false），发的话最多 80 行、12 000 字符（`terminalAiContextText`），并先过 `redactAiText`。

**系统管理**（`lib/infrastructure/ssh/system_management_service.dart`）：命令都经 `_executeSession` 走 exec，默认 15 秒；参数用 `shellQuote` 包单引号，PID 必须大于 0，容器和镜像 ID 只收字母数字，服务名只收字母数字和 `_.:@+-`，Caddyfile 的内容先 base64 再在远端解码，改之前备份、校验、失败回滚。现状里要知道三件事：

- **确认框**：会中断、删除或下次开机才发现的操作都先确认——进程 KILL/TERM/STOP；容器 stop/restart/pause、强杀、删除；镜像删除；Compose 的 stop/restart/pause/update/recreate/rebuild/down；服务的 stop/restart/disable；删 Caddy 站点。点了就执行的只剩不中断什么的：进程 CONT、容器 start/unpause、Compose start/unpause/pull、服务 start/enable、拉镜像、改优先级（本身有输入框）。新加的操作只要会中断服务就要确认：手机上误触很常见，停的要是 sshd，用户就连不回来了。测试：`test/system_management_confirm_test.dart`。
- **sudo 先问用户**：命令报权限错时，服务层不自己试 sudo，抛 `SudoRequired`（`passwordOptional: true`）；界面由 `runWithSudo`（`lib/presentation/widgets/system_management/sudo_prompt.dart`）弹「用 sudo 再试？」，用户点了「用 sudo 继续」（密码可空）才调 `set*SudoPassword` 记下同意，之后先试 `sudo -n`，要密码再问。同意按 Docker（含 Compose）、系统服务、Caddy 分开记，和密码一样只存在这个面板的 `SystemManagementService` 实例里；密码经 stdin 交给 `sudo -S -p ''`。以前一碰到权限错就自动试 `sudo -n`，免密 sudo 的机器上直接以 root 执行了。新加会提权的入口也走 `runWithSudo`，别在服务层自己重试。测试：`test/system_management_sudo_test.dart`。
- `_executeSession` 拿不到退出码时按 0（成功）算。

测试：`test/integration_ssh_fixture_test.dart`（「REG02 / NET11 断线恢复不重跑 startup、不重放输入」）、`test/tmux_protocol_test.dart`、`test/tmux_fixture_test.dart`、`test/ai_cli_discovery_test.dart`（「AIC01 actual POSIX discovery, without executing any CLI」）、`test/ai_cli_launch_ssh_fixture_test.dart`、`test/mosh_install_hint_test.dart`、`test/system_management_service_test.dart`、`test/system_management_sudo_test.dart`、`test/system_management_confirm_test.dart`、`test/ai_chat_sheet_test.dart`。

## 9. 网络与路由

- **一条路线**：每次连接前由 `resolveRoutePlan`（`lib/domain/connection_route.dart`）算出一份 `RoutePlan`，配置有问题就在拨号前抛 `RouteConfigException`，不退回直连；规则逐条见[架构 2.4](architecture.md#24-routeplan拨号前一次算好的路线)，用户侧见[手册第 3 节](../user/README.md#3-连接路径直连经代理经跳板机)。安全上要记的是：终端、SFTP、监控、系统管理、端口转发都借这一条已核过指纹的连接，不另拨。测试 `test/route_plan_test.dart`、`test/route_fail_closed_test.dart`。
- **谁拨号**：只有第一跳由手机拨（`Socket.connect`，走系统网络和用户自己开的 VPN）；后面每一跳是上一跳 SSH 的 `forwardLocal(next.host, next.port)`。
- **DNS**：`Endpoint` 只做语法检查，不解析。经 SOCKS5 时域名按地址类型 3 原样交给代理解析，经 HTTP 代理时把 `主机:端口` 交给代理，经跳板时由上一跳解析下一跳——这些情况手机都不查目标名。手机自己解析的只有：直连的目标名、代理本身的地址；Mosh 的 UDP 直接用 SSH 连上的 IP，不再解析。中文域名不自动转 Punycode：转换规则有多个版本，转错就连到另一台，所以直接拒绝，让用户填 `xn--` 写法。
- **SOCKS5 不降级**：配了用户名就只提供「用户名密码」一种认证方式，代理回「无认证」就拒绝（`_socks5`，`lib/infrastructure/transport/proxy_transport.dart`）；没配就只提供无认证。代理口令在网络上是明文，SSH 保护不了它（手册第 3 节写了）。测试 `test/socks5_hardening_test.dart`。
- **Tailscale API**：`tailscaleApiOrigin` 写死 `https://api.tailscale.com`，不从设置或导入文件读；请求 `followRedirects = false`，跟了重定向就会把 Authorization 头或 client secret 带到对方指定的任何地方。
- **管不住的**：插件、UU 远程、RustDesk 自己联网，不走宿主的路线（contract.md 第 7 节，手册第 15、16 节）。
- **默认不外连**：AI、云同步、检查更新都由 `ForkFeatures` 默认关掉，`test/fork_features_test.dart`「默认开关下冷启动、打开设置、后台恢复都不发网络请求」钉着。
- Android 清单 `usesCleartextTraffic="false"`，没有自定义 `networkSecurityConfig`。

## 10. 提交前检查

**不许进仓库**：

- 真实的账号、主机地址和 IP（包括 tailnet 的 100.x）、主机指纹、token、API Key、OAuth client secret、私钥。
- 签名文件：`*.jks`、`*.keystore`、`key.properties`、`signing.properties`。`android/` 下忽略了 `*.jks`、`*.keystore`、`key.properties`，`plugins/example/` 下忽略了 `*.jks`、`*.keystore`、`signing.properties`；**根目录和 `plugins/mosh/` 都没忽略**，放错地方 git 照样收。插件签名钥匙放仓库外的 `../.toolchain/plugin-keys/`。
- 测试环境生成的 `.run/` 目录（`tool/fixture-environment`、`tool/mosh-fixture`、`tool/tmux-fixture`、`tool/ai-cli-fixture`、`tool/tailscale-ssh-fixture` 下都已忽略，别强加）。
- 带 `--dart-define=R17_SSH=…`、`X09_MOSH=…` 编出来的测试 APK：里面有测试环境的密码。
- 导出的保险库 JSON：没凭据，但有主机名、用户名、路线、指纹、启动命令、环境变量。
- 没处理过的截图和设备日志：先放 `../.toolchain/artifacts/`；要写进 `plan/v3/evidence/` 的，先确认没有真实 IP、主机名、指纹、token、UU 或 RustDesk 的 ID。

**仓库里那些测试凭据为什么不算泄漏**：

- 单元测试里的是一眼看得出的假值，比如 `test/vault_secrets_test.dart` 的 `KEY-MATERIAL-0e8f`、`tool/sec05/seed_main.dart` 的 `SEC05-HOST-PW-7f1c`。故意做成特征串，在哪儿搜到它就说明哪儿漏了。
- 集成测试的密码、客户端私钥、服务器主机密钥每次 `up.sh` 现生成，写进 `.run/fixture.json`，测试运行时由 `test/fixtures/docker_fixture.dart` 读；容器端口只绑 127.0.0.1，`down.sh` 删掉。所以仓库里没有，换一次就全变。
- 公开的不用藏：证书 SHA-256（`official_plugins.dart` 和 compatibility.md 里的那几串）、GitHub device flow 的 `client_id`。

**提交前跑一遍**：

```bash
# 暂存区里有没有像秘密的东西（会有误报，逐条看）
git diff --cached | grep -nE 'BEGIN [A-Z ]*PRIVATE KEY|ghp_|github_pat_|sk-[A-Za-z0-9_-]{16,}|tskey-|AKIA[0-9A-Z]{16}'
# 有没有签名文件、测试环境产物
git diff --cached --name-only | grep -E '\.(jks|keystore|p12)$|(key|signing)\.properties$|/\.run/'
```

动了本文涉及的代码，至少跑下面这组（环境变量没配好、少了 `NO_PROXY` 时全部在 loading 阶段失败，见[本机手册第 1 节](README.md#1-mise-固定-zig再-source-环境)）：

```bash
flutter test --no-pub test/vault_secrets_test.dart test/vault_unreadable_secrets_test.dart \
  test/secure_storage_file_names_test.dart test/host_trust_test.dart test/netcatty_crypto_test.dart \
  test/terminal_remote_effects_test.dart test/terminal_links_test.dart test/terminal_paste_review_test.dart \
  test/mosh_bootstrap_test.dart test/official_plugins_test.dart test/route_fail_closed_test.dart \
  test/socks5_hardening_test.dart test/fork_features_test.dart
```

动了连接、tmux、Mosh 的，再跑对应的真实环境测试（`integration_ssh_fixture_test.dart`、`tmux_fixture_test.dart`、`mosh_fixture_test.dart`，起环境的方法见[本机手册第 2 节](README.md#2-测试)）。环境没起、自动跳过的不算通过。改了用户看得到的行为，同一个提交里改[使用手册](../user/README.md)。
