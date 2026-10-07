# 接口约定（插件 API 1.0）

宿主和插件之间只有四样东西：清单里的**服务声明**、一份**描述符** JSON、一个 **AIDL 接口**（控制：握手、开关会话、改尺寸），
加上每个会话一条 **socket 字节流**（终端数据）。没有别的通道：插件拿不到宿主的保险库、私钥、密码、别的主机或别的插件的会话，
宿主也不给插件执行命令、读文件、转发 Intent 的接口。

契约代码只有一份：`plugins/provider-sdk`（AIDL 在 `src/main/aidl/top/xdwa/xwshun/plugin/v1/`）。下面的数字都取自那里和宿主的实现，改了以那里为准。

## 1. 清单里要有什么

照 `plugins/example/app/src/main/AndroidManifest.xml`：

| 要求 | 不满足时宿主怎么说 |
|---|---|
| 一个服务，带 `<action android:name="top.xdwa.xwshun.plugin.action.PROVIDER_V1" />` | 列表里根本没有你（宿主只查这个 action，不申请「查看全部应用」）|
| 这个服务 `android:exported="true"` | 「不兼容：插件服务没有导出，宿主无法绑定」 |
| 一个 App 里**只有一个**这样的服务 | 「不兼容：一个安装包声明了 2 个插件服务，只允许一个」 |
| 服务上 `<meta-data android:name="top.xdwa.xwshun.plugin.DESCRIPTOR" android:resource="@raw/…" />` 指向描述符 | 「不兼容：插件服务没有声明 top.xdwa.xwshun.plugin.DESCRIPTOR」 |
| 服务**不设** `android:permission` | 宿主绑不上。独立签名的插件没法用 signature 权限认宿主，认人放在每个调用里（第 4 节） |
| `<queries><package android:name="top.xdwa.xwshun" /></queries>` | API 35 模拟器上去掉也能握手（宿主绑定插件时系统自动让插件看见宿主），样例照写，原因见清单注释 |
| 可选：一个导出的 Activity，带 `top.xdwa.xwshun.plugin.action.SETTINGS_V1` 和 `DEFAULT` category | 声明了多个时宿主不给入口，不替你挑 |

设置页：宿主详情页的「打开插件的设置页」用显式组件打开它，**不带任何 extras**。只有「可用」的插件才有这个入口。
设置存在插件自己的存储里，宿主看不到。它是导出的 Activity，任何 App 都能打开，别在里面放只该给宿主看的东西。

## 2. 描述符

放在 `res/raw/` 下的一个 JSON 文件。宿主批准之前**只读它**，不启动你的代码。结构定义：`plan/v3/contracts/plugin-manifest.schema.json`。

| 字段 | 必填 | 规则 | 样例里的值 |
|---|---|---|---|
| `schemaVersion` | 是 | 只能是 `1` | `1` |
| `pluginId` | 是 | `^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$`，≤128 字符。`builtin.` 开头的归宿主。和设备上别的已可用插件重复会被拒 | `example.hello_terminal` |
| `displayName` | 是 | 1–80 字符，不含控制字符 | `Hello 终端（样例）` |
| `version` | 是 | `x.y.z`，≤32 字符。建议和 `versionName` 一致 | `0.1.0` |
| `apiMajor` | 是 | 只能是 `1` | `1` |
| `apiMinor` | 是 | 0–999，见 [compatibility.md](compatibility.md) | `0` |
| `deployment` | 是 | 单独安装的插件写 `android-service`。`bundled` 是宿主自带的，单独安装的包写它会被拒；`external-app` 指 UU、RustDesk 那种外部 App | `android-service` |
| `capabilities` | 是 | 至少一个，不重复。现在宿主只会用第三方插件的 `terminal-session`。`route` 只许宿主自带的写 | `["terminal-session"]` |
| `supportedRoutes` | 是 | 至少一个：`system-default`、`socks5-connect`、`proxy-jump`、`socks5-proxy-jump`、`provider-managed`。终端插件写 `system-default` | `["system-default"]` |
| `platforms` | 是 | `android-service` 只能是 `["android"]` | `["android"]` |
| `permissions` | 是（可为空） | 0–8 个，只能从下表选 | `["own-session-input-output"]` |
| `packageName` | `android-service` 必填 | 等于你的 applicationId，≤180 字符 | `example.xwshun.hello` |
| `serviceClass` | `android-service` 必填 | 声明插件 action 的那个服务的全名，≤220 字符 | `example.xwshun.hello.HelloProviderService` |
| `license` | 否 | ≤100 字符，建议用 SPDX 写法 | `GPL-3.0-or-later` |
| `sourceUrl` | 否 | 只许 `https://`，≤1024 字符 | 样例没写 |

