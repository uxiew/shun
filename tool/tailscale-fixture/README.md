# 假 Tailscale API（R11、R13 设备验证用）

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

## R13 目录页：用真实界面走一遍

`catalog_app_main.dart` 跑的是正式 App 的全部界面，只把目录 API 指到这里的假服务器。
给 `serve.dart` 传一个设备列表文件，它每次列设备都重新读这个文件，验证途中改文件就能模拟设备换地址、消失、列表不完整。

```bash
source ../.toolchain/env.sh
cat > /tmp/devices.json <<'JSON'
{"devices":[
 {"id":"2001","name":"edge.tail0000.ts.net.","hostname":"edge","addresses":["127.0.0.1"],"os":"linux","connectedToControl":true},
 {"id":"2003","name":"unknown.tail0000.ts.net.","hostname":"unknown","addresses":["127.0.0.2"],"os":"linux"},
 {"name":"缺 id 的条目会让列表记为不完整"}
]}
JSON
dart run tool/tailscale-fixture/serve.dart /tmp/devices.json
(cd tool/fixture-environment && ./up.sh)                 # 要真的 SSH 进去时才需要
adb reverse tcp:18480 tcp:18480 && adb reverse tcp:22201 tcp:22201
flutter build apk --debug -t tool/tailscale-fixture/catalog_app_main.dart && adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

App 里：设置 → Tailscale 设备目录 → 添加来源 → 粘贴 token 读一次（随便填，假服务器不校验）。
设备地址写 `127.0.0.1`、导入时端口填 22201，导入的主机就能真的 SSH 到测试环境的 ssh-edge。
验完 `adb uninstall top.xdwa.xwshun`（这个包的目录 API 指着本机，别留着当正式版用），`./down.sh` 关测试环境。

撞墙时：

- **`adb -s emulator-5554` 写进变量后报 `command not found`**：zsh 不按空格拆变量。改用 `export ANDROID_SERIAL=emulator-5554` 再直接敲 `adb`。
- **`adb shell run-as <包名> sh -c 'cd … && tar …'` 打出来的包有几个 GB**：单引号被本机 shell 吃掉，`cd` 没带参数，
  tar 实际跑在设备根目录。整条命令外面再包一层双引号：`adb exec-out "run-as top.xdwa.xwshun sh -c 'cd /data/data/top.xdwa.xwshun && tar cf - .'"`。
- **`monkey -p top.xdwa.xwshun …` 退出码 -5、App 没起来**：刚 `install -r` 完启动器还没刷新。直接 `am start -n` 指定 Activity。
- **模拟器上连 `100.64.x.x` 这类到不了的地址，报的是「登录完成前连接被对方关闭」而不是连不上**：
  模拟器的用户态网络先替设备接下 TCP 连接，再去连真实地址，连不上就把连接关掉，所以 App 看到的是「连上了又断开」。
  从 Mac 上 `nc -vz 100.64.0.10 22` 是超时。要验「到不了」用真机，或者在模拟器里连一个没人监听的回环端口（报 Connection refused）。
- **模拟器里 `127.0.0.2:22201` 也能连到 `adb reverse` 的 22201**：整个 127/8 都是回环。App 会按新地址重新要求核对指纹，这是对的，不是缺陷。
