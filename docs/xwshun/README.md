# xwshun 本机手册

Netcatty-mobile 的实验 fork（分支 `xwshun/v3`，remote `origin` = `uxiew/xwshun`，所有者说推之前不 push）。这里只讲在这台 Mac 上怎么跑、怎么测、怎么装、怎么清理。
App 怎么用看 [使用手册](../user/README.md)；做什么、做到哪看 `plan/v3/STATUS.md`。命令都在仓库根目录执行。

## 1. 先 source 环境

```bash
source ../.toolchain/env.sh     # 每开一个终端都要做；只影响当前终端
flutter --version               # 应为 3.44.4
zig version                     # 应为 0.16.0；终端引擎（libghostty）的原生库要它从源码编
```

不做的后果：`flutter test` 全部在 loading 阶段报 `HttpException: Connection closed before full header was received`
（shell 设了 `http_proxy` 没设 `no_proxy`）；`emulator -list-avds` 看不到本项目的 AVD（它们在 `../.toolchain/avd`）。

## 2. 测试

```bash
flutter test -j 4     # 全量约 1020 条（R19 时开着测试环境 988 条通过、32 条跳过：31 条是 tmux 环境没起、1 条只在 Windows 跑），约 3 分钟；没起测试环境时真实 SSH 的用例自动跳过。刚关模拟器、内存紧时不加 -j 4 可能被系统杀掉
flutter analyze       # 应为 No issues found（连 spikes/、packages/ 一起查）
```

真实 SSH/SOCKS/跳板的集成测试要先起 Docker 测试环境：

```bash
(cd tool/fixture-environment && ./up.sh && ./selfcheck.sh)   # selfcheck 8 项全 PASS
flutter test test/integration_ssh_fixture_test.dart
(cd tool/fixture-environment && ./down.sh)                   # 用完关掉，删除临时凭据
```

- 只用 `down.sh` 收尾，**别 `orb stop`**：OrbStack 里还跑着你别的项目。
- 测试环境的镜像里有 vim、less、htop、tmux（终端引擎的全屏程序用例要用），改了 `Dockerfile` 后 `up.sh` 会重新构建。
- 第一次跑测试会用 Zig 编 Ghostty 的原生库，多一分钟左右；`zig version` 不是 0.16 就会编译失败，见第 1 节。
- Ghostty 在设备上的验证（R17，`integration_test/ghostty_engine_test.dart`）：起好上面的测试环境，再
  `adb -s <设备> reverse tcp:22201 tcp:22201`，然后
  `flutter test integration_test/ghostty_engine_test.dart -d <设备> --dart-define=R17_SSH="$(python3 tool/fixture-environment/r17_config.py)"`。
  每次 `up.sh` 都换密码，参数要重新取。
- 测试环境细节见 `tool/fixture-environment/README.md`，终端引擎验证工程见 `spikes/terminal_spike/README.md`。
- 键盘和输入法的设备测试（R18，前三份只在模拟器上跑，第四份要真人在真机上，都要上面的测试环境）：
  - 横竖屏 + 真软键盘下终端不被挡、远端尺寸对（`integration_test/r18_keyboard_test.dart`）：跑法同上一条（`adb reverse` + `R17_SSH`），
    另开一个终端先预授权通知，不然一连上就弹「允许通知」挡住键盘：
    `until adb -s emulator-5580 shell pm grant top.xdwa.xwshun android.permission.POST_NOTIFICATIONS 2>/dev/null; do sleep 0.3; done`
  - 输入法回放（`integration_test/r18_ime_replay_test.dart`）：先 `(cd plugins && ./build-fixtures.sh)`，再 `tool/ime-replay.sh emulator-5580`。
    脚本装回放输入法、临时设成默认、预授权通知、跑完换回原输入法并卸载，见 `plugins/README.md`「R18 回放输入法」。
  - 硬件键和快捷键栏修饰键（`integration_test/r18_keys_test.dart`）：要模拟器有硬件键盘设备。关掉模拟器，把
    `../.toolchain/avd/xwshun-a35-4k.avd/config.ini` 的 `hw.keyboard = no` 改成 `yes`，重新起，再
    `tool/ime-replay.sh emulator-5580 "" integration_test/r18_keys_test.dart`；**测完改回 `no` 再重起**，
    不然软键盘默认不弹，别的设备测试会等不到键盘。
  - 真人在真机上用自己的输入法打拼音、说话（`integration_test/r18_voice_device_test.dart`，TER02）：要所有者当次同意、本人拿着手机。
    `tool/r18-real-device.sh xdwmbp /opt/homebrew/share/android-commandlinetools/platform-tools/adb 47131FDAP0040E`，
    约 4 分钟（构建安装 1 分多钟，6 项每项半分钟）。手机上出现「点一下这里叫出键盘」后照屏幕说明做，每项按一次回车。
    脚本不碰手机的输入法设置，开始结束各记一次默认输入法；测完 App 被卸掉。