- **多一个字段就整份拒绝**（「不允许的字段：…」）：任意命令、Intent、回调地址只能从多出来的字段混进来，所以字段集合是封闭的。
- 整个文件 ≤16 KiB（「描述符超过 16 KiB」）。
- **描述符里没有证书字段。** 宿主只认系统从安装包里读出的签名证书；插件自己说什么都不算。

权限（集合是封闭的，没有保险库、私钥、口令、token、执行命令、文件、剪贴板这类东西）：

| 权限 | 宿主界面上的名字 | 用不用 |
|---|---|---|
| `own-session-input-output` | 本会话的输入输出 | 终端插件写它。宿主现在只在批准框、详情页显示，不写不会被拒，但用户看不出你要收发会话数据 |
| `own-session-ephemeral-secret` | 本会话的临时凭据 | 只有 Mosh 插件用得上（宿主只把 Mosh 的一次性密钥交给 pluginId 为 `xwshun.mosh` 的插件）。别的插件写了什么也拿不到，还会让用户以为你要凭据，别写 |
| `user-initiated-external-launch`、`own-provider-state`、`device-catalog-read` | 由你点击后打开外部 App / 插件自己的状态 / 读设备目录 | 第三方插件现在用不上 |

## 3. AIDL 接口

插件实现 `IXwshunProvider`，宿主握手时交给插件一个回调 `IXwshunHost`。

| 方法 | 谁调、什么时候 | 插件要做什么 |
|---|---|---|
| `String handshake(int hostApiMajor, int hostApiMinor, IXwshunHost host)` | 宿主每次连接（「连接测试」「会话测试」开始时）先调它 | 认人；核对版本（不接受就抛 `IllegalStateException`，话里写清楚要哪个版本）；记下 `host` 并 `linkToDeath`；**返回清单里那份描述符**（宿主核对其中的 `pluginId` 和批准的一致） |
| `long ping(long nonce)` | 连接测试 | 认人；原样返回 `nonce` |
| `void openSession(String handle, long generation, int cols, int rows, ParcelFileDescriptor stream)` | 开会话 | 认人；用 `ProviderSessions.open(handle, uid, generation, …)` 记下；在**自己的线程**里开始读写 `stream`，先回报 `active`；立即返回 |
| `void resizeSession(String handle, long generation, int cols, int rows)` | 终端尺寸变了 | 认人；`ProviderSessions.require` 核对；记下新尺寸；回报 `resized:COLSxROWS`。别在这里写 `stream`（可能阻塞 Binder 线程） |
| `void closeSession(String handle, long generation)` | 宿主关会话（**它已经先关了自己那端**，不等你返回） | 认人；`ProviderSessions.remove`；关掉流，会话线程回报 `closed`。重复调用、不存在的会话直接返回 |
| `void openMoshSession(…, String udpHost, int udpPort, byte[] printableKey)` | 只有 Mosh 插件会被调 | **不做 Mosh 也要实现**（AIDL 里有它）：把 `printableKey` 清零、关掉 `stream`、抛 `UnsupportedOperationException` |

宿主回调（都是 `oneway`，调用不会阻塞你的线程）：

