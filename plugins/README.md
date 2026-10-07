# 插件契约与测试插件

要写插件，看 [docs/plugin-authors/](../docs/plugin-authors/README.md)，从 `example/` 开始。本页讲的是这个目录里的测试插件怎么编、怎么用。

- `provider-sdk/`：宿主与插件共用的 AIDL 契约和认人工具（`CallerVerifier`、`SignerDigests`）。宿主工程和这里的测试工程引用同一份。
  它和 `example/` 是 Apache-2.0（各自目录里的 `LICENSE`）；测试插件 `fixture-*`、`mosh/` 和仓库其余部分仍是 GPL-3.0-or-later。
- `example/`：**插件样例**（Hello 终端，X12）。独立的 Gradle 工程，自带 wrapper，不在下面的测试工程里、`build-fixtures.sh` 不构建它；
  用作者自己的密钥签名（本机测试用的在仓库外 `../../.toolchain/plugin-keys/example-author.jks`，配置在同目录 `example-signing.properties`）。
- `fixture-echo/`、`fixture-rogue/`：X02–X04 的测试 APK。**只用于测试**：echo 连上不代表 Mosh 或任何真实 provider 可用。
- `fixture-fakeuu/`、`fixture-fakerustdesk/`：X06、X07 的「假 UU 远程」「假 RustDesk」，扮演外部远控 App 接请求。它们不是真的，和它们走通不代表真实 App 能用。
- `mosh/`：**真实插件**，不是测试用的。Mosh 运行时（官方 mosh-client 交叉编译，X08）。要先编运行时再构建，见 `mosh/README.md`；
  `build-fixtures.sh` 不构建它。

## 构建

```bash
source ../../.toolchain/env.sh
cp ../android/local.properties .      # 首次：告诉 Gradle SDK 在哪（被 .gitignore 忽略）
./build-fixtures.sh                   # 约 1 分钟，产物在 out/
```

首次运行会在仓库外 `../../.toolchain/plugin-keys/` 生成两把测试密钥（口令都是 `xwshun-fixture`）。
删掉这个目录再构建，证书就变了，手机上已批准的插件会被判为「换签」。

