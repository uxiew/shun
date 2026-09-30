# xwshun 本机手册

Netcatty-mobile 的本地实验 fork（分支 `xwshun/v3`，不 push）。这里只讲在这台 Mac 上怎么跑、怎么测、怎么装、怎么清理。
App 怎么用看 [使用手册](../user/README.md)；做什么、做到哪看 `plan/v3/STATUS.md`。命令都在仓库根目录执行。

## 1. 先 source 环境

```bash
source ../.toolchain/env.sh     # 每开一个终端都要做；只影响当前终端
flutter --version               # 应为 3.44.4
```

不做的后果：`flutter test` 全部在 loading 阶段报 `HttpException: Connection closed before full header was received`
（shell 设了 `http_proxy` 没设 `no_proxy`）；`emulator -list-avds` 看不到本项目的 AVD（它们在 `../.toolchain/avd`）。

## 2. 测试

```bash
flutter test -j 4     # 全量约 700 条（X06 时 654 条通过、44 条跳过），约 2.5 分钟；没起测试环境时真实 SSH 那 44 条自动跳过。刚关模拟器、内存紧时不加 -j 4 可能被系统杀掉
flutter analyze       # 应为 No issues found（连 spikes/、packages/ 一起查）
```

真实 SSH/SOCKS/跳板的集成测试要先起 Docker 测试环境：

```bash
(cd tool/fixture-environment && ./up.sh && ./selfcheck.sh)   # selfcheck 8 项全 PASS
flutter test test/integration_ssh_fixture_test.dart
(cd tool/fixture-environment && ./down.sh)                   # 用完关掉，删除临时凭据
```

- 只用 `down.sh` 收尾，**别 `orb stop`**：OrbStack 里还跑着你别的项目。
- 已知失败或会崩进程的用例默认跳过，要看现场加 `XWSHUN_RUN_KNOWN_FAILS=1`。
- 测试环境细节见 `tool/fixture-environment/README.md`，终端引擎验证工程见 `spikes/terminal_spike/README.md`。

## 3. 模拟器

现在只留一台 `xwshun-a35-4k`（Android 15，4 KiB 页，自带 Gboard），用的是你原有的 API 35 镜像。

```bash
flutter emulators --launch xwshun-a35-4k    # 带窗口启动；首次启动会重建空系统
flutter run -d emulator-5554                # 设备 ID 以 flutter devices 为准
adb -s emulator-5554 logcat -s flutter      # 看 Dart 日志
adb -s emulator-5554 emu kill               # 关机
```

在模拟器里连本机的测试环境：先 `adb reverse tcp:22201 tcp:22201`（SOCKS 再加 21080、21081），App 里地址填 `127.0.0.1`。
别用 `10.0.2.2`：它连 OrbStack 转发的端口能建 TCP 但收不到任何数据，App 会报「对方在登录前断开」，看着像配置错，其实是模拟器网络的问题。

其他版本测完已删（省磁盘）。要复测某个版本，按需重建、用完再删：

```bash
V="system-images;android-24;google_apis;arm64-v8a"      # 换成要测的版本，见下表
S=$ANDROID_HOME/cmdline-tools/latest/bin
$S/sdkmanager --install "$V"
echo no | $S/avdmanager create avd -n xwshun-tmp -k "$V" -d pixel_7
# 启动前在 ../.toolchain/avd/xwshun-tmp.avd/config.ini 里设 hw.audioInput=no（不让模拟器用 Mac 麦克风）
emulator -avd xwshun-tmp -no-window -no-snapshot -gpu host &
# 用完：
adb emu kill; $S/avdmanager delete avd -n xwshun-tmp; $S/sdkmanager --uninstall "$V"
```

| 用途 | 镜像 |
|---|---|
| 最低版本 Android 7.0–8.1 | `android-24`～`android-27`，tag `google_apis` |
| libghostty 构建目标以下 | `android-28;google_apis` |
| 16 KiB 页（新手机，native 库没对齐会加载失败） | `android-36;google_apis_ps16k` |

每台测出了什么见 `plan/v3/evidence/R04.md`。模拟器结果只算部分证据，不能代替真机。

## 4. 装到真机

手机开 USB 调试 → `adb devices` 显示 `device` 后，二选一：

```bash
flutter run -d <设备ID>                    # 调试着用，改代码能热重载
flutter build apk --release --target-platform android-arm64 \
  && adb install -r build/app/outputs/flutter-apk/app-release.apk   # 只装不调试；没配正式签名时用 debug 证书签
```