| 方法 | 用途 |
|---|---|
| `onProviderEvent(long generation, long sequence, String event)` | 插件级事件，比如握手后报一个 `ready`。宿主插件页「事件」里显示「插件回报 · 包名 · ready（序号 1）」。`sequence` 每次连接从 1 递增，不递增的丢掉 |
| `onSessionEvent(String handle, long generation, long sequence, String state)` | 会话状态，见第 5 节 |

两个回调的字符串都 ≤64 字符，超了直接丢。

## 4. 认人：每个方法第一行

```java
int uid = verifier.requireTrustedCaller();   // CallerVerifier(context, "top.xdwa.xwshun", {宿主证书 SHA-256})
```

- 它用 `Binder.getCallingUid()` 查出调用方的包名，再从系统读这个包**当前**的签名证书，必须是你在 `xwshunHostSha256` 里写的那张。
  不是就抛 `SecurityException`，宿主那边显示「插件拒绝了宿主：…」。
- **为什么不能只在 `onBind` 查**：宿主绑定你之后，别的 App 用同样的 Intent 去绑，系统直接把同一个 Binder 给它，`onBind` 根本不会再被调用（X02 在模拟器上实测）。
- **别信 Intent 里的任何东西**：extras 里的「调用方包名」之类是对方随便写的。
- 要在任何 `Binder.clearCallingIdentity()` 之前调。每次都重新读证书，不缓存：包可能被卸载后换一张证书装回来。
- 反过来，宿主也在每个回调里核对调用方是不是批准过的那个插件、证书是不是批准时那张。你把 `IXwshunHost` 转交给别的 App，它也调不进宿主。

## 5. 会话：字节流和状态

**字节流**：宿主建一对 socket，自己留一端，另一端作为 `openSession` 的 `stream` 交给你。终端数据只走这里，不经 Binder。

| 方向 | 是什么 | 注意 |
|---|---|---|
| 你读到的 | 用户的输入，终端原样字节 | 回车是 `\r`（0x0d），退格是 0x7f，方向键是 `ESC [ A` 这类序列；中文是 UTF-8，一个字可能被拆在两次 `read` 里 |
| 你写的 | 终端要显示的东西 | 换行写 `\r\n`。只写 `\n` 在真终端上下一行不回行首（会话测试里标成 `^J`）。颜色、光标用 ANSI 转义序列 |
| 读到 EOF | 宿主关了它那端 | 清理，回报 `closed` |

**状态**（`onSessionEvent` 的 `state`）：

| state | 什么时候发 | 宿主怎么处理 |
|---|---|---|
| `active` | 开始收发之后，先发它 | 会话测试显示「插件回报：运行中（active）」。不发的话一直停在「打开会话」 |
| `resized:COLSxROWS` | 收到 `resizeSession` 后 | 会话测试显示「插件确认尺寸 100x30」；2 秒没收到显示「2 秒内没收到插件的 resized 回报」 |
| `closed` | 会话结束、流已关 | 宿主在关时收到：「已关闭：插件确认已停止（closed）」；你自己结束：「已关闭：插件自己结束了会话（closed）」 |
| `failed:<原因>` | 你这边的运行时出错退出了 | 记下原因，会话按「中断」收尾 |

- `ProviderSessions` 把句柄、调用方 UID、代次绑在一起，三样都对上才放行；「没有这个会话」和「是别人的会话」给同一句错误，免得被拿来探测别人的句柄。
- `sequence` **每个会话从 1 开始递增**；`generation` 原样用宿主给的。代次不对、序号不增的事件宿主直接丢，已关的会话不会被迟到的 `active` 复活。
- **插件自己结束会话的顺序**：写完最后的输出 → 关流 → 回报 `closed`。宿主读到 EOF 后等 300 ms，等到 `closed` 记「已关闭」，等不到记「中断：插件关了它那一端，没有先回报 closed」。
- **宿主关会话**：先关自己那端，再调 `closeSession`，不等返回；2 秒内收到 `closed` 才算「插件确认已停止」，否则记「停止未确认」。

**上限和背压**（宿主这边的数字）：

