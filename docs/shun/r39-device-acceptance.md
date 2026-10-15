# R39 Android 设备验收

从仓库根目录执行。**已在 Android 30 跑到第四阶段：前三阶段通过，表单脚本过早读取异步保存结果而失败；等待修复已过本机测试，设备复验未完成。** 实际结果只记录在 `plan/v3/evidence/R39.md`。

## 准备与执行

1. 先检查现有 Homebrew Android 工具，**不重复安装或升级已有组件**。`../.toolchain/android-sdk` 可用符号链接复用已有 `platform-tools`、`emulator`、`cmdline-tools`、`system-images`，已有 `platforms` / `build-tools` 版本也逐个复用。仅补缺少的 Android 36/35 平台、build-tools 36.0.0、NDK 28.2.13676358、CMake 3.22.1；不能对共享 SDK 执行 `--update`。全新 Gradle/Android 缓存本机实际消耗较大，建议准备约 30 GiB，不再按 20 GiB 估算；安装后脚本仍要求至少 12 GiB 构建余量。脚本不下载 SDK、接受许可证或删除文件腾空间，并通过 `ORG_GRADLE_PROJECT_android.builder.sdkDownload=false` 禁止 Gradle 自动补装；缺组件时报错后先检查已有副本。
2. `ANDROID_AVD_HOME` 指向 `../.toolchain/avd`，端口固定 5580。默认配置是 `shun-a35-4k`（API 35）；已有 Android 30 arm64 镜像时，可创建独立的 `shun-r39-a30`，通过 `SHUN_R39_AVD=shun-r39-a30` 选择，避免下载另一份镜像或升级共享模拟器。编译 SDK 36 不要求运行镜像也是 36。本验收核对所选配置的 API、模拟器标志、项目 AVD 目录及模拟器真实二进制路径（解析复用符号链接），不接受真机、未知配置或其他同名 AVD。API 30 的结果不能冒充 API 35 或真机验证。
3. 使用已固定的 mise Zig 0.16.0；Flutter/JDK 默认本机路径，可用 `FLUTTER_SDK` / `JAVA_HOME` 指定。下载前按本机配置启用 `proxy`，不改全局 SDK 配置；驱动连接本机 VM 时单独移除代理变量。

2026-10-15 本机复用的是 Homebrew ADB 37.0.1、模拟器 32.1.15 和 API 30 镜像 r10，未升级它们。当前代理无法完成 `dl.google.com` 的 TLS 握手，但 Google 官方别名 `dl-ssl.google.com` 可用：SDK 安装命令临时设置 `SDK_TEST_BASE_URL=https://dl-ssl.google.com/android/repository/`；项目专用 `../.toolchain/gradle-home/init.d/r39-google-alias.gradle` 只将 Google Maven 的同路径 HTTPS 主机名替换为该别名。Java 下载通过当前命令的 `JAVA_TOOL_OPTIONS` 设置代理与 localhost 例外。没有关闭 TLS/校验、使用第三方镜像或修改应用 RoutePlan；换网络后先实测，不把这个局部配置复制成全局设置。

```bash
python3 tool/r39-device.py check
SHUN_R39_DISPOSABLE=1 python3 tool/r39-device.py run

# 复用已有 Android 30 镜像时，两条命令均选择受限的备用配置：
SHUN_R39_AVD=shun-r39-a30 python3 tool/r39-device.py check
SHUN_R39_AVD=shun-r39-a30 SHUN_R39_DISPOSABLE=1 python3 tool/r39-device.py run
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

真实存储是异步的：页面 `pumpAndSettle` 结束不等于父页面已经保存完。表单测试使用有截止时间的 `r39WaitFor` 等待可观察状态发布后再读回；超时必须失败，不能只延长固定 sleep 或吞掉 `singleWhere` 异常。

旧格式注入不等于“安装上一版发行 APK 后升级”。假客户端接到请求不等于真实远控成功；不连接真实主机、登录真实账号或安装官方远控客户端。

证据写入 `../.toolchain/artifacts/r39-device-<时间>/`，包含构建/阶段日志、四个进程报告、列表截图、源码/APK SHA256 和应用私有文件明文扫描结果。回调 URI 不写宿主日志；不导出真实用户存储。

## 脚本本身的回归

```bash
python3 -m unittest discover -s tool/tests -p test_r39_device.py -v
flutter test --no-pub test/r39_fixture_test.dart test/r39_ui_wait_test.dart
```

这些测试只验证安全检查与合成配置，不是 Android 设备验收通过的依据。
