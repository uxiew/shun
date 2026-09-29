# xwshun 本地使用手册

这是 Netcatty-mobile 的本地实验 fork（分支 `xwshun/v3`，不 push）。这份手册讲**在这台 Mac 上怎么把它跑起来、怎么测、怎么清理**。
做什么、为什么做看 `plan/v3/`；上游功能说明看仓库根目录的 `README.md` 和 `docs/DEVELOPMENT.md`。

下面所有命令都在仓库根目录 `netcatty-mobile/` 下执行，并且**先执行第 1 步**。

## 1. 每次开终端先做这一步

```bash
source ../.toolchain/env.sh
flutter --version   # 应显示 Flutter 3.44.4
```

`env.sh` 只改当前终端，不动 `~/.zshrc`。它做了这些事：把项目自带的 Flutter、JDK 17、adb、emulator 放进 PATH；
把 pub / Gradle 缓存和模拟器 AVD 指到 `../.toolchain/` 里；补上 `NO_PROXY=127.0.0.1,localhost,::1`。

不 source 会怎样：

- `flutter: command not found`，或者用上了系统里别的 Flutter 版本。
- `flutter test` 全部在 loading 阶段失败，报 `HttpException: Connection closed before full header was received, uri = http://127.0.0.1:xxxx`。
  原因是这台机器的 shell 设了 `http_proxy`，没设 `no_proxy`，测试框架连本机的请求被代理截走了。
- 列不出模拟器：AVD 放在 `../.toolchain/avd`，不在默认的 `~/.android/avd`。

## 2. 跑测试

```bash
flutter test                  # 主 App 全量 270 条；没起测试环境时 260 过、10 跳过，本机约 2.5 分钟
flutter analyze               # 应输出 No issues found；会连 spikes/、packages/ 下的代码一起检查
```

真实 SSH / SOCKS 的集成测试需要先起 Docker 测试环境（本机用 OrbStack），否则这 9 条会自动 skip：

```bash
(cd tool/fixture-environment && ./up.sh && ./selfcheck.sh)   # selfcheck 应 8 项全 PASS
flutter test test/integration_ssh_fixture_test.dart
(cd tool/fixture-environment && ./down.sh)                   # 用完关掉，会删除临时凭据
```

测试环境的拓扑、端口和各种坑写在 `tool/fixture-environment/README.md`，这里不重复。

已知会失败或会让进程崩溃的用例默认跳过。想看实际失败现场时加 `XWSHUN_RUN_KNOWN_FAILS=1`：

```bash
XWSHUN_RUN_KNOWN_FAILS=1 flutter test test/integration_ssh_fixture_test.dart
```

Ghostty 终端引擎的验证工程是独立的，用法见 `spikes/terminal_spike/README.md`。

## 3. 在模拟器上跑

模拟器都是 arm64 的，在 Apple Silicon 上原生运行，不用翻译层。这里只列查看和启动的方法；**模拟器的结果只算部分证据，不能代替真机**。

```bash
emulator -list-avds                          # 列出 ../.toolchain/avd 里的 AVD
flutter emulators --launch xwshun-a35-4k     # 带窗口启动，可以用鼠标和键盘手动操作
flutter devices                              # 启动好以后能看到 emulator-55xx
```

| AVD | 系统 | 内存页大小 | 用途 |
|---|---|---|---|
| `xwshun-a35-4k` | Android 15（API 35），Google APIs，自带 Gboard | 4 KiB | 日常运行、按键和输入法 |

在模拟器里跑主 App：

```bash
flutter run -d emulator-5554        # 设备 ID 以 flutter devices 显示的为准
```

常用 adb 操作（只有一台设备时可以省略 `-s`）：

```bash
adb -s emulator-5554 install -r build/app/outputs/flutter-apk/app-debug.apk
adb -s emulator-5554 exec-out screencap -p > shot.png        # 截图
adb -s emulator-5554 logcat -s flutter                       # 看 Dart 里的 print / debugPrint
adb -s emulator-5554 emu kill                                # 关掉模拟器
```

AVD 的配置里关掉了宿主麦克风（`hw.audioInput=no`），模拟器不能通过 Mac 的麦克风收音。需要测语音输入就只能上真机。

## 4. 装到真机

1. 手机开启"开发者选项 → USB 调试"，插线，手机上点"允许"。
2. `adb devices` 能看到设备，并且状态是 `device`，不是 `unauthorized`。
3. 执行 `flutter run -d <设备ID>`，或者 `flutter build apk --debug` 后执行 `adb install -r build/app/outputs/flutter-apk/app-debug.apk`。

包名是 `top.xdwa.xwshun`，桌面图标名是 xwshun。它和手机上的原版 Netcatty（`app.netcatty.mobile`）是两个独立的 App，
互不覆盖，数据也不共享。**不要把 applicationId 改回 `app.netcatty.mobile`**，否则安装时会覆盖原版并影响原版数据。

