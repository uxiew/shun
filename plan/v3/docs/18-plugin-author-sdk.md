# 18 插件作者SDK与实施交接

## 最小作者交付

一个可独立编译的示例Android provider APK、一份薄AIDL契约和Dart adapter说明、manifest描述符schema、错误/状态语义、兼容和签名测试。SDK只含本产品新写的接口与样例；不得把GPL/AGPL实现代码复制进标注宽松许可的SDK。正式SDK许可由所有者确认；建议与具体运行时许可证分离管理。

## 作者需要遵守的语义

`TerminalSessionProvider`拥有本次终端session，接口为typed open/resize/close；输入输出走FD。`DeviceCatalogProvider`只返回来源明确的设备；`RemoteDesktopProvider`明确是external launch或embedded surface。不得创建一个带任意shell/文件/Intent能力的万能plugin API。

描述符使用`contracts/plugin-manifest.schema.json`；示例值均是占位，不是已签名包。SDK兼容矩阵记录host API major/minor、插件版本、Android API/ABI及实际签名来源。不可用能力返回unsupported，不能伪装为空列表/成功或绕过指定route。

签名流程：插件验证真实宿主caller UID及证书，宿主验证安装包证书与用户授权；独立作者无需共享宿主签名私钥。发行签名变化需要明确更新信任，不可把debug包签名自动用于正式发行。每次session使用不透明owner handle和generation，避免被别的caller/旧实例接管。

## 合规与分发

APK通过用户明确安装，Play渠道用其受支持分发路径；侧载渠道独立给源码、hash、证书和更新说明，不自动下载安装、不申请无关安装权限。native必须随提供方APK打包，不能下载运行代码到宿主；不能照用低targetSdk或假FGS规避平台要求。[S49](13-sources.md#s49) [S50](13-sources.md#s50) [S54](13-sources.md#s54)

## 必需样例与测试

- Echo provider仅在debug fixture包，用于字节分片/resize/取消/崩溃测试；产品不把它当Mosh实现。
- 最小真实Mosh provider验证完整bootstrap、UDP、VT输出和生命周期。
- 同pluginId但不同证书的伪装包，API major不符包，拒绝关闭包和低速流包。
- 未授权caller不得读取描述符以外敏感数据，更不得获得session；每个敏感方法独立授权。
- provider被杀、更新、卸载、宿主被杀时资源有界，秘密不进入日志/备份，撤销不伤害其他SSH会话。

## 调试方法

按pluginId/sessionId/generation关联双方脱敏事件，不记录原始Mosh key、SSH凭据、UU ID或完整屏幕。终端材料用合成VT fixture；每个bug保留输入分片/状态序列和版本，不用生产终端记录做自动回归。

Android实机需记录主App与插件APK SHA-256、signer SHA-256、API/ABI/页面大小、FGS行为与外部App版本。没有真机就标NOT_RUN，Echo成功不等于Mosh成功，UU Intent启动成功不等于远控成功。

## 首批插件模型提示词

```text
读取AGENTS、docs/15、docs/16、docs/17、docs/18和tasks.json。
执行X00–X03中依赖满足的部分，先做最小registry与独立测试APK/IPC；
不要实现插件商城、Dart热加载、外部native下载或任意exec。
主App沿用Flutter/Netcatty，Kotlin限Android桥和服务，不迁回Compose/SSHJ。
逐次Binder事务校验UID+签名+owner+generation；流走FD，有背压、取消、death。
记录哪些是mock、哪些是APK真实运行；不领取缺授权的生产连接。
同步任务、测试和证据，提交可回滚小变更。
```

## X02 已落地的最小接口（2026-09-30）

契约代码只有一份：`plugins/provider-sdk/`（纯 Java + AIDL，可直接作为 Android 库引用）。构建与测试插件的用法见 `plugins/README.md`。

| 项 | 值 |
|---|---|
| 服务 action | `top.xdwa.xwshun.plugin.action.PROVIDER_V1`（宿主 `<queries>` 只查它） |
| 描述符 | 服务上的 meta-data `top.xdwa.xwshun.plugin.DESCRIPTOR`，指向 raw 资源，≤16 KiB；`packageName`、`serviceClass` 必须等于实际安装包和声明 action 的那个服务 |
| 一个包 | 只能有一个声明该 action 的服务，多于一个整包判为不兼容 |
| 服务 | `exported="true"`，不设 `android:permission`（独立签名没法用 signature 权限认宿主） |
| AIDL | `IXwshunProvider.handshake(hostApiMajor, hostApiMinor, IXwshunHost)` 返回描述符 JSON；`ping(nonce)`。宿主回调 `IXwshunHost.onProviderEvent(generation, sequence, event)`（oneway，event ≤64 字符） |
| 认人 | 每个方法第一行 `new CallerVerifier(ctx, "top.xdwa.xwshun", {宿主证书 SHA-256}).requireTrustedCaller()`；不在 onBind 查，不看 Intent extras |

**为什么不能只在 onBind 查**（模拟器实测）：宿主已绑定插件后，另一个 App 用相同 Intent（extras 不参与比较）去绑，系统直接把**同一个 Binder** 交给它，插件的 onBind 根本不会再被调用。

### 终端会话（X03 补齐，仍是 v1.0）

| 项 | 约定 |
|---|---|
| 方法 | `openSession(handle, generation, cols, rows, ParcelFileDescriptor stream)`、`resizeSession`、`closeSession`；宿主回调 `onSessionEvent(handle, generation, sequence, state)`。只在接口末尾追加，已有方法的事务号不变 |
| handle / generation | 宿主生成；插件用 SDK 的 `ProviderSessions` 把它们和调用方 UID 绑在一起，三者都对上才处理。「不存在」和「是别人的」给同样的错误，免得被拿来探测 |
| 字节流 | 宿主建 socketpair、自己留一端，另一端通过 `openSession` 交给插件。终端字节只走这里，不经 Binder。读到 EOF 表示宿主关了，插件随之清理 |
| 状态 | `active`（可以收发了）、`resized:COLSxROWS`、`closed`（插件已停止）、`failed`。每个会话的 sequence 从 1 递增 |
| 关闭 | 宿主先关自己那端，再调 `closeSession`，不等返回。2 秒内收到插件的 `closed` 才算确认停止，否则宿主记「停止未确认」 |
| 背压 | 宿主最多压着 4 + 1 块 × 16 KiB 输出不读、替插件排最多 1 MiB 输入，再多就拒绝写入。插件的 write 会阻塞，要放在自己的线程 |
| 宿主死亡 | 插件对 `IXwshunHost` 做 `linkToDeath`，宿主进程死了就关掉它开的全部会话（`ProviderSessions.dropOwner`） |
| 线程 | 三个会话方法都要立即返回，长操作放插件自己的线程；关 FD 前先 `Os.shutdown`，只 `close` 叫不醒阻塞在 read 上的线程 |

插件作者要做的：用自己的密钥签名；把宿主发行证书的 SHA-256 写进插件；在每个方法里调 `requireTrustedCaller`。宿主这边由用户在「设置 → 插件（实验）」里核对证书后批准。
宿主换了发行证书，插件要发新版本信任新证书；插件换了密钥，用户要重新批准。