- 粘贴、滑动、选字、链接、远端效果的设备测试（R19，`integration_test/r19_terminal_test.dart`，只在模拟器上跑过）：跑法同 R17 那条
  （测试环境 + `adb reverse` + `R17_SSH`），另开终端预授权通知（同下面 R18 那条）。
  `--plain-name "Ghostty：TER07"` 只跑一项。四项全跑约 1.5 分钟（不算构建）。会往模拟器剪贴板里写测试文字；打开链接换成了假的，不开浏览器。
  用到测试环境镜像里的 bash 和 tmux（R19 起镜像带 bash，改 Dockerfile 后 `up.sh` 自己重建）。
  真 bash 上的粘贴行为（bracketed paste 开关、断线不补发）在本机就能测：`test/integration_ssh_fixture_test.dart` 的「R19 粘贴到真 bash」。
- 终端输入面板的设备测试（R25，`integration_test/r25_input_panel_test.dart`，只在模拟器上跑过）：要上面的测试环境和回放输入法，经脚本跑
  `tool/ime-replay.sh emulator-5580 "" integration_test/r25_input_panel_test.dart`（脚本负责装回放输入法、转发 22201、预授权通知、跑完复原）。
  约 2 分钟（不算构建）。按键面板的键、回放输入法打进大输入框的字（微信语音、拼音）、发到真 bash 的效果都在远端逐字节核对；
  面板切换时远端收到几次窗口变化，用前台一个只数 SIGWINCH 的 bash 记到 `/tmp/r25-winch` 里，另开 exec 通道读。会把屏幕转成横屏再转回来。
  经 Mosh 的那一段在 `integration_test/mosh_session_test.dart` 的 `panel` 场景（跑法见下面 Mosh 那条，`X09_SCENARIO=panel`）。
- tmux 的测试（R21，`test/tmux_fixture_test.dart`）用另一套环境：四个真实 tmux 版本（2.4、2.7、3.0a、3.5a）加「没有 tmux」「假 tmux」两台，
  `(cd tool/tmux-fixture && ./up.sh)` 起、`./down.sh` 关，和上面那套互不影响、可以同时开；没起时整组跳过。细节见 `tool/tmux-fixture/README.md`。