debug 包用本机的 Android 调试证书（`~/.android/debug.keystore`）签名，只适合自己装着试。
换一台电脑构建出来的包签名不同，必须先卸载旧的才能装上，卸载会清掉 App 里的数据。正式签名和分发方式还没定。

AI 助手、云同步和检查更新在这个 fork 里默认关闭，设置页也不显示这几项，这是有意的（见 `lib/application/fork_features.dart`）。

## 5. 看进度、改状态

- 当前进度看 `plan/v3/STATUS.md`，每个任务实际做了什么看 `plan/v3/evidence/<任务ID>.md`。
- 状态只在 JSON 里改，然后同步到文档，最后做校验：

```bash
P=../.toolchain/pyenv/bin/python
$P plan/v3/scripts/set_status.py case <用例ID> <PASS|FAIL|...> --evidence evidence/<任务ID>.md
$P plan/v3/scripts/sync_docs.py      # 把 JSON 里的状态同步进 docs/08、docs/09
$P plan/v3/scripts/validate_plan.py  # 检查 ID、依赖、schema；它不测 App
```

别手改 `docs/08`、`docs/09` 表格里的状态列，下次运行 sync 会被覆盖。也别用 `json.dump` 自己重写 JSON：
缩进一变，整份文件就是几千行 diff，没法审查。

## 6. 磁盘占用和清理

所有工具都在仓库外的 `../.toolchain/`。整个目录删掉，就恢复到安装前的状态（只剩下面第二张表里那几项）。

| 目录 | 大约 | 是什么 | 删掉后 |
|---|---|---|---|
| `gradle-home/` | 6 GB | Gradle 依赖和构建缓存 | 下次构建重新下载，首次构建会慢 |
| `baseline-495f5d31/` | 0.1 GB（构建一次会涨到 2 GB） | 上游原版代码的 git worktree，用来对照原版行为 | 先执行 `git worktree remove ../.toolchain/baseline-495f5d31`，直接删目录会让 git 以为 worktree 还在 |
| `artifacts/` | 0.2 GB | 留作证据的安装包，目前只有原版 debug APK（sha256 `339f4932…`，和 R01 证据一致） | 做"原版和 fork 同机共存"测试时要重新构建原版 |
| `avd/` | 每个 AVD 1.5–3 GB | 模拟器的用户数据 | 模拟器就没了，重建一个几分钟 |
| `flutter/` | 1.1 GB | Flutter SDK | 什么都跑不了 |
| `pub-cache/` | 0.3 GB | Dart 依赖包 | 执行 `flutter pub get` 重新下载 |

下面这些**不在** `.toolchain` 里，而是装在共享的 Android SDK（`~/Library/Android/sdk`）里，都是 2026-09-29 为这个项目装的：

| 项 | 怎么来的 | 卸载命令 |
|---|---|---|
| NDK 28.2、platform 36、build-tools 36 | 经你同意手动安装 | `sdkmanager --uninstall "ndk;28.2.13676358" "platforms;android-36" "build-tools;36.0.0"` |
| platform 34、CMake 3.22.1 | 第一次构建时 Gradle 自动装的 | `sdkmanager --uninstall "platforms;android-34" "cmake;3.22.1"` |
| 模拟器系统镜像（`system-images/` 下，每个 3–5 GB） | 为模拟器验证下载 | `sdkmanager --uninstall "system-images;android-XX;<tag>;arm64-v8a"` |

`sdkmanager` 在 `~/Library/Android/sdk/cmdline-tools/latest/bin/`。
API 35 的 `google_apis` 镜像是你原来就有的，你自己的 `lizhi` 模拟器也在用它，**不要卸载**。

## 7. 撞墙时

- **`git push` 报错 `NO_PUSH_see_plan_v3`**：这是故意设置的，防止误推到上游。这个 fork 不 push。
- **把命令存进 zsh 变量再执行，报 `command not found: adb -s emulator-5554 shell`**：zsh 不会把变量按空格拆开。
  这种写法请用 bash（`bash -c '...'`），或者写成函数。
- **`flutter emulators --launch` 报 `Running multiple emulators with the same AVD`**，或者没弹出窗口：
  这个 AVD 已经在后台以无窗口方式运行了，自动化验证就是这样启动的。先执行 `adb devices` 看它的设备 ID，
  需要窗口的话先执行 `adb -s <设备ID> emu kill` 关掉它，再重新 launch。
- **模拟器启动后 `adb devices` 显示 `offline`**：还没启动完。等 `adb shell getprop sys.boot_completed` 输出 `1`，冷启动大约 20 秒。
- **磁盘不够**：这台 Mac 可用空间只有 10 GB 左右。一个模拟器镜像 3–5 GB，再加 AVD 数据 1–3 GB。先看第 6 节删掉不用的。