| 产物 | 包名 | 签名 | 用来测 |
|---|---|---|---|
| `echo-author.apk` | example.xwshun.fixture.echo | 独立作者密钥 | 批准后接入、双向鉴权（PLG15） |
| `echo-impostor.apk` | 同上 | 另一把密钥 | 同包名不同签名（PLG04）。要先卸载 author 版才装得上 |
| `echo-leaky.apk` | 同上 | 独立作者密钥 | 握手后把宿主回调 Binder 转交给 rogue（PLG05 宿主侧） |
| `echo-debugkey.apk` | example.xwshun.fixture.echo.debugkey | 本机 Android 调试证书 | release 宿主拒收调试证书（PLG15） |
| `echo-fakemosh.apk` | example.xwshun.fixture.fakemosh | 另一把密钥 | 自称 `xwshun.mosh`：宿主只认 Mosh 插件那张证书（`lib/domain/plugins/official_plugins.dart`），应「已拒绝：xwshun.mosh 只认登记过的官方证书…」、没有批准按钮（X12） |
| `rogue.apk` | example.xwshun.fixture.rogue | 另一把密钥 | 冒用 `builtin.ssh`、伪造 Intent extras 调插件、用转交来的 Binder 调宿主 |
| `echo-slowopen.apk` | example.xwshun.fixture.echo | 独立作者密钥 | 3 秒后才回报 active：打开途中关闭（PLG08） |
| `echo-stubborn.apk` | 同上 | 独立作者密钥 | 不理 close、宿主关流也不回报 closed、每 500 ms 发事件（PLG12） |
| `echo-misbehave.apk` | 同上 | 独立作者密钥 | 发旧代次和伪造句柄的会话事件（PLG06） |
| `echo-major2.apk` | 同上 | 独立作者密钥 | 握手时只接受宿主 API major 2（PLG02） |
| `echo-badhandshake.apk` | 同上 | 独立作者密钥 | 握手时抛 UnsupportedOperationException（约定是 IllegalStateException）：宿主要报「连接失败：插件握手出错…」，不能崩（X12） |
| `echo-v2.apk` | 同上 | 独立作者密钥 | 版本 0.2.0（versionCode 2），能力不变：普通更新，应仍可用（PLG11） |
| `echo-morecaps.apk` | 同上 | 独立作者密钥 | 0.3.0，多申请 `remote-desktop-external`：应回到待批准，不自动扩大批准（PLG11） |
| `echo-apimajor2.apk` | 同上 | 独立作者密钥 | 0.4.0，描述符声明 API major 2：应判不兼容（X04「major 变化阻断」） |
| `fakeuu.apk` | com.netease.uuremote | 独立作者密钥 | X06 假 UU 远程 4.42.0：冒充官方包名，证书不是官方的，宿主要用户批准证书后才发请求 |
| `fakeuu-old.apk` | 同上 | 独立作者密钥 | 4.41.0：宿主应判「版本太旧」 |
| `fakeuu-resigned.apk` | 同上 | 另一把密钥 | 同包名换签：批准过 `fakeuu` 之后装它，宿主应停下来要求重新核对。要先卸载 `fakeuu` 才装得上 |
| `fakeuu-lookalike.apk` | example.xwshun.fixture.fakeuu | 另一把密钥 | 别的包也声明 `uuremote://`：官方包名没装时宿主应说「没装」并提醒有别的 App 声明，请求不发给它 |
| `fakeuu-hijack.apk` | 同上 | 另一把密钥 | 抢回调的 App：另外声明宿主的回调地址 `xwshun-uuremote://callback`。宿主应说出它的包名，绑定和小窗不发（UUR06） |
| `fakerd.apk` | com.carriez.flutter_hbb | 独立作者密钥 | X07 假 RustDesk 1.4.9：冒充官方包名，证书不是发行渠道的，宿主要用户批准证书后才发请求 |
| `fakerd-old.apk` / `fakerd-ungated.apk` / `fakerd-newer.apk` | 同上 | 独立作者密钥 | 版本 1.2.3 / 1.4.6 / 1.6.0：宿主应分别说「版本太旧」（不发）、提醒更新（能发）、「这个版本没核对过」（能发）（RDX05） |
| `fakerd-resigned.apk` | 同上 | 另一把密钥 | 同包名换签：批准过 `fakerd` 之后装它，宿主应停下来要求重新核对。要先卸载 `fakerd` 才装得上 |
| `fakerd-custom.apk` | example.xwshun.fixture.fakerustdesk | 另一把密钥 | 别的包名也声明 `rustdesk://`：宿主只列出它，点「信任并改用」确认后才把请求发给它（RDX01） |
| `fakerd-custom-hostonly.apk` | 同上 | 独立作者密钥 | 同上，但 intent-filter 限定 `host=connect`：宿主照样看得见。和 `fakerd-custom` 不同密钥，卸载后换装它就是「信任过的包换签」 |

同包名同密钥的变体之间 `adb install -r` 直接覆盖，批准记录不受影响。测试 APK 都是可调试的，方便 `run-as` 看进程的 fd。
X04 的三个更新变体 versionCode 是 2、3、4，其余都是 1：从高版本换回低版本要 `adb install -r -d`，否则报 `INSTALL_FAILED_VERSION_DOWNGRADE`。
所有 echo 变体都带一个自己的设置页（`SettingsActivity`，声明 `top.xdwa.xwshun.plugin.action.SETTINGS_V1`）。

插件只接受一张宿主证书：默认是本机 `~/.android/debug.keystore`（宿主 debug 包和没配正式签名的 release 包都用它）。
换台电脑构建的宿主证书不同，插件会拒绝它，报「签名证书不是信任的那张」。要指定别的宿主证书：`HOST_SHA256=<64位十六进制> ./build-fixtures.sh`。

## 负向探测

