# 手机接在另一台电脑上

真机只接在 xdwmbp（另一台 Mac）上时，用这个在本机直接跑 `adb`、`flutter run`、`flutter test integration_test`，
不用在那台电脑上装 Flutter、拷代码。

```bash
source ../.toolchain/env.sh
tool/remote-device/up.sh xdwmbp /opt/homebrew/share/android-commandlinetools/platform-tools/adb
source /tmp/xwshun-remote-device/env      # 每个要用手机的终端都执行一次
adb devices                               # 应该看到 47131FDAP0040E（Pixel 9 Pro）
flutter test integration_test -d 47131FDAP0040E
tool/remote-device/down.sh xdwmbp         # 用完拆掉
```

第二个参数是那台电脑上 adb 的完整路径。xdwmbp 上 adb 不在 PATH 里，不写的话会报 `adb: command not found`。

说白了：adb 分客户端和服务端，服务端得在接手机的那台电脑上跑。`up.sh` 用 SSH 把那边的服务端口（5037）
接到本机 15037，再让本机的 adb 客户端连 15037。这台 Mac 自己的模拟器（包括 `lizhi`）在这个终端里看不到，不会误碰。

真机上能做什么、不能做什么，按所有者每次的授权来（见 `plan/v3/evidence/R04.md` 开头）。

## 撞墙时

- **`flutter test` 报 `WebSocketChannelException ... Connection refused ... port = 5xxxx`，或者 `flutter drive` 一直卡着不动**：
  flutter 用 `adb forward` 把手机上的 VM service 转到"本机"端口，但 adb 服务在那台电脑上，监听口也开在那边，本机连不到。
  `up.sh` 做了一个假 SDK（全部软链接回真 SDK，只把 `platform-tools/adb` 换成 `adb-wrapper.sh`），
  每次 forward 时先经 SSH 在本机开同一个端口，再把端口交回 flutter。所以一定要 `source /tmp/xwshun-remote-device/env`，
  它把 `ANDROID_HOME` 指到假 SDK——flutter 按 `ANDROID_HOME` 找 adb，只改 PATH 没用。
  `flutter drive --host-vmservice-port` 想固定端口，实测（Flutter 3.44.4）没生效，补上转发后又卡住，别走这条路。
- **`unix_listener: ... too long for Unix domain socket`**：SSH 控制套接字路径太长（比如放在 scratchpad 下）。脚本固定用 `/tmp/xwshun-remote-device`。
- **`adb: failed to check server version: cannot connect to daemon at tcp:127.0.0.1:15037`**：隧道没起或断了，重新 `up.sh`。
- **用过之后直接 `./gradlew` 报 `SDK location not found`**：flutter 构建时把 `android/local.properties` 的 `sdk.dir` 写成了假 SDK，
  `down.sh` 之后它已经不在了。随便跑一次正常环境下的 `flutter build` 就会写回来，或者手动改回 `$HOME/Library/Android/sdk`。
- **`adb reverse`（手机连本机的测试服务）**：反向转发本来会落到接手机的那台电脑上，不是本机。包装脚本在 reverse 时再开一条 `ssh -R`，把那台电脑的同一个端口接回本机（R18 真机复测时手机连本机 22201 跑通）。那台电脑上这个端口已被占用时 reverse 直接失败，报「没能在 xdwmbp 上开 22201 端口接回本机」，先在那边 `lsof -nP -iTCP:22201 -sTCP:LISTEN` 看是谁占着。
- **真机 `adb logcat` 按"之前有几行"截取会漏行**：真机日志多，main 缓冲区只有 256 KiB，很快滚动。
  用 `adb logcat -d -v epoch` 按时间戳截，或者测试期间后台一直 `adb logcat ... >> 文件`。
- **测完 `flutter test` 会把被测 App 卸掉**（数据清空），这是 flutter 的行为，和远程无关。
