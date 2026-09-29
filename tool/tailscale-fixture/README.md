# 假 Tailscale API（R11 设备验证用）

在本机起一个只会两个端点的假 API，让模拟器/真机上的 App 代码真的发一遍请求，看它发了什么。
没有真实 Tailscale 账号时只能这么验；它证明的是 App 发了什么、怎么处理响应，不证明 Tailscale 服务器的行为。

```bash
source ../.toolchain/env.sh
dart run tool/tailscale-fixture/serve.dart          # 前台运行，每个请求打一行 JSON
adb reverse tcp:18480 tcp:18480 && adb reverse tcp:18481 tcp:18481
flutter build apk --debug -t tool/sec05/tailscale_seed_main.dart && adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n top.xdwa.xwshun/app.netcatty.mobile.MainActivity
adb logcat -s flutter | grep "R11 seed"             # 三条路径的结果摘要
```

- 18480 是假 API；tailnet 写成 `redirect-me` 时回 302 指向 18481。
- 18481 收到任何请求都会打一行带 `"STOLEN":true` 的日志——出现就说明 App 跟随了重定向，是缺陷。
- 日志不含凭据原文：Authorization 只记「是不是本服务发出的 token」，token 端点只记表单参数名和 scope。
- 种子入口和正式 App 同一个包名，会**覆盖设备上这个 App 的数据**，只在测试设备/模拟器上跑。
  验完装回正式版：`flutter build apk --debug && adb install -r build/app/outputs/flutter-apk/app-debug.apk`。

撞墙时：

- **`adb -s emulator-5554` 写进变量后报 `command not found`**：zsh 不按空格拆变量。改用 `export ANDROID_SERIAL=emulator-5554` 再直接敲 `adb`。
- **`adb shell run-as <包名> sh -c 'cd … && tar …'` 打出来的包有几个 GB**：单引号被本机 shell 吃掉，`cd` 没带参数，
  tar 实际跑在设备根目录。整条命令外面再包一层双引号：`adb exec-out "run-as top.xdwa.xwshun sh -c 'cd /data/data/top.xdwa.xwshun && tar cf - .'"`。
- **`monkey -p top.xdwa.xwshun …` 退出码 -5、App 没起来**：刚 `install -r` 完启动器还没刷新。直接 `am start -n` 指定 Activity。
