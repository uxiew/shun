# xwshun 本地使用手册

Netcatty-mobile 的本地实验 fork（分支 `xwshun/v3`，不 push）。这里只讲在这台 Mac 上怎么跑、怎么测、怎么清理。
做什么、做到哪看 `plan/v3/STATUS.md`；上游功能看根目录 `README.md`。命令都在仓库根目录执行。

## 1. 先 source 环境

```bash
source ../.toolchain/env.sh     # 每开一个终端都要做；只影响当前终端
flutter --version               # 应为 3.44.4
```

不做的后果：`flutter test` 全部在 loading 阶段报 `HttpException: Connection closed before full header was received`
（shell 设了 `http_proxy` 没设 `no_proxy`）；`emulator -list-avds` 看不到本项目的 AVD（它们在 `../.toolchain/avd`）。

## 2. 测试

```bash
flutter test          # 全量约 394 条，约 2.5 分钟；没起测试环境时真实 SSH 那 33 条自动跳过
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

## 4. 装到真机与使用

手机开 USB 调试 → `adb devices` 显示 `device` → `flutter run -d <设备ID>`。

- 包名 `top.xdwa.xwshun`，和原版 Netcatty（`app.netcatty.mobile`）并存、数据互不影响。**别把 applicationId 改回去**，会覆盖原版。
- debug 包用 `~/.android/debug.keystore` 签名；换台电脑构建的包签名不同，要先卸载（会清掉 App 数据）才能装。
- AI、云同步、检查更新默认关闭且不显示，是有意的（`lib/application/fork_features.dart`）。
- 要先经代理再走跳板：把代理设在**目标主机**上（代理只用于连第一台跳板）。设在跳板机上会报错，不会被偷偷套用。
- 连接报错会写明是哪台机器、哪一步，比如「跳板机“hop2”（地址）转发失败（到 目标:端口）」。
- 服务器指纹变了会直接拒绝连接，没有「确认更新」。先向管理员核对；确认是正常换钥，就在弹窗里点「删除旧指纹」，再重连并重新核对。
- 连接等待页写着当前到哪一步（比如「第 2/3 跳，“hop2”：SSH 握手、核对指纹、登录」）。点「终止连接」后已连上的那几段马上断开，不会在后台连完。
- 断线自动恢复沿用这个标签**原来的**路线和账号。期间改了主机、跳板或代理，要关掉标签重新连才生效——自动恢复不会悄悄换路线。
- 断线（包括在 shell 里 `exit`）后，这个标签的 SSH 连接连同跳板会立刻释放；借它开的端口转发随之不可用，但条目还留在列表里，要手动停掉。

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
| `baseline-495f5d31/` | 0.1 GB | 原版代码的 worktree；用 `git worktree remove` 删，直接 rm 会留下失效记录 |
| `artifacts/` | 0.2 GB | 原版 debug APK（sha256 `339f4932…`），测原版与 fork 同机共存要用 |
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
- **模拟器里按电脑的 Esc，App 退回上一页**：模拟器键位表把 Esc 映射成了返回键，真机蓝牙键盘不会这样。用终端快捷键栏的 Esc。
- **Android 8.1 及更早的模拟器上 `adb logcat -c` 清不掉日志**（8.0 直接报 `failed to clear the 'main' log`）：
  按日志核对结果时别依赖清空，按"操作前已有几行"截取（`spikes/terminal_spike/tool/adb_key_check.sh` 就是这么做的）。