- Tailscale SSH 的测试（`test/tailscale_ssh_login_test.dart`）要 Go：会自己构建、起停仿制服务器，没装 Go 时整组跳过。仿制服务器和「Headscale + 真 tailscaled」环境的用法见 `tool/tailscale-ssh-fixture/README.md`。
- 目录设备经四条路线连接的设备测试（R15，`integration_test/catalog_route_matrix_test.dart`）只在模拟器/真机上跑：`./up.sh routes` 后用同目录的 `route-matrix.sh`，见上面那份 README 的「R15」一节。
- Mosh（X08、X09）有自己独立的测试环境 `tool/mosh-fixture`（compose 项目 `xwshun-mosh`，SSH 22301、UDP 60101–60108，
  另有一台没装 mosh 的 22302），和上面那套互不影响。Mosh 插件 APK 怎么编见 `plugins/mosh/README.md`。
  - 桌面上（不要模拟器）：`(cd tool/mosh-fixture && ./up.sh)` 后 `flutter test test/mosh_fixture_test.dart`，13 条，约 10 秒。
    真实 OpenSSH + mosh-server 上的引导、指纹、密码错、缺 mosh-server、五种路线拒绝，计数来自测试环境的记账（`counts.sh`）。没起环境时整组跳过。
  - 模拟器上（X09，用户点「连接」的那条路 + 真插件）：先**关掉模拟器的 Wi-Fi**（原因见第 3 节「别用 10.0.2.2 连 TCP」那段），装插件，再跑：
    ```bash
    adb -s emulator-5580 shell svc wifi disable
    adb -s emulator-5580 install -r plugins/mosh/build/outputs/apk/release/mosh-release.apk
    flutter test integration_test/mosh_session_test.dart -d emulator-5580 \
      --dart-define=X09_MOSH="$(python3 tool/mosh-fixture/x08_config.py)" --dart-define=X09_SCENARIO=all
    adb -s emulator-5580 shell svc wifi enable      # 测完开回来
    ```
    `all` 约 45 秒（不算构建）；另有 `cycles`、`kill`（打出 `X09 kill.READY` 后在电脑上强杀插件）、`ime`（经 `tool/ime-replay.sh`，
    额外参数放 `IME_REPLAY_DEFINES`，写法见脚本开头）。
    多行的报告（阶段、屏幕）只有第一行带 `X09 ` 前缀，grep 时带上 `-A`。
  - **Mosh 插件换签名（包括以后换正式签名、删了 `plugin-keys` 重新生成）必须同步改宿主的 `lib/domain/plugins/official_plugins.dart`**：
    宿主只认那里登记的证书，别的证书签的包自称 `xwshun.mosh` 一律「已拒绝」、不给批准，真 Mosh 插件也一样被拒。
    新证书从安装包读：`$ANDROID_HOME/build-tools/36.0.0/apksigner verify --print-certs plugins/mosh/build/outputs/apk/release/mosh-release.apk`。
  - 插件已有会话时进出连接测试、会话测试不断开它（X12，`integration_test/x12_plugin_reuse_test.dart`）：同上关 Wi-Fi、装 Mosh 插件，
    另装 `plugins/out/echo-author.apk`，`--dart-define=X09_MOSH=…` 照上面取，约 25 秒（不算构建）。测试不 pkill、只看前后差值，
    别人开着的 mosh-server 不受影响。报告行以 `X12 ` 开头。

## 3. 模拟器

现在只留一台 `xwshun-a35-4k`（Android 15，4 KiB 页，自带 Gboard），用的是你原有的 API 35 镜像。

```bash
flutter emulators --launch xwshun-a35-4k    # 带窗口启动；首次启动会重建空系统
flutter run -d emulator-5554                # 设备 ID 以 flutter devices 为准
adb -s emulator-5554 logcat -s flutter      # 看 Dart 日志
adb -s emulator-5554 emu kill               # 关机
```

在模拟器里连本机的测试环境：先 `adb reverse tcp:22201 tcp:22201`（SOCKS 再加 21080、21081），App 里地址填 `127.0.0.1`。
别用 `10.0.2.2` 连 TCP：模拟器的默认网络是虚拟 Wi-Fi，经它连 `10.0.2.2` 的 TCP 能建上但收不到数据（Mac 上一个普通的 Python HTTP 服务也一样，
不是 OrbStack 的问题，X09 查实），App 会报「对方在登录前断开」，看着像配置错。UDP 经 `10.0.2.2` 是通的。
**Mosh 例外**：UDP 必须发往 SSH 实际连上的那个 IP，SSH 走 adb reverse 就成了 127.0.0.1，UDP 会发到模拟器自己身上。
这时 `adb shell svc wifi disable` 关掉 Wi-Fi，默认网络换成模拟器的蜂窝那张网卡，经 `10.0.2.2` 的 TCP 就正常了；测完 `svc wifi enable`。

