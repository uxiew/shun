# Mosh 运行时选择（X08）

决定日期：2026-10-04。由 X08 实施代理根据实测做出，等所有者知悉；推翻它要重跑本文「怎么复核」里的对比。

## 结论

**生产运行时用官方 mosh-client 1.4.0（C++），从源码交叉编译，随独立插件 APK 安装；每个会话一个子进程，经 PTY 接到宿主的 socketpair。**
不用 Dart 的 `dart_mosh 0.0.4`。只保留这一套，不做双实现切换。

## 两个候选

| | Dart：`dart_mosh 0.0.4`（Conduit 在用） | Native：官方 `mosh-client 1.4.0` |
|---|---|---|
| 是什么 | 纯 Dart 重写的 Mosh UDP 协议层（2744 行），不含 SSH 和终端 | mosh 项目自己的客户端，自带终端模型和本地预测 |
| 来源与维护 | pub.dev，单一作者，0.0.1 到 0.0.4 都发在 2026-06-05 至 06-22；自称 clean-room、未独立审计 | 2022-10 发布，Debian/Alpine/Termux/Homebrew 都在打包；协议本身就是它定义的 |
| 许可 | Apache-2.0（依赖 pointycastle） | GPL-3.0-or-later + OpenSSL 链接例外（宿主本来就是 GPL-3.0-or-later，见 `plugins/mosh/LICENSES.md`） |
| 怎么进独立 APK | 插件里要带一套 Flutter 引擎（arm64 release 的 `libflutter.so` 未压缩 163.8 MB，引擎 jar 压缩后 41.7 MB）、自己的 AOT 代码，再写 Kotlin 桥把 socketpair 接进 isolate | 一个 6.2 MB 的可执行文件 + 10 KB 的 JNI，整包 2.8 MB |

## 实测对比

都连同一台真 mosh-server 1.4.0（`tool/mosh-fixture`）。Dart 候选和「官方客户端」在本机跑（`tool/mosh-fixture/dart_probe`，23 条）；
插件里我们自己交叉编译的那份在 Android 模拟器上跑（`integration_test/mosh_runtime_test.dart`），结果见 `plan/v3/evidence/X08.md`。

| 检查 | dart_mosh 0.0.4 | 官方 mosh-client |
|---|---|---|
| 互通、VT 重绘 | 8 种画面（大量滚动、中文宽字符与组合字符、光标定位、备用屏与滚动区、颜色与折行、200x60 多分片、改尺寸、vim 交互）逐字等于官方客户端画出的屏幕 | 对照基准 |
| 丢 30% + 每包两份 + 乱序 | 收敛（约 3.4 秒） | 收敛（约 7 秒） |
| 篡改的包 | 认证失败、丢掉，会话照常 | 同（OCB 认证） |
| 重放服务器的旧包 | 屏幕不变 | 协议按状态号去重 |
| **把客户端自己的包反射回客户端** | **吃下去了**：不查 nonce 的方向位，反射包里的确认号被当成服务器对输入的确认，待发的按键被删掉，之后的输入状态号和服务器对不上——**后面打的字全都送不到**（实测，对照组不反射时照常送达） | 丢掉（`src/network/network.cc:513` 的 `dos_assert` 查方向位），输入照常送达（同一个中继、同样的反射，实测） |
| **用户关会话** | `close()` 只关本地套接字，不通知服务器：5 秒后远端 mosh-server 和 shell 还在 | 插件发 SIGHUP，客户端按协议通知服务器（`src/frontend/stmclient.cc:501–510`）：不到 100 ms 远端 mosh-server 退出（实测） |
| 远端 shell 退出 | 能识别（0.0.3 起），服务器随后退出 | 同 |
| 本地预测（高延迟下先显示自己打的字） | 没有 | 有（mosh 的主要卖点） |
| 收到「基于更旧状态」的差分 | 丢掉，等服务器重发（只认最新状态） | 保留最近的状态，能直接用 |
| 服务器发来的超大压缩包 | 解压不设上限（插件进程可能被撑爆，宿主不受影响） | mosh 自己的实现 |
| 加密实现 | pointycastle 的纯 Dart AES（查表实现，不是常数时间） | OpenSSL 3.5 的 AES-OCB（arm64 有硬件 AES） |
| 解析失败时 | 异常里带着整段 bootstrap 输出（可能含 key）；`rawOutput` 也留着原文 | 不解析 bootstrap（宿主解析，见 MOS08） |

## 为什么不是 Dart

反射那一条是协议层的安全/正确性缺陷：链路上任何能看到包的人（公共 Wi-Fi、运营商 NAT）不用知道 key，
把客户端发出的包原样弹回去，就能让这个会话之后的输入全部丢失，用户只看到「打字没反应」。再加上关会话不通知服务器
（每关一次在远端留一个 mosh-server + shell）、没有本地预测。这些都能改，但改就等于我们自己维护一份 Mosh 协议实现，
而官方客户端已经是完整、被广泛使用的实现。Dart 候选的优势（许可宽松、和宿主同语言）不足以抵这些；
它在独立 APK 里还要多带一整套 Flutter 引擎。

这不是「只因更易编译或许可更宽松就跳过协议验证」：两边都和真 mosh-server 跑过同一套检查，差别是实测出来的。

## 选 native 的代价和风险

- **exec 的合法性**：运行时装在 nativeLibraryDir（系统安装时从 APK 解出，只读），不在可写目录里 exec（docs/13 S54）。
  这是 Android 允许的做法，但依赖 `extractNativeLibs=true`；以后的 Android 若收紧，要改成进程内 JNI（mosh-client 的
  `exit()`、全局单例、信号都要改，代价大）。
- **每会话一个子进程**：Android 12 起系统会限制 App 的子进程（phantom process），后台时可能被杀。会话被杀等于运行时退出，
  按 docs/16 显示「原会话丢失」，不自动重放输入。后台存活和移动网络恢复是 X10 的事。
- **key 经环境变量交给子进程**：不进命令行参数（`ps` 看得到参数），mosh-client 读完就 `unsetenv`（`src/frontend/mosh-client.cc:168–184`）；但 `/proc/<pid>/environ`
  里的初始环境块还在，只有插件自己的 UID 和 root 读得到。
- **强杀插件**（SIGKILL）时 mosh-client 来不及通知服务器，远端会留下 mosh-server，这是 mosh 的设计（服务器等客户端回来）。
- **GPL 义务**：插件按 GPL-3.0-or-later 分发，要能提供对应源码（本仓库 + 上游源码包 + 补丁 + 构建脚本）。
- **只有 arm64-v8a**：其他 ABI 没设备测过，不打进包。

## 怎么复核

```bash
(cd tool/mosh-fixture && ./up.sh && cd dart_probe && flutter pub get && flutter test)   # Dart 候选 + 官方客户端对照，23 条
# 插件在设备上：见 plugins/mosh/README.md「设备上验证」
```

`dart_probe` 里「缺陷复现」那条断言的是 dart_mosh 0.0.4 的错误行为；它哪天挂了，说明上游修了，可以重新评估。
