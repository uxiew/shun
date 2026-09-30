# 插件契约与测试插件

- `provider-sdk/`：宿主与插件共用的 AIDL 契约和认人工具（`CallerVerifier`、`SignerDigests`）。宿主工程和这里的测试工程引用同一份。
- `fixture-echo/`、`fixture-rogue/`：X02–X04 的测试 APK。**只用于测试**：echo 连上不代表 Mosh 或任何真实 provider 可用。

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
| `rogue.apk` | example.xwshun.fixture.rogue | 另一把密钥 | 冒用 `builtin.ssh`、伪造 Intent extras 调插件、用转交来的 Binder 调宿主 |
| `echo-slowopen.apk` | example.xwshun.fixture.echo | 独立作者密钥 | 3 秒后才回报 active：打开途中关闭（PLG08） |
| `echo-stubborn.apk` | 同上 | 独立作者密钥 | 不理 close、宿主关流也不回报 closed、每 500 ms 发事件（PLG12） |
| `echo-misbehave.apk` | 同上 | 独立作者密钥 | 发旧代次和伪造句柄的会话事件（PLG06） |
| `echo-major2.apk` | 同上 | 独立作者密钥 | 握手时只接受宿主 API major 2（PLG02） |
| `echo-v2.apk` | 同上 | 独立作者密钥 | 版本 0.2.0（versionCode 2），能力不变：普通更新，应仍可用（PLG11） |
| `echo-morecaps.apk` | 同上 | 独立作者密钥 | 0.3.0，多申请 `remote-desktop-external`：应回到待批准，不自动扩大批准（PLG11） |
| `echo-apimajor2.apk` | 同上 | 独立作者密钥 | 0.4.0，描述符声明 API major 2：应判不兼容（X04「major 变化阻断」） |

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

## 撞墙时

- **`defaultConfig contains custom resource values, but the feature is disabled`**：AGP 9 默认关了 resValue，模块里要 `buildFeatures { resValues = true }`。
- **构建 rogue 时报「缺 -PhostSha256」**：Gradle 会配置所有模块，echo 的脚本也会跑。用 `build-fixtures.sh`，它每次都传。
- **`keytool -printcert -jarfile` 什么都不打印**：APK 只有 v2 签名，keytool 读不了。用 `$ANDROID_HOME/build-tools/36.0.0/apksigner verify --print-certs <apk>`。
- **`adb install` 报 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`**：同包名换了签名，系统不让覆盖。先 `adb uninstall example.xwshun.fixture.echo`。
- **`flutter test integration_test/...` 在 loading 就失败、没有任何报错细节**：X03 时遇到两次，原因没查清，重跑一次都好了。连着失败再看 `adb logcat`。
- **跑着跑着 `waiting for device`**：Mac 内存太紧时 adb 会短暂断开，模拟器其实还在。等 `adb shell getprop sys.boot_completed` 为 1 后重跑。
- **强杀插件后会话被记成「中断」而不是「插件死亡」**：宿主读到 EOF 比 Binder 死亡通知早。现在桥上等 300 ms 再上报 EOF；如果还是看到「中断」，先确认装的是新宿主包。