**别在模拟器或本机上直连 `100.x`。** 这台 Mac 自己在真实 tailnet 上（`utun4`，`100.64/10` 走它），模拟器发出的连接也是 Mac 发的，
直连 100.x 等于往你的真实 tailnet 里拨号（R13 曾这样连过 `100.64.0.10`，那里恰好没有设备）。测试用的 tailnet 只经 SOCKS 或跳板去连，见 `tool/tailscale-ssh-fixture/README.md`。

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
tool/build-release.sh && adb install -r build/app/outputs/flutter-apk/app-release.apk   # 只装不调试；没配正式签名时用 debug 证书签
```

- 发布用的包一律走 `tool/build-release.sh`，别直接 `flutter build apk --release`：直接打会沿用缓存里的终端原生库，
  缓存被改了也照样打进包（实测翻一个字节，构建照常成功）。脚本先丢掉缓存、从核对过 SHA256 的源码重编，
  再查每个 `.so` 都是 16 KiB 对齐。要联网，比平时慢一两分钟。
- 包里只有 arm64-v8a：只有它在设备上测过，别的 ABI 在 `android/app/build.gradle.kts` 里排除了。

- 包名 `top.xdwa.xwshun`，和原版 Netcatty（`app.netcatty.mobile`）并存、数据互不影响。**别把 applicationId 改回去**，会覆盖原版。
- 包用 `~/.android/debug.keystore` 签名；换台电脑构建的包签名不同，`adb install` 报 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`，要先卸载（会清掉 App 数据）才能装。
- AI、云同步、检查更新默认关闭且不显示，开关在 `lib/application/fork_features.dart`。

手机接在另一台电脑上（现在的真机 Pixel 9 Pro 只接在 xdwmbp 上）：用 `tool/remote-device/`，见那里的 README。

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
| `avd/<名字>.avd/snapshots/` | 约 2.5 GB/台 | 快速启动的快照。我们都用 `-no-snapshot` 冷启动，删了没影响，装过的 App 和设置都在 |
| `baseline-495f5d31/` | 0.1 GB | 原版代码的 worktree，2026-09-29 已删。要重新构建原版时：`git worktree add ../.toolchain/baseline-495f5d31 495f5d3`，再 `chmod +x android/gradlew`（上游仓库里它没有可执行位，不加会报 Permission denied）。删用 `git worktree remove --force`，直接 rm 会留下失效记录 |
| `artifacts/` | 0.25 GB | 原版 debug APK（sha256 `339f4932…`，测原版共存、插件页「看不到这个包」诊断要用）；Tailscale 官方 OpenAPI 原件 `tailscale-openapi-b416d98e.yaml`（244 KB，删了就没法离线核对官方规范变没变，见 `plan/v3/docs/05`）；UU 远程的官方接入文档和官方 4.42.0 APK（`uuremote-*`，27 MB，App 里固定的官方证书就是从这个 APK 读的，删了没法复核，见 `plan/v3/docs/17`）；RustDesk 1.4.9 的清单、链接处理源码和 GitHub 发行版 APK（`rustdesk-*`，27 MB，固定的发行证书从这个 APK 读，同上） |
| `zig-cache/` | 0.1 GB 起 | Zig 编 Ghostty 的缓存，每多编一个平台涨一些。删了下次编要重新下 Zig 依赖 |
| `plugin-keys/` | 12 KB | 测试插件的两把签名密钥（`fixture-author`、`fixture-impostor`）和 X12 样例的作者密钥（`example-author`）。删了下次 `plugins/build-fixtures.sh` 会生成新的，设备上已批准的测试插件随之变「已拒绝（换签）」，在插件页撤销旧批准重新核对即可。**Mosh 插件也用 `fixture-author` 签，宿主把 `xwshun.mosh` 绑在这张证书上**（`lib/domain/plugins/official_plugins.dart`）：删了它、Mosh 插件换了证书，宿主就当它是冒充者直接拒，得同步改那个文件 |
| `mosh-build/` | 0.25–0.65 GB | X08 Mosh 运行时的源码包（60 MB，带 SHA256 核对）、交叉编译目录、装好的静态库（`prefix-arm64-v8a/`）和本机 protoc/tic（`host/`）。`build/` 下的编译目录随时可删（约 0.4 GB），只要 `prefix-*`、`host/` 在，`plugins/mosh/native/build-mosh-client.sh` 只重编 mosh 本身；整个删了要联网重下源码、从零编约 2 分钟 |
| 整个 `.toolchain/` | — | 回到安装前，只剩下面 SDK 里的东西 |

仓库里能删的（都在 `.gitignore` 里）：`build/`（约 1 GB）、`.dart_tool/flutter_build`（2–3 GB），下次构建重新生成；
`.dart_tool/hooks_runner`（约 0.5 GB）是终端原生库的构建缓存，删了下次构建要用 Zig 重编，多一两分钟。