| 项 | 值 | 超了会怎样 |
|---|---|---|
| 会话句柄 | `^[A-Za-z0-9-]{1,64}$`，宿主生成（现在是 UUID）| `ProviderSessions.open` 拒绝 |
| 你的会话数 | 你自己定（`new ProviderSessions<>(上限)`，样例是 4） | 宿主显示「插件拒绝：会话数已到上限」 |
| 宿主压着不读的输出 | 4 块未确认 + 手里 1 块，每块 ≤16 KiB | 宿主停读，你的 `write` 阻塞——所以读写要在自己的线程 |
| 宿主替你排队的输入 | 1 MiB | 你不读输入，再写就失败：「插件没有及时读取，输入积压超过上限」 |

**线程**：三个会话方法都要立即返回，读写放在会话自己的线程。关流之前先 `Os.shutdown(fd, SHUT_RDWR)`：只 `close` 叫不醒阻塞在 `read` 上的线程。

**宿主进程死了**：握手时对 `IXwshunHost` 做 `linkToDeath`，回调里 `ProviderSessions.dropOwner(uid)` 拿到它开的全部会话、逐个关掉。
模拟器上看到：插件进程没有会话、被系统冻结时，死亡通知要等它下次被唤醒才到。

**插件进程死了**：宿主把它的会话记成「中断：插件进程没了」，不会自动重连。

## 6. 出错时抛什么、宿主显示什么

| 在哪抛 | 抛的 | 宿主显示 |
|---|---|---|
| 任何方法 | `SecurityException`（`CallerVerifier` 抛的） | 「插件拒绝了宿主：…」 |
| `handshake` | `IllegalStateException` | 「连接失败：插件不接受宿主的 API 版本：<你的原话>」 |
| `handshake` | 别的运行时异常（`UnsupportedOperationException` 等） | 「连接失败：插件握手出错：<异常类名> <原话>」。**X12（2026-10-07）之前编的宿主会整个崩掉**，所以握手里只抛 `IllegalStateException` |
| `handshake` | 返回的描述符 `pluginId` 和批准的不同 | 「插件握手时自称 X，与批准的 Y 不符」 |
| 其他方法 | `IllegalStateException`、`IllegalArgumentException` | 「插件拒绝：<原话>」 |
| 其他方法 | 别的运行时异常 | 「插件出错：<异常类名> <原话>」 |
| 任何方法 | 进程在调用中死了 | 「插件进程已不在」「握手时插件进程退出」 |

只用上面这几种异常。Binder 只把 `SecurityException`、`IllegalArgumentException`、`IllegalStateException`、`NullPointerException`、
`UnsupportedOperationException` 等少数几种原样带回调用方，别的类型带不回来。不支持的事就明确抛，**别返回假成功、空结果**。

## 7. 宿主保证什么、不保证什么

保证：

- 批准之前不启动你的代码；只用显式组件绑定你声明了 action 的那个服务；每次连接前再核一次证书仍是批准时那张。
- 证书变了（换签）、描述符多申请了能力、`apiMajor` 变了，都会停下来让用户重新核对，不自动扩大批准。
- 你的插件出错（抛异常、进程死掉）只影响它自己的会话，宿主和别的会话照常。

不保证、也管不了：

- **你的插件是独立的 App，有它自己的系统权限。** 宿主管不住它自己联网；描述符的 `supportedRoutes` 是兼容约定，不是防火墙。详情页会把这一点告诉用户。
- 你的插件看得到它自己会话里的全部数据（用户敲的每个键、屏幕上的每个字）。
- 宿主不替你保存设置、不替你更新、不下载任何东西。

## 8. Dart 那一半（`packages/plugin_api`）

宿主用它判定插件能不能用：描述符解析（`PluginDescriptor.parse`）、准入（`AdmissionPolicy`）、路线判定、会话状态。
你写插件用 Java/Kotlin，**不需要**它；唯一用得上的是构建前自查（README 第 4 步），它跑的就是宿主这套代码，报的话一字不差。