- 包名 `top.xdwa.xwshun`，和原版 Netcatty（`app.netcatty.mobile`）并存、数据互不影响。**别把 applicationId 改回去**，会覆盖原版。
- 包用 `~/.android/debug.keystore` 签名；换台电脑构建的包签名不同，`adb install` 报 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`，要先卸载（会清掉 App 数据）才能装。
- AI、云同步、检查更新默认关闭且不显示，开关在 `lib/application/fork_features.dart`。

装好之后怎么用，看 [使用手册](../user/README.md)。测试插件怎么构建、插件会话怎么在设备上验证，看 `plugins/README.md`。

## 5. 改任务状态

```bash
P=../.toolchain/pyenv/bin/python
$P plan/v3/scripts/set_status.py case <用例ID> <PASS|FAIL|...> --evidence evidence/<任务ID>.md
$P plan/v3/scripts/sync_docs.py       # 同步到 docs/08、09；别手改那两张表
$P plan/v3/scripts/validate_plan.py   # 只查计划本身，不测 App
```

## 6. 磁盘与清理

这台 Mac 常年只剩 5–15 GB。能删的（都在 `../.toolchain/`，删了可重建）：

| 目标 | 大小 | 删了会怎样 |
|---|---|---|
| `gradle-home/caches/9.1.0/transforms` | 1–3.5 GB | 下次构建在本机重建（spike release 17 秒→45 秒），构建一次又长回来。先 `(cd android && ./gradlew --stop)` |
| `gradle-home/` 整个 | 2.5–6 GB | 下次构建要联网重新下依赖 |
| `avd/<名字>.avd/*.img`、`*.qcow2` | 1–3 GB/台 | 关机后删；下次启动是空系统，装过的 App、Gboard 拼音设置都没了 |
| `baseline-495f5d31/` | 0.1 GB | 原版代码的 worktree，2026-09-29 已删。要重新构建原版时：`git worktree add ../.toolchain/baseline-495f5d31 495f5d3`，再 `chmod +x android/gradlew`（上游仓库里它没有可执行位，不加会报 Permission denied）。删用 `git worktree remove --force`，直接 rm 会留下失效记录 |
| `artifacts/` | 0.25 GB | 原版 debug APK（sha256 `339f4932…`，测原版共存、插件页「看不到这个包」诊断要用）；Tailscale 官方 OpenAPI 原件 `tailscale-openapi-b416d98e.yaml`（244 KB，删了就没法离线核对官方规范变没变，见 `plan/v3/docs/05`）；UU 远程的官方接入文档和官方 4.42.0 APK（`uuremote-*`，27 MB，App 里固定的官方证书就是从这个 APK 读的，删了没法复核，见 `plan/v3/docs/17`） |
| `plugin-keys/` | 8 KB | X02 测试插件的两把签名密钥。删了下次 `plugins/build-fixtures.sh` 会生成新的，设备上已批准的测试插件随之变「已拒绝（换签）」，在插件页撤销旧批准重新核对即可 |
| 整个 `.toolchain/` | — | 回到安装前，只剩下面 SDK 里的东西 |

共享 Android SDK 里为本项目装的：

```bash
S=$ANDROID_HOME/cmdline-tools/latest/bin     # sdkmanager 不在 env.sh 的 PATH 里，直接敲会 command not found
$S/sdkmanager --uninstall "ndk;28.2.13676358" "platforms;android-36" "build-tools;36.0.0" \
  "platforms;android-34" "cmake;3.22.1"      # 后两个是首次构建时 Gradle 自动装的
```

API 35 镜像是你原有的，`lizhi` 模拟器在用，**不要卸**。

## 7. 撞墙时

- **`git push` 报 `NO_PUSH_see_plan_v3`**：故意的，这个 fork 不 push。
- **zsh 里把命令存进变量再执行，报 `command not found: adb -s ...`**：zsh 不按空格拆变量，改用 `bash -c '...'` 或函数。
- **新 AVD 起不来，日志 `FATAL | Not enough space to create userdata partition ... need 7372.80 MB`**：
  首次启动要建 6 GB 数据盘，需要空闲 ≥ 7.2 GB（分区的 1.2 倍）；改 `config.ini` 的分区大小没用，会被改回。按第 6 节腾空间。
- **`flutter emulators --launch` 报 `Running multiple emulators with the same AVD`**：这台已在后台无窗口运行，先 `adb -s <ID> emu kill`。
- **`adb devices` 显示 `offline`**：还没启动完，等 `adb shell getprop sys.boot_completed` 输出 `1`（实测 18 秒到 2 分钟）。
- **adb 断开（`waiting for device`）又连上后，`emulator-5554` 可能已经不是本项目的模拟器了**：
  X06 时本项目的模拟器在 Mac 内存只剩几十 MB 时被关掉，同一个端口随即出现的是你自己无窗口启动的 `lizhi`，
  后面几条命令就打到了它上面（一次界面导出、一次点在桌面空白处，已删掉导出文件、确认桌面原样）。
  每次重连后先 `adb -s emulator-5554 emu avd name`，是 `xwshun-a35-4k` 才继续；两台同时开时内存也更紧。
  `lizhi` 开着的时候，本项目的模拟器用固定的另一个端口起，之后每条 adb 都带 `-s emulator-5580`，就不会串：
  `emulator -avd xwshun-a35-4k -port 5580 -no-window -no-snapshot -gpu host &`（X06 后半段这样跑的，构建时空闲内存 36%–47%，没再被关）。
- **模拟器里按电脑的 Esc，App 退回上一页**：模拟器键位表把 Esc 映射成了返回键，真机蓝牙键盘不会这样。用终端快捷键栏的 Esc。
- **Android 8.1 及更早的模拟器上 `adb logcat -c` 清不掉日志**（8.0 直接报 `failed to clear the 'main' log`）：
  按日志核对结果时别依赖清空，按"操作前已有几行"截取（`spikes/terminal_spike/tool/adb_key_check.sh` 就是这么做的）。