- `flutter_build` 越跑越大：每次 `--dart-define` 的值不同（比如 `up.sh` 换了测试密码后再跑集成测试）就多一个约 120 MB 的子目录，
  10-06 攒到 24 个共 2.8 GB。只留最新的一个、其余删掉就行，正在构建时别删。
- 新开 worktree 时用 `cp -cR <主仓库>/.dart_tool/hooks_runner <worktree>/.dart_tool/` 带过去：`-c` 是 APFS 克隆，不占额外空间，也省得再用 Zig 重编。
- 空闲空间掉得比文件长得快时，看一眼 `sysctl vm.swapusage`：系统 swap 和数据盘共用同一块空间（10-06 用到 5.5 GB），
  模拟器、Gradle、Flutter 同时开着内存一紧，磁盘就跟着掉。

共享 Android SDK 里为本项目装的：

```bash
S=$ANDROID_HOME/cmdline-tools/latest/bin     # sdkmanager 不在 env.sh 的 PATH 里，直接敲会 command not found
$S/sdkmanager --uninstall "ndk;28.2.13676358" "platforms;android-36" "build-tools;36.0.0" \
  "platforms;android-34" "cmake;3.22.1"      # 后两个是首次构建时 Gradle 自动装的
```

API 35 镜像是你原有的，`lizhi` 模拟器在用，**不要卸**。

brew 为本项目装的（2026-10-04）：`zig@0.16` 和它依赖的 `llvm@21`、`lld@21`，共约 1.8 GB。
卸了（`brew uninstall zig@0.16 lld@21 llvm@21`）就编不了 libghostty 的原生库，主 App 接上 Ghostty 后连 App 都构建不了。

## 7. 撞墙时

- **`git push` 报 `Repository not found`**：`uxiew/xwshun` 在 GitHub 上还没建，或者这把 SSH 钥匙没有写权限。推送等所有者说，见 `docs/architecture/base-decision.md`。
- **zsh 里把命令存进变量再执行，报 `command not found: adb -s ...`**：zsh 不按空格拆变量，改用 `bash -c '...'` 或函数。`export ANDROID_SERIAL=emulator-5580` 后 adb 默认就打到那台，最省事。
- **`adb shell input text` 打字，分号后面的东西在模拟器上被当成命令执行了**：参数是交给模拟器的 shell 解释的，`;`、`$` 都会生效。整段用单引号包起来再传（`adb shell input text "'echo%s\$HOME'"`，`%s` 是空格），或者一次只打一条不带分号的命令。
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
- **跑过 `flutter test integration_test/...` 之后再 `adb install build/app/outputs/flutter-apk/app-debug.apk`，App 一打开就「isn't responding」**：
  集成测试会用测试入口重新构建并覆盖同一个 `app-debug.apk`，装的其实是测试包；而且测试跑完会把 App 卸掉（数据清空）。先重新 `flutter build apk --debug --target-platform android-arm64` 再装。
- **用 adb 注入按键（`input keyevent` / `input text`）之后，微信输入法的软键盘不出来了，只剩底部「收起」和「切换输入法」**：
  微信输入法收到注入的键就当接了实体键盘，切进实体键盘模式，重开 App、回桌面都不恢复，换到别的 App 打字也一样。
  在它的中文模式下，注入的字母还会先进拼音组字区：一行最多剩 60 字节，`_` 变成「——」，回车被拿去提交组字，Esc 被它吃掉。
  所以装着中文输入法的真机上，别用 adb 注入按键测终端（`spikes/terminal_spike/tool/adb_key_check.sh` 只适合 Gboard 或没弹键盘时）。
  恢复要用**一条**命令：`adb shell 'am force-stop com.tencent.wetype; ime set com.tencent.wetype/.plugin.hld.WxHldService'`。
  只 force-stop 的话，系统会把默认输入法换成 Gboard（R04 时发生过一次，马上改回了）。改之前后各跑一次
  `settings get secure default_input_method`（还有 `selected_input_method_subtype`、`enabled_input_methods`）对比，确认没变。
- **模拟器里按电脑的 Esc，App 退回上一页**：模拟器键位表把 Esc 映射成了返回键，真机蓝牙键盘不会这样。用终端快捷键栏的 Esc。
  用 sendevent 写扫描码也一样：`qwerty2.kl` 里扫描码 1 是 BACK，没有任何扫描码映射到 ESCAPE，模拟器上测不了硬件 Esc。
