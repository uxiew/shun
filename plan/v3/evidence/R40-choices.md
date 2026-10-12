# R40：首跳代理选择与嵌套路线展开

日期：2026-10-12。起点 `cd9d7e7`，实现/测试/用户与开发手册提交 **`d4a9c96`**。接续 [组件抽取](R40.md)、[链式编辑与代理管理](R40-chain.md) 和 [首次模拟器回归](R40-simulator.md)。本轮按所有者明确要求实现剩余的显式选择和展开，第二跳以后自带代理仍拒绝。

## 实现与契约

- `jump_route_choices.dart` 是 `connection_route.dart` 的 part，复用 RoutePlan 私有校验，不另建路由引擎。产生候选 → 展示顺序/首跳代理 → 用户选择 → 复核来源 → 原子应用；页面只负责草稿和保存，弹窗不访问存储或网络。
- 首跳有代理时，没有默认选项；「也经这个代理」复制内联配置或保留可复用代理 ID，「直连这台跳板机」明确移除当前入口代理。弹窗说明会替换入口，只改当前目标，不改来源主机。无首跳代理时，展开保留原目标入口。
- 嵌套列表有界递归展开为最多三跳，连续公共前缀只列一次。缺失、非 SSH、循环、重复端点、过长、格式错误、第二跳及以后带代理均拒绝；失败/取消不部分写入，不尝试直接连接目标。
- 完整执行链仍在原 `hostIds` 和代理字段中。原 hostChain 内增加 `shunRouteConfirmation` 命名空间扩展，只有版本、顺序、来源非秘密路线字段、入口和首跳选择，不含密码/私钥；没有迁移或复制整台主机。旧客户端执行语义未测试，不宣称跨端执行兼容。
- 连接仍只由 `resolveRoutePlan` 决定。它核对确认和当前来源以及展开结果，绝不将递归结果在拨号时动态加入链。来源地址/路线/代理选择变化、重排、坏确认都会拒绝。共享代理同 ID 更新沿用现有规则；内联密码是确认时复制的值，更新来源口令需重新确认。
- 弹窗期间比较内存中的完整配置版本（含凭据，但不记录/序列化）；页面禁止在保险库加载或代理秘密不可读时复制路线，确认返回后再次检查。草稿再次编辑会清掉旧确认。
- 修复检查中发现的凭据清除缺口：`RoutePlan.withoutSecrets()` 原先只删 SSH 密码，冻结 hop/target 的内联代理密码仍残留；现在深拷贝移除 SSH、Telnet、内联代理密码及密钥引用对象，保留路线 shape，原计划不变。

## 自动化覆盖

新增域测试覆盖两种首跳选择、JSON 往返、三层展开、公共祖先、全部拒绝矩阵、来源/入口/顺序变化、确认不含秘密、共享代理更新/删除及冻结凭据清除。两页相同输入对照增加直连首跳、沿用代理、展开、展开加代理四组；组件测试覆盖取消、弹窗期间来源变化及重新确认。测试发现草稿预览使用 `HostProfile.create` 的时间戳导致每次版本都不同，改用稳定的路线专用预览数据后通过。

定向七文件 **92 PASS、0 FAIL**，最终静态检查 **No issues found**。Dart 格式检查 14 文件无变更，Shell 语法及 `git diff --check` 通过。定向文件：jump_route_choices、connection_route_editor、proxy_profiles_page、route_plan、route_fail_closed、host_route_editor、localization_coverage。

## Android 与真实 SSH 边界

专用 `shun-a35-4k` / `emulator-5580`，Android 15 / API 35、arm64 / 4 KiB，1080×2400、约 411.43dp，真实系统键盘及 Android 加密存储。实际页面、VaultController/Repository 和 SshService，由轻量导航宿主加载，不计完整首页/终端回归。只连接本机五容器 OpenSSH/SOCKS fixture；目录页数据为合成数据，不请求真实 Tailscale。每次成功核对每跳指纹并执行目标 hostname。无真实主机、账号、VPN、真机或 iOS。

设备脚本现在构建一次直接 integration main 的 APK，再用 `flutter drive --keep-app-running` 两次执行，阶段间 force-stop，以真实数据验证另一进程恢复。`R40_APK` 只用于复用相同源码和本轮凭据的构建。所有 adb 命令限制专用序列号；新增 22201 仅用于用户明确选择的首跳直连。拨号计数在入口白名单判断前记录，避免拒绝测试误判为零拨号。

## 设备矩阵

| 场景 | 断言 |
|---|---|
| 三层展开与首跳代理 | 选择 nested-c，先取消不变，再选择沿用代理；保存为 proxy-edge→nested-b→nested-c，入口 21080，原来源主机不变；真实 SSH 顺序和四个指纹一致 |
| 首跳明确直连 | direct-edge 自带有效代理；选择直连后目标入口不带代理，经本机 22201 到首跳，再转发至目标；不是失败后的降级 |
| 循环 | cycle-a↔cycle-b 被拒绝，显示错误且草稿未展开 |
| 冷启动确认 | 另一 App PID 从真实加密存储恢复两条选择路线，分别沿代理三跳、直连首跳查询目标成功 |
| 来源变化 | 将 nested-b 的来源链改成 edge，已保存路线在 RoutePlan 阶段拒绝，拨号次数不增加；编辑器也显示错误；随后还原来源 |
| 既有 R40 | 旧内联另存、取消、未知字段保留；0–3 跳、排序/移除、两页共用链、代理共享更新/删除、认证失败不直连、英文 HTTP 表单继续回归 |

