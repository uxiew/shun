# Mosh 运行时插件（X08）

独立安装的 APK（`top.xdwa.shun.mosh`，pluginId `shun.mosh`），给主 App 提供 Mosh 终端会话。
里面是官方 mosh-client 1.4.0 的 Android 交叉编译版，每个会话一个子进程，经 PTY 接到宿主给的 socketpair 上。
为什么选它、不选 Dart 的 dart_mosh，见 `docs/decisions/mosh-runtime-decision.md`；来源、许可、ABI 见同目录 `LICENSES.md`。

X08 做了运行时（能装、能和真 mosh-server 互通、生命周期不拖垮宿主）；X09 在主 App 里接上了：主机协议选 Mosh 后，
宿主经 SSH 受控启动 mosh-server（只许直连），把数字 IP、端口、临时 key 交给本插件。怎么用见使用手册第 17 节「用 Mosh 连接」，
宿主那边的设备测试见 `integration_test/mosh_session_test.dart`。后台存活、网络切换是 X10。

## 构建

```bash
source ../../../.toolchain/env.sh             # 在 plugins/mosh/ 下；要 NDK 28、SDK 里的 cmake 3.22.1
native/build-mosh-client.sh                   # 编 mosh-client（第一次下载约 60 MB 源码，约 2 分钟）
cd .. && ../android/gradlew -p . -q :mosh:assembleRelease \
  -PhostSha256=<宿主证书 SHA-256> -PsignWith=author   # 宿主证书怎么取见 ../build-fixtures.sh
# 产物：mosh/build/outputs/apk/release/mosh-release.apk（约 2.8 MB，只有 arm64-v8a）
```

- 没先跑 `native/build-mosh-client.sh` 就构建 APK：报 `缺运行时 …libmoshclient.so`。故意的，不打一个缺运行时的包。
- 编译目录在仓库外 `../../../.toolchain/mosh-build/`，可以删（见本机手册第 6 节）；`FORCE=1` 全部重编。
- 签名现在用测试作者密钥（`plugin-keys/fixture-author.jks`，证书 SHA-256 `7feb5825…6e9d`，2026-10-15 重新生成），正式签名等所有者定。宿主第一次看到它要用户批准证书。
- **宿主把 pluginId `shun.mosh` 绑在这张证书上**（`lib/domain/plugins/official_plugins.dart`）：别的证书签、自称 `shun.mosh` 的包直接「已拒绝」。
  换签名（正式签名、或 `plugin-keys` 被删后重新生成）必须同步改那个文件，不然这个插件自己也会被当成冒充者拒掉。

## 会话 key 怎么交给 mosh-client

宿主 bootstrap 拿到 key → Binder（`openMoshSession` 的 byte[]，宿主和插件两边用完都清零）→ JNI 在 fork 之前把 22 个字节
写进一根管道、关掉写端 → 子进程把读端放到 fd 3 → mosh-client 按 `MOSH_KEY_FD=3` 读走、关掉（补丁 0002）。
不进命令行参数，不进环境变量，不写文件，不进日志。剩下的风险：mosh-client 进程内存里有 key（它要用）；
Binder、平台通道自己的缓冲我们清不到。

## 为什么运行时叫 `libmoshclient.so`

它其实是可执行文件。Android 10 起 App 不能 exec 自己可写目录里的文件；能 exec 的只有系统安装时解出的
`nativeLibraryDir`（只读），而系统只解出 `lib*.so`。所以：名字必须是 `lib*.so`，`useLegacyPackaging = true` /
`extractNativeLibs="true"` 必须开着。关了的话 APK 照样能装，但打开会话时报
`运行时起不来：…No such file or directory`（nativeLibraryDir 里没有文件）。

## 设备上验证

在仓库根目录：

```bash
(cd tool/mosh-fixture && ./up.sh)
adb -s emulator-5580 reverse tcp:22301 tcp:22301        # SSH bootstrap 走 adb reverse
adb -s emulator-5580 install -r plugins/mosh/build/outputs/apk/release/mosh-release.apk
flutter test integration_test/mosh_runtime_test.dart -d emulator-5580 \
  --dart-define=X08_MOSH="$(python3 tool/mosh-fixture/x08_config.py)" --dart-define=X08_SCENARIO=interop
```

| 场景 | 看什么 | 要在电脑上配合 |
|---|---|---|
| `interop` | 提示符、echo、中文、vim、改尺寸（stty size）、关会话后远端 mosh-server 退出 | 无 |
| `exit` | 远端 shell 退出：会话自己收尾为 closed，mosh-server 不留 | 无 |
| `multi` | 两个会话互不串、关一个另一个照常 | 无 |
| `cycles` | 连开连关 10 次：宿主 fd 不涨、远端不留进程 | 打出 `X08 cycles.READY` 后 `adb shell ps -A \| grep -c libmoshclient` 应为 0 |
| `kill` | 强杀插件：会话记插件死亡，宿主和它的 SSH 照常 | 打出 `X08 kill.READY` 后 `adb shell run-as top.xdwa.shun.mosh kill -9 $(adb shell pidof top.xdwa.shun.mosh)` |
| `hostkill` | 强杀宿主：插件按协议关掉它的会话，远端 mosh-server 退出 | 打出 `X08 hostkill.READY` 后 `adb shell run-as top.xdwa.shun kill -9 $(adb shell pidof top.xdwa.shun)`，再在电脑上数 mosh-server |
| `echo-mosh` | 把 Mosh 材料发给不支持的 echo：宿主报错不崩；Dart 层因为没申请权限根本不发 | 先装 `plugins/out/echo-author.apk` |

每次 `flutter test integration_test/...` 都会重装主 App（数据清空），批准由测试自己写入。

## 模拟器到 Mac 上 mosh-server 的 UDP

见 `plan/v3/evidence/X08.md`「设备上的 UDP 通路」。结论写在那里，这里不重复。

## 撞墙时

- **会话打开就失败 `运行时起不来`**：先看 `adb logcat -s ShunMosh`。`不可执行` 说明 APK 没解出运行时（见上）。
- **会话 active 了但一直没有画面**：mosh-client 收不到服务器的 UDP。它自己会在屏幕顶上显示
  `mosh: Nothing received from server on UDP port …`。查 UDP 通路，别查 SSH。
- **关会话后远端还留着 mosh-server**：插件被强杀时可能会这样（mosh 的设计：服务器等客户端回来）。
  实测多数时候不留：插件一死 PTY 主端被关，内核给 mosh-client 发 SIGHUP，它还来得及通知服务器（X08、X09 都是 3 秒内远端归零）；
  但不保证，所以宿主在标签里提示「远端可能还有旧会话」。
- **宿主报「mosh-client 没能正常收尾（退出码 1）」**：mosh-client 自己的「没能正常收尾」，最常见是 UDP 到不了服务器——
  它等 15 秒没收到服务器的包就开始退出（模拟器上从打开到退出约 20 秒）。终端里它自己打印的 `mosh did not make a successful connection` 更具体。