- **集成测试里等软键盘超时（「等待软键盘弹出超时」），截图上是「Allow xwshun to send you notifications?」**：
  每次 `flutter test` 都重装 App，一连上 SSH 就为前台保活服务申请通知权限，系统框挡在 App 前面，键盘出不来。按第 2 节预授权。
- **跑着跑着 `adb reverse` 没了，App 报连不上 127.0.0.1:22201**：`adb root` 会重启 adbd，端口转发跟着清掉。先 root 再 reverse
  （`tool/ime-replay.sh` 就是这个顺序）。
- **别用 `pkill -f flutter_tester` 收拾卡住的测试**：它会把别的 worktree、别的代理正在跑的测试一起杀掉（R18/R21 并行时撞过，
  对方的测试重跑四次都被中途杀掉）。只杀自己那条：`pgrep -f "flutter_tools.snapshot test <你的测试文件>"`。
- **几个代理共用一台模拟器时，锁被占着却没人在用**（10-07 撞了两次：锁占了 1.5 小时，设备上什么都没装）：
  后台等锁的循环自己 `mkdir` 抢到了锁，但等锁的代理没被叫醒，以为还在排队。排队的循环**只盯锁、不替你抢**，锁空了先叫醒代理，
  由代理自己拿锁；看到锁占着，先 `cat ../.toolchain/locks/emulator/owner` 看是谁，再看设备上 `pm list packages` 有没有它的 App，
  都没有动静就去问那个代理，别直接删别人的锁。另外两条：
  - **Gradle daemon 是共用的**（都在 `../.toolchain/gradle-home`），别人可能正在构建时别 `./gradlew --stop`，会把对方的构建停掉；
    收尾停 daemon 交给最后走的人。
  - 测试环境谁起谁关：`tool/fixture-environment`、`tool/mosh-fixture` 的 `up.sh` 每次都换密码和主机密钥，正在用它的人会全部连不上。
    别人起着的环境只读它的 `.run/` 配置借用，不 up、不 down、不 pkill，用完告诉起它的人。
- **widget 测试在 `tester.pump(时长)` 里卡死、CPU 100%**：flterm 在终端闲 250ms 后排一个「空闲优先级」任务压缩滚动区；
  这时如果还有动画在跑（比如刚点过按钮的水波纹），调度器推迟它、用零延时计时器反复重试，假时钟里一次 pump 不出帧，就成了死循环
  （真机上帧照常出，动画结束就放行，不会卡）。只用 `pump()` 不推进时间的测试碰不上；要推进时间的，在测试里设
  `tester.binding.schedulingStrategy = ({required priority, required scheduler}) => true`（`test/terminal_input_routing_test.dart` 有）。
  查这种卡死：`flutter test --start-paused`，用 vm_service 的 `getStack` 看卡在哪（R18 就是这么找到的）。
- **设备测试里远端逐字节收（`captureRemote`）读回来的字节缺一截、或者夹着不该有的字节**（R19 撞上的两种）：
  一是收之前切到了备用屏（测全屏程序），结果打在备用屏上，备用屏没有滚动区，比屏幕长的开头被挤掉——用 `postlude` 在打结果前切回来；
  二是从屏幕上抄回来的十六进制会混进旧行的残字（R19 时 xterm2 上撞的，同一次收的，exec 通道读文件是干净的）。
  要准确的字节，收完另开 exec 通道读 `/tmp/r18.bin`（`integration_test/r19_terminal_test.dart` 的 `capture`）。
- **两个测试文件都连 `tool/fixture-environment` 时，`-j 4` 全量跑互相搅乱**：`integration_ssh_fixture_test` 会数 ssh-edge 上的连接数、
  读 sshd 日志、pkill 全部会话，别的文件同时开会话就让它随机失败（R19 时 JMP01/JMP02、R10 两条）。连这个环境的测试都放进那一个文件。
