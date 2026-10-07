# 出错了怎么查

按你看到的那句话找。标「实测」的是 X12 在 Android 15（API 35）arm64 模拟器上真撞出来的；没标的话取自宿主代码里的原句，没专门复现。

先看日志：

```bash
adb logcat -s XwshunHello XwshunPlugins AndroidRuntime:E
#   XwshunHello：样例插件自己的 TAG，换成你的
#   XwshunPlugins：宿主的插件桥，丢掉的事件、拒绝的调用记在这里
#   AndroidRuntime:E：谁崩了（FATAL EXCEPTION 下面是调用栈）
```

## 构建时

| 看到的 | 原因 | 怎么办 |
|---|---|---|
| `Unable to locate a Java Runtime`（实测） | 没装 JDK，或没在 PATH / `JAVA_HOME` 上 | 装 JDK 17。项目这台 Mac 上 `source /Users/fodelf/xdw/xwshun/.toolchain/env.sh` |
| `SDK location not found. Define a valid SDK location with an ANDROID_HOME environment variable…`（实测） | 没告诉 Gradle Android SDK 在哪 | `export ANDROID_HOME=<SDK 目录>`，或在工程根目录建 `local.properties` 写 `sdk.dir=<SDK 目录>` |
| `xwshunHostSha256 没填或格式不对：…`（实测） | `gradle.properties` 里没写宿主证书，或不是 64 位十六进制 | README 第 3 步。冒号可有可无，大小写都行 |
| `缺签名配置 …/signing.properties：…`（实测） | 没建签名配置 | README 第 2 步，`cp signing.properties.example signing.properties` 再填 |
| `密钥库不存在：…`（实测） | `storeFile` 路径不对。相对路径是相对 `signing.properties` 所在目录算的 | 写绝对路径或 `~/` 开头 |
| `…signing.properties 里缺 storePassword` | 少填了一项 | 四项都要：`storeFile`、`storePassword`、`keyAlias`、`keyPassword` |
| `KeytoolException: Failed to read key plugin from store "…": keystore password was incorrect`（实测） | `storePassword` 不对 | 用生成密钥时设的密码 |
| `找不到 provider-sdk：…` | `provider-sdk` 没放在样例旁边 | 放到 `../provider-sdk`，或 `gradle.properties` 里写 `xwshunSdkDir=<路径>` |

## 安装时

| 看到的 | 原因 | 怎么办 |
|---|---|---|
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | 设备上已有同包名、**另一把密钥**签的包，系统不让覆盖 | `adb uninstall <包名>` 再装（插件的数据会清掉）。宿主那边随后显示「已拒绝（换签）」，见下面「插件页」 |
| `INSTALL_FAILED_VERSION_DOWNGRADE` | 新包 `versionCode` 比装着的小 | 加大 `versionCode`；只是测试就 `adb install -r -d` |
| 桌面上找不到插件的图标 | 正常：插件 App 没有启动页 | 去宿主的插件页看 |

## 宿主插件页：列表、状态

插件页最底下「某个应用没出现在这里？」：填包名点「检查」，宿主说它看到了什么。

