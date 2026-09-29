# 当前状态 V3

日期：2026-09-29。首批（R00–R04、X00）已执行。

- 基座：kmh1145/Netcatty-mobile `495f5d31`（v1.4.7），本机 fork `xwshun/v3`，不 push。GPL-3.0-or-later 个人隔离实验；applicationId `top.xdwa.xwshun`。
- 任务：DONE 5（R00 R01 R02 R03 X00）、BLOCKED 1（R04，缺真机）、NOT_STARTED 40、DEFERRED 7。
- 用例（共 142）：PASS 11、FAIL 3、BLOCKED 4、NOT_RUN 124。每条的实际动作和观察在 `evidence/`。
- 门禁：G0 **BLOCKED**（R04 缺 ARM64 真机）；其余门禁 NOT_RUN。离 CORE_READY / FULL_READY 都还很远。
- 没有真机、没有安装过任何 APK、没有连接任何用户真实主机/账号/VPN，没有 push 或发布。

## 这批改了什么（代码层面）

- 冷启动不再请求上游 GitHub 检查更新；AI、云同步、更新检查默认关闭（R01）。
- 选了代理就必须经代理：配置无效或代理失败一律报错，不再静默直连；代理握手有截止时间（R03/A01）。
- 终端输出整条流共用一个 UTF-8 解码器，中文不再因切包乱码（R03/A03）。
- 断线恢复不再重跑 startupCommand 或托管终端的管理命令（R03/A04）。
- 插件契约 v1 落成 `packages/plugin_api`（X00）。

## 三个 FAIL（都已定位到负责任务）

| 用例 | 问题 | 归属 |
|---|---|---|
| NET01 | 配了代理口令，代理却选"无认证"时仍建立会话（A02） | R06 |
| NET11 | 断线时不确定是否送达的输入没有标"结果未知" | R23 |
| GST01 | libghostty 已缓存的库副本被篡改后构建不报错，篡改库进了 APK | R17（打包前校验）；发布构建先删 `.dart_tool` |

另有一个 R04 发现：flterm 0.0.5 在 dispose 后 write 会段错误，终端页销毁后迟到的 SSH 数据会让 App 闪退。R17 必须按代次挡住。

## 下一批

依赖已满足：**R05**（统一 RoutePlan）、**X02**（Android 插件发现与双向签名，出真实证据需要能装 APK 的设备）。
R05 完成后可做 R06（修 A02）和 X01。R16/R17（Ghostty 接入主 App）要等 R04 解除 BLOCKED。

## 等所有者决定或提供

- 一台 ARM64 Android 真机（解除 R04；BAS02/BAS03/TER02/REL03 也要它）。
- 是否允许新建一个专用 Android 模拟器（会写入 `~/.android`；只能作部分证据，不能代替真机）。
- 应用正式名称、正式签名、分发形态（BAS04/REL01 许可结论依赖它）。
- Gradle 依赖是否也要锁定校验（SUP01 只完成了 pub 层）。

只能将真执行结果写入 evidence。用户 LobiShell 成功属于参考应用事实，不转移为新 App 通过。
