# 给 xwshun 写插件

> 对应插件 API **1.0**（2026-10-07）。宿主的插件 API 版本在「设置 → 插件（实验）」最底下；不是 1.0 时，先看这几份文档有没有跟着改。

xwshun 是 Android 上的 SSH 终端 App（[Netcatty Mobile](https://github.com/kmh1145/Netcatty-mobile) 的 fork，包名 `top.xdwa.xwshun`，下面叫「宿主」）。
**插件是你自己写、用你自己的密钥签名的另一个 Android App。** 它给宿主提供终端会话：宿主把用户敲的键发给它，它把要显示的字写回来。
用户在宿主的「设置 → 插件（实验）」里核对你的签名证书、点「批准」之后，宿主才会启动你的代码。

照这份文档做，你不需要宿主的源码，也不需要宿主的签名私钥。

| 文档 | 讲什么 |
|---|---|
| 本页 | 最快路线；从零做出一个插件、装上、批准、验证（第 1–8 步） |
| [capabilities.md](capabilities.md) | **先读**：每种能力、权限宿主用不用，插件做不到什么、为什么 |
| [contract.md](contract.md) | 接口约定：描述符每个字段、AIDL 每个方法、字节流和状态、报错怎么让宿主看见 |
| [troubleshooting.md](troubleshooting.md) | 出错了：按你看到的那句话查原因 |
| [compatibility.md](compatibility.md) | 版本号、升级规则、Android 版本和 ABI、测过什么 |
| [licensing.md](licensing.md) | 许可：宿主、SDK、样例、Mosh 插件各是什么许可 |

## 最快路线（约 10 分钟）

工具都装好的前提下（JDK 17、Android SDK，见下面「你要准备什么」；项目这台 Mac 上 `source /Users/fodelf/xdw/xwshun/.toolchain/env.sh` 就全有了）：

```bash
# 1. 宿主装到设备上（安装包由项目所有者给你）
adb install -r 宿主.apk
# 2. 一步起工程：复制样例、改名、生成你的密钥、从宿主安装包读证书、自查、构建（不改仓库里的任何文件）
<仓库>/plugins/example/tools/new-plugin.sh com.alice.notes com.alice.notes "Alice 的笔记终端" --host-apk 宿主.apk --build
# 3. 装插件（路径脚本最后会打出来）
adb install -r ~/xwshun-plugins/notes/app/build/outputs/apk/release/app-release.apk
```

4. 宿主「设置 → 插件（实验）」→ 点你的插件 → 详情页的证书 SHA-256 和脚本打出的「你的证书」对一下 →「批准」。
5. 点「会话测试」→「开始」：看到「插件回报：运行中（active）」和欢迎语就通了。敲 `help` 发送、点「改成 100×30」、点「关闭会话」，见第 7 步。

项目这台 Mac 上（Gradle 有缓存）第 2 步实测 9 秒；新机器第一次要下载 Gradle 和 Android Gradle Plugin，看网速。
脚本做了第 1–4 步的全部手工活；想知道它做了什么、或者不想用脚本，看下面的手动做法。接着就是改 `TerminalShell.java` 写你自己的逻辑（第 8 步）。

## 先说清楚现在能做什么

- **只有 Android。** 插件是 APK，iOS 上没有这套东西。
- **只有「终端会话」一种插件能用。** 描述符里还能写设备目录、远控之类的能力名，但宿主现在不会调用第三方插件的这些能力。每一项的现状见 [capabilities.md](capabilities.md)。
- **宿主里能用你插件的地方，目前只有插件详情页的「会话测试」。** 主机列表里「用某个插件连接」的入口所有者已经同意做，还没上。
  Mosh 插件是宿主专门接进去的（它要宿主先 SSH 上去启动 mosh-server），不走这条路。

## 仓库里这几类「插件」不是一回事

| 类别 | 在哪 | 是什么 | 能照着写吗 |
|---|---|---|---|
| **样例** | `plugins/example` | Hello 终端：一个很小的行编辑「shell」，演示认人、版本协商、字节流、改尺寸、关闭、设置页 | **能，从它开始** |
| 测试插件 | `plugins/fixture-*` | 只给宿主做测试：echo 原样回显，还有故意不理关闭、发假事件、握手抛异常的变体；rogue 故意冒充宿主；假 UU、假 RustDesk、回放输入法 | 不要。有的是故意做坏的 |
| 真实插件 | `plugins/mosh` | Mosh 运行时：官方 mosh-client 交叉编译进 APK，经 PTY 接到宿主给的字节流上 | 结构可以参考；它带 native 代码、按 GPL 分发，还用到一个只给 Mosh 的方法 |
| 外部 App 适配 | 宿主内置的「UU 远程调用」「RustDesk 调用」 | **不是插件 APK**：宿主按 UU、RustDesk 公开的链接格式去拉起它们自己的 App，它们不实现本 SDK | 不适用 |

## 你能读的材料

做插件只需要这些（复验时也只看这些）：

- `docs/plugin-authors/`：本目录。
- `plugins/example/`：样例工程。
- `plugins/provider-sdk/`：契约库。AIDL 接口（`src/main/aidl/`）和四个 Java 类：`CallerVerifier`（认调用方）、`SignerDigests`（从系统读证书）、`ProviderSessions`（会话表）、`PluginContract`（常量）。
- `packages/plugin_api/`：宿主判定插件能不能用的规则（Dart），以及构建前自查描述符的命令。
- `plan/v3/contracts/plugin-manifest.schema.json`：描述符的 JSON Schema。
- 可选参考：`plugins/mosh/`（带原生代码的真实插件）和它的许可台账 `plugins/mosh/LICENSES.md`。

宿主的 `lib/`、`android/` 不用看。

## 你要准备什么

| 东西 | 要求 | 没有会怎样 |
|---|---|---|
| 宿主 APK | 项目所有者给你（现在没有公开发布）。本机就是 `xwshun/v3` 分支编出来的 debug 包 | — |
| 设备 | Android 7.0（API 24）及以上、**arm64** 的手机或模拟器，开着 USB 调试 | 宿主只带 arm64-v8a 的原生库，别的 ABI 没测过 |
| JDK | 17 | `./gradlew` 报 `Unable to locate a Java Runtime`（macOS 上的说法） |
| Android SDK | platform 36、build-tools 36.0.0（里面有 `apksigner`）、platform-tools（`adb`）。设 `ANDROID_HOME` 指向它 | 报 `SDK location not found` |
| Gradle | 不用装：样例自带 wrapper，第一次构建自动下载 Gradle 9.1.0（压缩包 232 MB，解开连包约 740 MB）和 Android Gradle Plugin 9.0.1 及其依赖（这部分没在空缓存上量过），要联网 | 第一次构建失败 |
| Dart SDK | 可选，只给第 4 步的自查用；Flutter 自带的也行 | 跳过自查 |
| perl | `new-plugin.sh` 改名时用（macOS、Linux 一般自带） | 脚本报「要 perl」 |

**在项目这台 Mac 上**：`source /Users/fodelf/xdw/xwshun/.toolchain/env.sh`，上面的 JDK、SDK、Dart、Gradle 缓存就都有了，不用联网。

## 手动做法：第 1–4 步

用了上面的 `new-plugin.sh` 就不用做这四步，直接看第 5 步。

## 第 1 步：复制样例，先原样编一次

先别改名。原样编通、装上、看到会话通了，说明工具链和设备都没问题，之后改出毛病就知道是改出来的。

```bash
mkdir -p ~/my-plugin
rsync -a --exclude build --exclude .gradle <仓库>/plugins/example <仓库>/plugins/provider-sdk ~/my-plugin/
cd ~/my-plugin/example
```

两个目录要放在同一个父目录下：样例默认在 `../provider-sdk` 找契约库。放别处就在 `gradle.properties` 里加一行 `xwshunSdkDir=<provider-sdk 的路径>`，
不加会报 `找不到 provider-sdk：…`。

## 第 2 步：生成你自己的签名密钥

```bash
mkdir -p ~/xwshun-plugin-keys
keytool -genkeypair -keystore ~/xwshun-plugin-keys/my-plugin.jks -alias plugin \
  -keyalg RSA -keysize 3072 -validity 10000 -dname "CN=你的名字"
# 会问两次密码（一次输入、一次确认），记住它
```

```bash
cp signing.properties.example signing.properties    # 已被 .gitignore 忽略，别提交
```

把 `signing.properties` 里的 `storeFile`、`storePassword`、`keyPassword` 改成你的（`keyAlias` 就是上面的 `plugin`）。
**`keyPassword` 和 `storePassword` 填同一个密码**：JDK 9 起 keytool 默认建 PKCS12 密钥库，里面的密钥口令就是密钥库口令，keytool 也只问这一个。
填成别的，构建时报 `KeytoolException: Failed to read key plugin from store "…": Get Key failed: Given final block not properly padded…`（实测）。

- **这把密钥要一直用下去。** 丢了就没法发新版本：同一个包名换了密钥，系统不让覆盖安装，用户只能卸载重装、在宿主里重新批准。
- 你的证书指纹要公布给用户，他们批准时拿来核对。构建出 APK 之后最准的读法（输出就是宿主详情页上那串小写、不带冒号的 64 位十六进制）：
  `$ANDROID_HOME/build-tools/36.0.0/apksigner verify --print-certs app/build/outputs/apk/release/app-release.apk`，取 `certificate SHA-256 digest` 那一行。
  只有密钥库时：`keytool -list -v -keystore ~/xwshun-plugin-keys/my-plugin.jks -alias plugin | awk '/SHA256:/{print $2}' | tr -d ':' | tr 'A-F' 'a-f'`
  （keytool 的输出带冒号、大写，中文系统上其他行是中文，只有 `SHA256:` 那一行要）。
- 别用 Android 调试证书（`~/.android/debug.keystore`）签：正式版宿主一律拒收（「debug 证书签名的插件只在开发构建中可用」），
  开发版宿主也会标出来。样例的 debug 包、release 包都用你的密钥签，避开这个坑。

## 第 3 步：告诉插件信任哪个宿主

插件只接受用某一张证书签名的宿主来调它，不然谁冒充宿主都能用你的插件。这张证书的 SHA-256 写进 `gradle.properties`：

```properties
xwshunHostSha256=499ff3abf2d0aeb386ce3b30da1c3a0fa3566d5d89b042bf279c0773f79d500f
```

上面这串是项目这台 Mac 上编的 debug 宿主的证书。**你手里的宿主不一定是这张**，两种办法取：

- 装好宿主后打开「设置 → 插件（实验）」，拉到最底下「给插件作者」：「本 App 的签名证书 SHA-256」那一行，长按能复制；
- 或者对宿主 APK 文件：`$ANDROID_HOME/build-tools/36.0.0/apksigner verify --print-certs 宿主.apk`，取 `certificate SHA-256 digest` 那一行。
  （`keytool -printcert -jarfile` 读不了这种只有 v2/v3 签名的包，什么都不打印。）

写错了会怎样：构建照样成功，装上也能批准，但「连接测试」报 **「连接失败：插件拒绝了宿主：top.xdwa.xwshun 的签名证书不是信任的那张」**。
debug 宿主是用编它那台电脑的调试证书签的，换一台电脑编的宿主证书就不同；要同时支持几个宿主，用逗号隔开写几张。

## 第 4 步：构建

```bash
./gradlew assembleRelease
# 产物：app/build/outputs/apk/release/app-release.apk（样例约 660 KB）
```

项目这台 Mac 上有缓存时约 6–13 秒。缺配置会在这一步报出来，并说去看哪一步：

```text
xwshunHostSha256 没填或格式不对：…怎么取见 docs/plugin-authors/README.md 第 3 步
缺签名配置 …/signing.properties：照 signing.properties.example 写一份。…第 2 步
```

**可选：构建前自查描述符**（要 Dart SDK）。报出来的话和宿主插件页上的一字不差，省得装到手机上才发现：

```bash
<仓库>/plugins/example/tools/check-descriptor.sh ~/my-plugin/example/app/src/main/res/raw/xwshun_plugin.json \
  --package example.xwshun.hello --service example.xwshun.hello.HelloProviderService
# 通过（宿主 API 1.0 的判定）。证书和批准要装到设备上再看。
```

## 第 5 步：装到设备

```bash
adb install -r 宿主.apk                                        # 还没装宿主的话
adb install -r app/build/outputs/apk/release/app-release.apk
```

宿主不下载、不安装插件，都是你（或用户）自己装。插件 App 没有桌面图标，桌面上看不到它是正常的。

## 第 6 步：在宿主里核对证书、批准

1. 打开宿主 →「设置」→ 往下拉 →「插件（实验）」。你的插件在列表里，状态「待批准」。
   这时候宿主只读了你的描述符，**没启动你的任何代码**（`adb shell pidof example.xwshun.hello` 什么都不打印）。
2. 点进去看详情页：插件 ID、包名、版本、能力、申请的权限，以及**签名证书 SHA-256**——和第 2 步你自己读出的那串对一下。
3. 点「批准」，确认框里再显示一遍证书，点「批准」。状态变「可用」，出现「连接测试」「会话测试」「停用」「撤销批准」「打开插件的设置页」。

列表里没有你的插件、或者状态是「不兼容」「已拒绝」：看 [troubleshooting.md](troubleshooting.md)，条目上写着原因。

## 第 7 步：验证会话通了

**连接测试**：详情页点「连接测试」，应显示「握手成功（插件核对了宿主证书），ping 往返正常」。
这一步宿主绑定你的服务、调 `handshake`（你的插件核对宿主证书、协商版本）、再调一次 `ping`。
再点一次显示「已经连着（之前握过手），沿用这条连接：ping 往返正常…」：宿主对一个插件只留一条连接，连着就只 ping、不重新握手。

**会话测试**：点「会话测试」→「开始」。样例的结果应该是这样（模拟器上实测，毫秒数每次不同）：

```text
75 ms  连接：握手成功（插件核对了宿主证书），ping 往返正常
116 ms  打开会话：80×24，代次 1
117 ms  插件回报：运行中（active）
```

框里是你的插件写回来的字节，控制字符写成 `^X`（`^[` 是 ESC）：

```text
^[[1;36mHello 终端^[[0m：xwshun 插件样例
宿主 API 1.0 · 终端 80×24 · 输入 help 看命令
hello>
```

接着：

| 做什么 | 应该看到 |
|---|---|
| 输入框敲 `help`，点「发送」 | 步骤里「内容：help^M」（`^M` 是回车 `\r`，默认勾着「末尾加回车」）；框里出现命令列表 |
| 点「改成 100×30」，再发 `size` | 「插件确认尺寸 100x30」；框里「终端大小：100 列 × 30 行」 |
| 发 `color` | 框里 `^[[31m红^[[0m …`：颜色转义序列原样到了宿主 |
| 点「关闭会话」 | 「正在关闭：本 App 先关了自己这一端，再请插件关」→「已关闭：插件确认已停止（closed）」 |
| 点「重新开始」，发 `exit` | 框里「再见。插件这边结束会话。」→「已关闭：插件自己结束了会话（closed）」 |

插件这边的日志：`adb logcat -s XwshunHello`（样例的 TAG；改成你自己的）。宿主的插件桥日志 TAG 是 `XwshunPlugins`，它丢掉的事件、拒绝的调用记在那里。

到这里，授权 → 版本协商 → 字节流 → 改尺寸 → 关闭都走过一遍了。

## 不装宿主能测什么

**会话逻辑在电脑上测**：样例把「收到什么、回什么」写在纯 Java 的 `HelloShell`（脚本起的工程里叫 `TerminalShell`）里，不碰任何 Android 类，
`app/src/test` 里有它的 9 条 JVM 单测，`./gradlew :app:testDebugUnitTest` 几秒跑完，不用设备、不用宿主。你的插件也这样分：逻辑写成纯 Java，
`Session` 类只管把 FD 接到逻辑上。

**握手、认人、字节流这一层要装宿主测**，用宿主的「会话测试」。SDK 里不提供「假宿主」，原因：

- 插件只接受宿主那张证书签的、包名是 `top.xdwa.xwshun` 的调用方（`CallerVerifier`）。假宿主要么用同一个包名（和真宿主装不到一台设备上），
  要么让插件额外信任一个假宿主——这得在插件里放开一个口子，只在 debug 包里放开也容易被带进发布包，削弱的正是这层认人。
- 假宿主要把宿主的插件桥（绑定、握手、socketpair、背压、关闭确认）重写一遍，几百行，写出来也不等于真宿主的行为。

宿主的会话测试只发你敲的那一行、把插件写回的字节原样（控制字符转义）显示出来，每一步写结果，够用来核对协议这一层。

## 第 8 步：改成你自己的插件

要一起改的（漏一处宿主就会报出来，见 [troubleshooting.md](troubleshooting.md)）：

| 改什么 | 在哪 | 规则 |
|---|---|---|
| 包名 | `app/build.gradle.kts` 的 `applicationId`、`namespace`；描述符的 `packageName`（用 `new-plugin.sh` 起的工程这几样已经改好了） | 描述符的 `packageName` 必须等于实际安装的包名，否则「已拒绝：描述符声称的包名与实际安装包不一致」 |
| Java 包和服务类 | `app/src/main/java/` 的目录和 `package` 行；描述符的 `serviceClass` | `serviceClass` 必须是声明插件 action 的那个服务的全名，否则「不兼容：描述符自称的服务类与实际声明插件 action 的服务不一致」 |
| 插件 ID | 描述符 `pluginId` | 小写字母、数字、下划线，至少两段用点隔开（`com.yourname.foo`）；`builtin.` 开头的是宿主保留的 |
| 名字、版本 | 描述符 `displayName`、`version`；`versionName`、`versionCode` | `version` 是 `x.y.z`；每次发新版本 `versionCode` 加 1 |
| 会话逻辑 | `HelloShell.java`（脚本起的工程里是 `TerminalShell.java`），连同它的 JVM 单测 | 换成你的。字节流约定见 [contract.md](contract.md)「会话」。接线（`HelloSession` / `TerminalSession`）一般不用动 |
| 设置页 | `SettingsActivity.java` | 不要就把它和清单里那个 `<activity>` 一起删掉 |
| 许可 | 描述符 `license` | 写你的插件实际的许可，见 [licensing.md](licensing.md) |

发新版本、换密钥、宿主升级 API 时会怎样，见 [compatibility.md](compatibility.md)。