| 看到的 | 原因 | 怎么办 |
|---|---|---|
| 列表里没有你的插件；检查说「看不到这个包：没有安装，或者它没有声明插件 action…」 | 没装上，或清单里服务没写 `top.xdwa.xwshun.plugin.action.PROVIDER_V1` | `adb shell pm list packages | grep 你的包名`；查清单 |
| 检查说「装了，但它没有声明插件服务 action，不是本 App 的插件」 | 同上，action 写错了 | 照 contract.md 第 1 节 |
| 不兼容：插件服务没有导出，宿主无法绑定 | 服务少了 `android:exported="true"` | 加上 |
| 不兼容：一个安装包声明了 N 个插件服务，只允许一个 | 有两个服务都声明了插件 action | 只留一个 |
| 不兼容：插件服务没有声明 top.xdwa.xwshun.plugin.DESCRIPTOR | 服务上没有描述符 meta-data | 加上，`android:resource` 指向 `@raw/…` |
| 不兼容：描述符超过 16 KiB / 读不出描述符资源 / 不是合法 JSON | 描述符文件本身的问题 | 用自查命令（README 第 4 步）先过一遍 |
| 不兼容：不允许的字段：… | 描述符里多了约定以外的字段 | 删掉。字段集合是封闭的 |
| 不兼容：API major 2 不兼容（宿主 1）（实测，用测试插件 echo-apimajor2） | `apiMajor` 不是 1 | 写 `1`。版本规则见 compatibility.md |
| 不兼容：未知能力：… | `capabilities` 里有宿主不认识的名字，而 `apiMinor` 又不比宿主新 | 只写 contract.md 里列的能力 |
| 不兼容：描述符自称的服务类与实际声明插件 action 的服务不一致 | 改了包名或类名，描述符的 `serviceClass` 没跟着改 | 改成服务的全名 |
| 已拒绝：描述符声称的包名与实际安装包不一致 | 描述符的 `packageName` 不等于 applicationId | 改成一样 |
| 已拒绝：builtin.xxx 是内置 provider 保留 ID，外部包不能占用 | `pluginId` 用了 `builtin.` 开头 | 换一个 |
| 已拒绝：xxx 自称随包内置，但它是单独安装的包… | `deployment` 写了 `bundled` | 写 `android-service` |
| 已拒绝：xxx 已被另一个 provider 占用，不允许遮蔽 | 设备上另一个已可用的插件用了同一个 `pluginId` | 换一个 `pluginId` |
| 已拒绝：debug 证书签名的插件只在开发构建中可用（实测，正式版宿主 + 测试插件 echo-debugkey） | 用 Android 调试证书签的插件，装在正式版宿主上 | 用你自己的密钥签（样例默认就是） |
| 待批准，且写着「用 Android 调试证书签名：只有开发构建能用」 | 同上，装在开发版宿主上：能批准，但换正式版宿主就不能用了 | 同上 |
| 已拒绝：安装包证书与批准时不同（换签），已禁用，需要重新核验 | 批准之后你换了签名密钥（卸载后装了另一把密钥签的包） | 确认是你自己换的：详情页「撤销批准」，再核对新证书、重新批准 |
| 更新后回到「待批准」：插件申请了批准范围之外的新能力，需要重新批准 | 新版本的 `capabilities` 多了 | 正常，让用户重新核对后批准 |
| 点批准提示「这个插件由多张证书共同签名，暂不支持批准」 | 用了多个签名者 | 只用一把密钥签 |
| 点批准提示「确认期间插件有变化（更新、换签或卸载），没有批准」 | 确认框开着的时候你又装了一次 | 重新打开确认框核对、再批 |
| 已卸载 | 之前批准过，现在设备上没这个包了 | 装回**同一把密钥**签的包，直接恢复「可用」（实测） |

## 连接测试

| 看到的 | 原因 | 怎么办 |
|---|---|---|
| 没有「连接测试」按钮 | 插件不是「可用」 | 先批准；停用了就点「启用」 |
| 连接失败：插件拒绝了宿主：top.xdwa.xwshun 的签名证书不是信任的那张（实测） | 你在 `xwshunHostSha256` 里写的不是手上这个宿主的证书。最常见：宿主是另一台电脑编的 debug 包，或者换成了正式版宿主 | 从宿主插件页底部「给插件作者」抄证书，重新构建插件 |
| 连接失败：插件不接受宿主的 API 版本：本插件要求宿主 API 1.1 及以上，宿主是 1.0（实测，样例加 `-PminHostMinor=1` 构建） | 你的 `handshake` 不接受这个宿主版本（抛了 `IllegalStateException`） | 宿主升级，或者降低你的要求。后面那半句是你自己抛的原话 |
| 连接失败：插件握手出错：UnsupportedOperationException …（实测，测试插件 echo-badhandshake） | 握手里抛了 `IllegalStateException` 以外的异常 | 握手里只抛 `IllegalStateException`。X12 之前编的宿主遇到这种会整个闪退（实测：`FATAL EXCEPTION: pool-6-thread-1`），新宿主只报错 |
| 插件握手时自称 X，与批准的 Y 不符 | `handshake` 返回的描述符和清单里那份不是一个 `pluginId` | 返回同一份（样例从 `R.raw.xwshun_plugin` 读） |
| 握手时插件进程退出 / 插件进程已不在 | 插件在握手时崩了 | `adb logcat -s AndroidRuntime:E` 看调用栈 |
| 插件的签名证书和批准时不同，已拒绝绑定 | 批准之后插件包被换了签名 | 同「已拒绝（换签）」 |
| 系统拒绝绑定插件服务 / 插件服务已不在设备上，或不再声明插件 action | 服务被删了、改名了，或刚卸载 | 查清单，重新装 |