- **模拟器里连 `10.0.2.2` 的 SSH 报 `Connection closed before authentication`，测试环境的 sshd 日志里却根本没有这条连接**：
  模拟器的虚拟 Wi-Fi 吃掉了发往 `10.0.2.2` 的 TCP（`toybox nc` 偶尔能收到一行版本号，换成真的 SSH 握手就断）。
  X09 先以为是 OrbStack，在 Mac 上垫了一个 TCP 中继、又起了个 Python HTTP 服务，都一样收不到；`adb shell svc wifi disable` 之后立刻正常。
  刚开机、Wi-Fi 还没接管默认网络的那十几秒里是通的，所以第一次试可能骗过你。见第 3 节。
- **关了 Wi-Fi 反而连不上 `10.0.2.2`，报 `Network is unreachable`（errno 101）**（R25 撞上的）：这次开机模拟器的蜂窝网络没注册上，
  `adb shell dumpsys telephony.registry | grep mDataRegState` 是 `OUT_OF_SERVICE`，关了 Wi-Fi 就一条网都没有。
  `adb emu gsm data home`、开关飞行模式、`svc data enable` 都没用；`emu kill` 后冷启动一次就是 `IN_SERVICE` 了。
  跑 Mosh 测试前先看一眼这一项，别把它当成 App 或测试环境的问题。
- **设备测试里点按键面板的键，结果切到了「文件」页**（R25 撞上的）：键被挡在看得见的范围外（面板太矮、后两行被剪掉），
  `tester.tap` 只给一句警告、照样在那个坐标点下去，点中的是底下的导航栏。R25 的设备测试打开了
  `WidgetController.hitTestWarningShouldBeFatal`，点不中就直接失败；新写设备测试也建议这样。
- **回放输入法的键盘只有 200dp，还盖住了底部导航栏**：终端页只被压掉一百来 dp。照「键盘压掉多少」开按键面板就太矮了，
  所以面板有最低高度（竖屏 256dp、横屏 156dp），见 `lib/presentation/screens/terminal_screen_input.dart`。
- **想数远端收到几次窗口变化，在交互 shell 里 `trap ... WINCH` 数不到**：断线恢复后的新 shell 是测试环境的 busybox sh，
  它的 WINCH trap 不记数（R25 第一次跑全是 0）。在前台跑一个只数 SIGWINCH 的 bash 往文件里记（`r25_input_panel_test.dart` 第 4 段）。
- **页面测试结束时报 `A Timer is still pending`，挂在 `_sendSize` 的 100ms 定时器上**：面板换回系统键盘后要给键盘空 700ms 的位置，
  到点终端变高、再发一次尺寸、再起一个 100ms 的合并定时器。测试里每步之后至少等 1.2 秒（`terminal_input_panel_test.dart` 的 `settle`）。
- **Android 8.1 及更早的模拟器上 `adb logcat -c` 清不掉日志**（8.0 直接报 `failed to clear the 'main' log`）：
  按日志核对结果时别依赖清空，按"操作前已有几行"截取（`spikes/terminal_spike/tool/adb_key_check.sh` 就是这么做的）。

## 8. 仓库里有什么

| 目录 | 内容 |
|---|---|
| `lib/` | App 本体（Flutter + Riverpod + dartssh2）。终端引擎只经 `lib/infrastructure/terminal/` 的适配层接入 |
| `android/` | Android 工程和原生代码：SSH 保活前台服务、画中画、手机目录授权、插件桥 |
| `packages/plugin_api/` | 插件契约 v1（Dart 端） |
| `plugins/` | 插件的 Android 契约与 SDK（`provider-sdk/`）、插件样例（`example/`）、真实的 Mosh 插件（`mosh/`），加上只用于测试的插件 APK |
| `third_party/` | 自己维护的上游 fork（现在是 libghostty / flterm），说明见 `third_party/README.md` |
| `tool/` | 发布构建脚本（`build-release.sh`）；测试工具：真实 SSH / 代理 / 跳板的 Docker 环境、多版本 tmux 环境（`tmux-fixture/`）、Tailscale 测试环境、假 Tailscale API、远程真机（`remote-device/`） |
| `spikes/` | 终端引擎验证工程（R04，现在用来在 Android 上验 fork），不进 App |
| `plan/v3/` | 计划、任务、用例、每批的实测证据 |
| `docs/` | 使用手册（`user/`）、本机手册（本文件）、插件作者文档（`plugin-authors/`）、基座决定（`architecture/`），其余是上游原来的开发文档 |
