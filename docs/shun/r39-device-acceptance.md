# R39 Android 设备验收

从仓库根目录执行。**脚本尚待设备实跑；下面是预期流程，不是通过证据。** 实际结果只记录在 `plan/v3/evidence/R39.md`。

## 准备与执行

1. 先准备项目专用 SDK `../.toolchain/android-sdk`，不要更新其他项目正在用的 SDK。组件包括 `platform-tools`、`emulator`、`platforms;android-36`、`build-tools;36.0.0`、`ndk;28.2.13676358`、`cmake;3.22.1` 和 API 35 arm64 系统镜像。安装前先留约 20 GiB；安装完后脚本仍要求至少 12 GiB 构建余量。脚本不会自动下载组件、接受许可证或删除文件腾空间。
2. 用该 SDK 创建并启动专用 `../.toolchain/avd/shun-a35-4k.avd`，端口固定 5580，`ANDROID_AVD_HOME` 指向 `../.toolchain/avd`。不要使用本机手册中的旧共享 SDK 启动方式。本验收会核对模拟器标志、API 35、AVD 目录及运行进程的 SDK 路径，不接受真机或其他同名 AVD。
3. 使用已固定的 mise Zig 0.16.0；Flutter/JDK 默认本机路径，可用 `FLUTTER_SDK` / `JAVA_HOME` 指定。下载前按本机配置启用 `proxy`，不改全局 SDK 配置；驱动连接本机 VM 时单独移除代理变量。

```bash
python3 tool/r39-device.py check
SHUN_R39_DISPOSABLE=1 python3 tool/r39-device.py run
```

`check` 只检查环境。`run` 构建新测试 APK，不复用可能过期的二进制；核验包名和证书后安装。开始前以下四个包必须未安装，已有任何一个就停止，不覆盖数据：

- `top.xdwa.shun`
- `com.netease.uuremote`（本轮安装的是 fakeUU）
- `com.carriez.flutter_hbb`（本轮安装的是 fakeRustDesk）
- `example.shun.fixture.echo`

只构建这三个 fixture，不构建所有插件变体。独立测试作者签名放在 `../.toolchain/plugin-keys/fixture-author.jks`，沿用既有 fixture 公共口令，不能用于正式发布。完成或失败后，只卸载本轮安装且证书未变的包；不删除 AVD、不关闭其他模拟器、不改生产信任名单。

## 四阶段与证据边界

| 阶段 | 预期验证 |
|---|---|
| seed | 向真实 Android 加密存储写入旧 v1 格式，含绑定、目录来源和有效待回调；不先初始化 v2 控制器。 |
| migrate | 另一进程迁移并核对 ID、归属和到期时间；删除源 SSH 后独立条目保留；宿主在请求仍 pending 时强制结束进程。 |
| cold | Android callback Intent 启动新进程，之后 drive 连接已有 VM；回调确认前不换绑定，确认后保存，重复回调不再生成 offer。 |
| verify | 再冷启动核对持久化与显式目录关联；六种类型保存/重开；通过真实 Android 桥向假客户端发起，检查前台包。 |

四个阶段必须有不同 PID（进程号）和同一 runId。`migrate` 的驱动断开只有在匹配本轮 runId、PID 和 `kill-ready` 后才算预期中断；其他超时/断开均失败。

旧格式注入不等于“安装上一版发行 APK 后升级”。假客户端接到请求不等于真实远控成功；不连接真实主机、登录真实账号或安装官方远控客户端。

证据写入 `../.toolchain/artifacts/r39-device-<时间>/`，包含构建/阶段日志、四个进程报告、列表截图、源码/APK SHA256 和应用私有文件明文扫描结果。回调 URI 不写宿主日志；不导出真实用户存储。

## 脚本本身的回归

```bash
python3 -m unittest discover -s tool/tests -p test_r39_device.py -v
flutter test --no-pub test/r39_fixture_test.dart
```

这些测试只验证安全检查与合成配置，不是 Android 设备验收通过的依据。