## 会话测试

| 看到的 | 原因 | 怎么办 |
|---|---|---|
| 详情页没有「会话测试」按钮 | 插件不是「可用」，或描述符的 `capabilities` 里没有 `terminal-session` | 批准；加上能力（加能力后要重新批准） |
| 没有「会话测试」按钮，写着「这个插件申请了「本会话的临时凭据」：…会话测试拿不出这些材料，所以不在这里开」 | 描述符的 `permissions` 里有 `own-session-ephemeral-secret`。这种会话（Mosh）要宿主先经 SSH 拿一次性材料 | 普通终端插件别申请这个权限（它也拿不到任何东西）；Mosh 插件从主机列表用 Mosh 协议连接 |
| 打开会话失败：插件拒绝：会话数已到上限 | 开的会话超过了你 `ProviderSessions` 的上限 | 调大上限，或检查会话结束时有没有 `drop` |
| 一直停在「打开会话」，没有「插件回报：运行中（active）」 | 你没回报 `active` | 会话线程开始收发前先 `onSessionEvent(…, "active")` |
| 框里是空的，「插件写回来的字节数」一直是 0 | 没往 `stream` 里写，或写在了别的地方 | 用 `new FileOutputStream(stream.getFileDescriptor())` 写 |
| 框里出现 `^J` | 你只写了 `\n` | 写 `\r\n`。在真终端上只有 `\n` 时下一行不回行首，越来越往右 |
| 2 秒内没收到插件的 resized 回报 | `resizeSession` 里没回报 `resized:COLSxROWS` | 加上，格式是 `resized:100x30` |
| 已关闭：2 秒内没等到插件确认（停止未确认） | 宿主关会话时你没回报 `closed`：线程卡在别处、没检查 EOF，或 `closeSession` 没关流 | 读到 EOF 就清理并回报 `closed`；关流前先 `Os.shutdown` |
| 中断：插件关了它那一端，没有先回报 closed | 你自己结束会话时关了流，但 300 ms 内没回报 `closed` | 关流后立即回报 `closed` |
| 中断：插件进程没了 | 插件崩了，或被系统、被你杀了 | 看 `AndroidRuntime:E` |
| 中断：本 App 断开了这个插件（停用、撤销批准或插件包变了） | 会话开着时你重装了插件，或者在宿主里停用、撤销了 | 正常 |
| 发送失败：插件没有及时读取，输入积压超过上限 | 你的插件不读输入，宿主替你排的 1 MiB 满了 | 会话线程要一直读 |
| 插件页「事件」里有「droppedEvent … 旧代次」「… 序号不递增」「… 不是这个插件的会话」 | 你发的会话事件代次不对、序号没递增，或用了别的句柄 | `generation` 原样用宿主给的；`sequence` 每个会话从 1 递增 |

## 别的

- **连接测试显示「已经连着（之前握过手），沿用这条连接…」**：宿主对一个插件只留一条连接，已经连着就不重新握手，免得断掉正在跑的会话。
  改了插件的握手逻辑想重新看一遍：装新包（系统换进程，宿主自动断开旧连接），或者在详情页点「断开」再测。
- 事件里「连接关闭 · … · 被新的连接取代」：旧连接已经不答话（进程没了），宿主重新连了一次。
- 插件页的「事件」最多留 30 条，最新的在最上面。