```bash
adb install -r out/rogue.apk
adb shell am start -n example.xwshun.fixture.rogue/.ProbeActivity      # 冒充宿主调 echo 的每个方法
adb logcat -d -s XwshunRogue XwshunEcho XwshunPlugins                   # 每个方法一行；出现 ACCEPTED 就是鉴权有洞
```

## X03 设备检查（会话字节流与故障）

`integration_test/plugin_session_test.dart` 在设备上驱动真实的插件桥和测试插件，按场景跑。每次都会重装 App（数据清空，批准由测试用 App 自己的存储重新写入）。

```bash
adb install -r out/echo-author.apk && adb install -r out/echo-debugkey.apk     # 在 plugins/ 下
cd .. && flutter test integration_test/plugin_session_test.dart -d emulator-5554 --dart-define=X03_SCENARIO=stream
```

| 场景 | 先装 | 看什么 |
|---|---|---|
| `stream` | echo-author | 逐字节、1 MiB 随机分块夹 resize、订阅者暂停时宿主缓冲与输入积压的上限、关闭确认、连开连关 20 次 fd 不涨 |
| `slowopen` | echo-slowopen | 打开途中关：不进入运行中，插件确认停止 |
| `misbehave` | echo-misbehave | 旧代次、伪造句柄的事件被丢弃，会话照常 |
| `stubborn` | echo-stubborn + echo-debugkey | 撤销后插件持续发的事件全被丢弃，记「停止未确认」，另一个插件不受影响 |
| `version` | echo-major2 | 握手被拒，打不开会话 |
| `kill` | echo-author + echo-debugkey，另起 `tool/fixture-environment/up.sh` 并 `adb reverse tcp:22201 tcp:22201` | 测试打出 `X03 kill.READY` 后执行 `adb shell run-as example.xwshun.fixture.echo kill -9 $(adb shell pidof example.xwshun.fixture.echo)`：它的会话记插件死亡，另一个插件、SSH、SFTP 照常 |
| `hostkill` | echo-author | 打出 `X03 hostkill.READY` 后 `adb shell run-as top.xdwa.xwshun kill -9 $(adb shell pidof top.xdwa.xwshun)`；看 echo 日志「宿主已退出，关闭 1 个会话」和它的 fd 数。测试会报「未完成」，那是被杀掉了，正常 |

`kill` 场景的 SSH 参数用 `--dart-define` 传：`SSH_PORT=22201`、`SSH_USER`、`SSH_PASS`、`SSH_FP`，取自 `tool/fixture-environment/.run/fixture.json`（`sshEdge.fingerprintSha256`）。

## X04 设备检查（管理界面、更新检测、设置页）

用正式 debug 宿主（`flutter build apk --debug`）手动走，没有自动化脚本。先装 `echo-author` 和 `echo-debugkey`，
在「设置 → 插件（实验）」批准 echo，停在它的详情页，然后在电脑上依次：

```bash
adb install -r out/echo-v2.apk          # 仍「可用」，版本变 0.2.0（2），之前的连接测试结果作废
adb install -r out/echo-morecaps.apk    # 回到「待批准」：申请了批准范围之外的新能力
adb install -r out/echo-apimajor2.apk   # 「不兼容」：API major 2
adb install -r -d out/echo-author.apk   # 直接「可用」（原批准覆盖它的能力）
adb uninstall example.xwshun.fixture.echo && adb install out/echo-impostor.apk   # 「已拒绝（换签）」
adb logcat -d -s XwshunEcho | grep 设置页   # 点过「打开插件的设置页」后：action=…SETTINGS_V1 extras=[]
```

每一步都不需要点「重新扫描」。批准确认框开着时装一个新版本再点批准，应马上提示「确认期间插件有变化」、不批准。

## X06 假 UU 远程

假 UU 收到本 App 的请求后，按事先设定的模式回调。先设模式，再在 App 里点「在 UU 里选设备」或「小窗远控」：

