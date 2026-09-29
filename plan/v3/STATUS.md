# 当前状态 V3

日期：2026-09-29。首批（R00–R04、X00）已执行；同日所有者同意用 arm64 模拟器补测。

- 基座：kmh1145/Netcatty-mobile `495f5d31`（v1.4.7），本机 fork `xwshun/v3`，不 push。GPL-3.0-or-later 个人隔离实验；applicationId `top.xdwa.xwshun`。
- 任务：DONE 5（R00 R01 R02 R03 X00）、BLOCKED 1（R04）、NOT_STARTED 40、DEFERRED 7。
- 用例（共 142）：PASS 12、FAIL 4、BLOCKED 2、NOT_RUN 124。每条的实际动作和观察在 `evidence/`。
- 门禁：G0 **BLOCKED**（R04）；其余门禁 NOT_RUN。离 CORE_READY / FULL_READY 都还很远。
- 设备：只有 arm64 模拟器（API 28 / 35 / 36，36 是 16 KiB 页），**没有真机**。只装过本项目自己的 APK 和原版 Netcatty；没有连接任何用户真实主机/账号/VPN，没有 push 或发布。

## 这批改了什么（代码层面）

- 冷启动不再请求上游 GitHub 检查更新；AI、云同步、更新检查默认关闭（R01）。模拟器上按 UID 看内核流量：fork 冷启动→设置→后台→deep link 全程 0 条，原版冷启动即有（BAS02）。
- 选了代理就必须经代理：配置无效或代理失败一律报错，不再静默直连；代理握手有截止时间（R03/A01）。
- 终端输出整条流共用一个 UTF-8 解码器，中文不再因切包乱码（R03/A03）。
- 断线恢复不再重跑 startupCommand 或托管终端的管理命令（R03/A04）。
- 插件契约 v1 落成 `packages/plugin_api`（X00）。
- terminal spike 补了 Android 适配层（软键盘退格兜底、收起后叫回键盘）和一份 flterm 中文输入补丁（R04，只在 spike 里）。

## 四个 FAIL（都已定位到负责任务）

| 用例 | 问题 | 归属 |
|---|---|---|
| NET01 | 配了代理口令，代理却选"无认证"时仍建立会话（A02） | R06 |
| NET11 | 断线时不确定是否送达的输入没有标"结果未知" | R23 |
| GST01 | libghostty 已缓存的库副本被篡改后构建不报错，篡改库进了 APK | R17（打包前校验）；发布构建先删 `.dart_tool` |
| TER02 | flterm 0.0.5 原样在 Gboard 上打不了中文（被当成密码框）；打补丁后模拟器拼音全流程通过 | R17（补丁去向）；真机+国产输入法未测 |

R04 其他要带进 R17 的发现：dispose 后 write 段错误、软键盘退格 0 字节、收起后叫不回键盘、内联组字漏字、组合字符缺重音、默认资源上限过大。详见 `evidence/R04.md`。

## 下一批

依赖已满足：**R05**（统一 RoutePlan）、**X02**（Android 插件发现与双向签名，模拟器可以出部分证据）。
R05 完成后可做 R06（修 A02）和 X01。R16/R17（Ghostty 接入主 App）要等 R04 解除 BLOCKED。

## 等所有者决定或提供

- 一台 ARM64 Android 真机 + 你常用的中文输入法：R04/TER02 最后一步必须真人在真机上做。
- flterm 补丁的去向：fork 进仓库自己维护，还是先向上游提 issue/PR 再 pin 新版本（R17 前要定）。
- Ghostty 路径的最低 API：声明的是 24，但本机模拟器只能测到 28（28 实测能跑）；是找 24–27 的真机，还是把最低版本定成 28。
- 应用正式名称、正式签名、分发形态（BAS03 的"签名不同"、BAS04/REL01 许可结论依赖它）。
- Gradle 依赖是否也要锁定校验（SUP01 只完成了 pub 层）。

只能将真执行结果写入 evidence。用户 LobiShell 成功属于参考应用事实，不转移为新 App 通过；模拟器结果都标明了是模拟器。