最终 `device7` 两阶段均通过：seed PID **4525**（87 秒）、cold PID **4788**（24 秒），不含构建时间。**13 次真实 SSH 成功（9 + 4）**；保留一次预期代理认证失败，来源变化/删除代理在拨号前拒绝。两阶段扫描分别检查 **9 / 12 个私有文件及 Flutter 日志**，测试 SSH/代理密码未明文出现；编译了临时 define 的 APK 不属于扫描范围，收尾移除构建缓存并销毁 fixture 凭据。

八张截图保存在最终目录：`chain-three`、`proxy-manager`、`catalog-chain`、`jump-route-confirm`、`jump-route-cycle`、`delete-impact`、`missing-proxy`、`english-manager`（PNG）。检查过确认按钮、循环错误和英文页面；截图结合测试断言、指纹及 hostname 查询作证，不单独代替连接成功。HTTP 只验证表单，不计代理互通。

## 环境故障与修复

初次构建因磁盘不足失败。清理本项目可重建缓存、停空闲 Gradle daemon，并临时限制本项目 Gradle 内存/worker 后构建完成；临时配置随后删除。磁盘压力期间 OrbStack 服务退出，fixture 端口拒绝；重新启动 OrbStack，并用 compose start 恢复已有容器（不轮换本轮凭据），拓扑自检重新 **8/8 PASS**。其他项目容器也恢复运行。

复用 `flutter test` 生成的引导 APK 时，`flutter drive` 找不到驱动扩展；改为直接 `flutter build apk --target integration_test/...`。一轮旧脚本退出清理与新脚本重叠导致 define 缺失，已改为顺序重跑。随后 seed 全部通过，但 drive 默认退出会卸载应用，持久化检查失败；加 `--keep-app-running` 并仍显式 force-stop。上述失败日志均保留，不计为成功。

第六轮两阶段已完成全部新增真实 SSH/冷启动场景，删除代理的旧断言却早于 Android 加密存储写入完成；`pumpAndSettle` 只等帧，不等 I/O。设备测试改成最多 10 秒观察实际条目消失，同时检查管理页错误，不放宽删除结果断言。

原始证据根目录：`../.toolchain/artifacts/r40-choices-cd9d7e7/`。用户和开发手册同步首跳选择、嵌套展开、确认失效、内联口令复制规则及设备复现方式。

## 最终全量与计划

```bash
source ../.toolchain/env.sh
flutter test --no-pub -j 4 --exclude-tags ai-cli-ssh-fixture --reporter expanded
flutter analyze --no-pub
```

最终全量 **1214 PASS、47 SKIP、0 FAIL**（158 秒），包含 RTE01/JMP03 配置与失败不直连测试，以及 JMP04 本机真实 OpenSSH 回归；47 项跳过为未启动的 tmux/Mosh 等 fixture 条件，不计通过。单独 AI 原生工具 fixture 标签被排除，本轮不需要真实 AI 账号。静态检查 **No issues found**（8.5 秒）。对应 `full-final.log`、`targeted-final.log`、`analyze-final.log`；最终设备日志、两次扫描和八张截图在 `device7/`。`manifest.json` 记录本轮证据文件大小与 SHA256。

R40 本轮范围完成，标 **DONE**；UX06 结合两页同输入 Widget 对照、真实页面设备回归及前两轮代理复用证据标 **PASS**。第二跳以后自带代理仍拒绝，没有消除既有停止条件。计划共 37 DONE、3 IN_PROGRESS；用例 127 PASS、1 FAIL、6 BLOCKED、26 NOT_RUN，其他任务的真机/账号限制仍保留，不代表完整 V3 已就绪。

## 收尾

测试 App 已从 5580 卸载，adb 端口转发为空，专用模拟器已关闭；adb 仅剩用户的 5554。五个 fixture 容器、两张测试网络、`.run` 凭据/define 已删除。本项目空闲 Gradle daemon 已停，临时 Gradle 限额已移除，APK/Flutter build/transforms 可重建缓存已清理，保留 SDK/AVD、原生 hooks 与历史证据。磁盘可用约 4.4 GiB。

OrbStack 保持运行；收尾核对原有七个其他项目容器都在运行（quant_trading_flow 三个、clouddesk 四个）。本轮为专用 AVD 用过 adb root 和 sm fstrim 释放已删除数据，未修改 Wi-Fi、PIN、输入法或真实设备。所有提交仅本地保存，没有 push/发布。计划校验只证明文档/契约一致性，不替代上面的应用测试。