```bash
adb install -r out/fakeuu.apk
adb shell am start -n com.netease.uuremote/example.xwshun.fixture.fakeuu.ModeActivity --es mode bind_ok
adb logcat -d -s XwshunFakeUu     # 每个请求、每次回调一行：参数名、state 长度、加密 ID 的哈希前缀（不记原文）
```

| 模式 | 用在 | 假 UU 怎么回 |
|---|---|---|
| `bind_ok` / `bind_ok_b` | 绑定 | 两个不同的加密 ID，都带 `+ / =`，按官方示例编码 |
| `bind_ok_raw` | 绑定 | ID 里的 `+` 不编码：本 App 应按字面收下，后面发远控时编码成 `%2B` |
| `bind_error:<错误码>` | 绑定 | 比如 `bind_error:user_cancel`、`bind_error:superseded` |
| `bind_wrong_nonce` / `bind_dup` / `bind_long` | 绑定 | nonce 不对 / nonce 出现两次 / 5000 字符的 ID：本 App 都应拒收 |
| `bind_twice` | 绑定 | 同一条回调 1.5 秒后再发一次：第二次应被当成重放忽略 |
| `bind_none` | 绑定 | 不回调：本 App 一直等，可以「结束等待」 |
| `bind_late:<秒>` | 绑定 | 延迟回调：趁这段时间 `adb shell am force-stop top.xdwa.xwshun`，看回调冷启动 App 后还能不能对上 |
| `pip_success` / `pip_failure:<reason>` | 小窗远控 | 比如 `pip_failure:pip_unsupported`、`pip_failure:device_not_found` |
| `pip_twice` / `pip_late:<秒>` / `pip_none` | 小窗远控 | 重放 / 延迟回报（先在 App 里结束等待，看迟到的是否被忽略）/ 不回 |

全屏远控和官方一样从不回调。伪造一条没有请求的回调：`adb shell am start -a android.intent.action.VIEW -d 'xwshun-uuremote://callback/bind?state=AAAAAAAAAAAAAAAAAAAAAA\&anonymous_device_id=x\&nonce=y'`。

**抢回调的 App**（`fakeuu-hijack.apk`）。装上它，宿主的 UU 页应立刻（回到前台时）出现「另有 App 也声明了本 App 的 UU 回调地址」，绑定和小窗按钮变灰。
要看「请求发出之后它才装上」会怎样：

```bash
adb shell am start -n com.netease.uuremote/example.xwshun.fixture.fakeuu.ModeActivity --es mode bind_late:30
# 在 App 里点「重新绑定」，然后 30 秒内：
adb install -r out/fakeuu-hijack.apk
adb shell am start -n example.xwshun.fixture.fakeuu/example.xwshun.fixture.fakeuu.ModeActivity --es mode hijack_swap
# 假 UU 回调时系统弹「Open with」，选 Fake UU：它把加密标识换成自己的再转给宿主。宿主应显示「…这次返回的设备不可信，没有采用」，不弹确认框。
adb logcat -d -s XwshunFakeUu | grep HIJACK     # 它拿到了什么（参数名和哈希）
```

`hijack_log`（默认）只记不转。它的模式存在它自己的包里，和假 UU 的模式互不相干；卸载后模式也没了。

## X07 假 RustDesk

假 RustDesk 收到链接后只做一件事：把收到的东西原样写进日志、显示在屏幕上。和真实 RustDesk 一样，它不会回报任何结果。

```bash
adb install -r out/fakerd.apk
# 在 App 里：主机 → RustDesk → 批准证书 → 填 ID → 「用 RustDesk 远控」
adb logcat -d -s XwshunFakeRd
# RECEIVED via=onCreate pkg=com.carriez.flutter_hbb uri=rustdesk://connect/123456789 action=android.intent.action.VIEW
#   categories=[] extras=[] flags=0x10000000 newTask=true taskRoot=true referrer=null
```

每行要看的：`uri` 只能是 `rustdesk://connect/<ID>`，没有 `?`；`extras=[]`；`pkg` 是宿主页面上写的那个包；`via=onNewIntent` 说明假 RustDesk 当时已经开着。
`referrer=null` 是正常的（模拟器 API 35 上实测如此）。
换版本直接 `adb install -r out/fakerd-newer.apk`（同密钥、同 versionCode）；换签名的要先 `adb uninstall com.carriez.flutter_hbb`。

绕过 Dart 层、直接调平台桥的设备检查（带密码的、改配置的链接，证书对不上的包，平台层自己挡不挡得住）：

```bash
adb install -r out/fakerd.apk && adb install -r out/fakerd-custom.apk
cd .. && flutter test integration_test/rustdesk_bridge_test.dart -d emulator-5580   # 会重装 App、清空数据
adb logcat -d -s XwshunFakeRd    # 应当只有一行：pkg=example.xwshun.fixture.fakerustdesk uri=rustdesk://connect/987654321
```

它证明不了的：真实 RustDesk 收到链接后连不连得上、要不要密码、连的是哪台服务器。那些要装真实的 RustDesk 和一台被控电脑。

## R18 回放输入法

不是插件，是一个只认 adb 广播的输入法（`fixture-replayime`）：按脚本对当前输入连接做真实输入法那样的调用
（`setComposingText`、`commitText`、`setComposingRegion`、`finishComposingText`、`deleteSurroundingText`、回车键），
用来在模拟器上复现微信输入法语音那种「结束组字又圈回去改」的序列，看 App 发给远端的字节对不对。
脚本内容和来由写在 `ReplayIme.java` 里，期望结果在 `integration_test/r18_ime_replay_test.dart`。

```bash
cd plugins && ./build-fixtures.sh && cd ..            # 产出 plugins/out/replayime.apk
(cd tool/fixture-environment && ./up.sh)              # 已经起着就不用
tool/ime-replay.sh emulator-5580                      # R20 起只有 Ghostty，第二个参数留空
```

`tool/ime-replay.sh` 会临时把模拟器的默认输入法换成它，跑完（含失败）换回原来的并卸载；只认模拟器，真机上拒绝跑
（换默认输入法会动到所有者的设置）。手动试单段脚本：

```bash
adb shell am broadcast -a example.xwshun.fixture.replayime.RUN -p example.xwshun.fixture.replayime --es script wechat_voice
adb logcat -d -s ReplayIme      # START / STEP / DONE 每步一行
```

它证明不了的：真实微信输入法、Gboard 语音到底按什么顺序调用（这里回放的是 R04 真机日志里看到的）；
真机上的语音输入还要所有者亲自说话复测。

## 撞墙时

- **`defaultConfig contains custom resource values, but the feature is disabled`**：AGP 9 默认关了 resValue，模块里要 `buildFeatures { resValues = true }`。
- **构建 rogue 时报「缺 -PhostSha256」**：Gradle 会配置所有模块，echo 的脚本也会跑。用 `build-fixtures.sh`，它每次都传。
- **`keytool -printcert -jarfile` 什么都不打印**：APK 只有 v2 签名，keytool 读不了。用 `$ANDROID_HOME/build-tools/36.0.0/apksigner verify --print-certs <apk>`。
- **`adb install` 报 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`**：同包名换了签名，系统不让覆盖。先 `adb uninstall example.xwshun.fixture.echo`。
- **`flutter test integration_test/...` 在 loading 就失败、没有任何报错细节**：X03 时遇到两次，原因没查清，重跑一次都好了。连着失败再看 `adb logcat`。
- **跑着跑着 `waiting for device`**：Mac 内存太紧时 adb 会短暂断开，模拟器其实还在。等 `adb shell getprop sys.boot_completed` 为 1 后重跑。
- **强杀插件后会话被记成「中断」而不是「插件死亡」**：宿主读到 EOF 比 Binder 死亡通知早。现在桥上等 300 ms 再上报 EOF；如果还是看到「中断」，先确认装的是新宿主包。
- **`ime enable` 报 `Unknown input method ... cannot be enabled`**：刚 `adb install` 完系统还没扫描到新输入法。等 `adb shell ime list -a -s` 里出现它再 enable（`tool/ime-replay.sh` 已经这样做）。
