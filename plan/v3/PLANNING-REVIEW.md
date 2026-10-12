# 规划层自检（不是独立App审计）

本轮读取上一版总册；保留网络/终端/安全测试，覆盖旧技术栈与后续门禁。新插件需求已进入核心依赖，R30无法跳过X13。数量来自结构化JSON而非手填已完成。

核对重点：Netcatty是Flutter xterm2不是WebView；Mosh README与Manifest不同；UU raw与旧搜索缓存全屏回调不同；目录凭据不入网；SOCKS复用服务不复用同一目标SSH连接；Mosh需要独立UDP；外部远控不承诺继承SSH route；独立APK不自动豁免GPL/AGPL；SDK和运行时分开。

自动结构检查与schema正/负例记录在PLAN-CHECK.json。该结果不构建应用、不运行网络、不安装APK，不证明插件安全。初版（2026-09-29）的142项App验收当时均为NOT_RUN；实施后的当前数量与结果以 STATUS.md 和 verification-cases.json 为准，独立审查仍需真实执行者。

补充核对：Conduit的Mosh为dart_mosh，不应误写native。X08增加Dart/native运行时选择及互操作要求；插件独立安装契约不变。源码与声明未替代Android实测。

2026-10-11 补充：OSH、meshTerm、NovaScale 仅按公开资料研究；该批主线52项不变、后续增为17项；新增UX10–UX12均NOT_RUN，已有PASS不扩写冒充新范围通过。PLAN-CHECK.json 更新为本次结构检查，PACKAGE-MANIFEST.json 更新为当前计划快照；两者均不代表应用构建或验收。

2026-10-11 后续补充：Dokodemo CLI、ShellDiver 官方研究及所有者明确新增的 AI CLI 需求落为 R55–R57 主线，合计 72 项任务（55 主线 / 17 后续）、160 项用例、88 项来源。G4、R25、R30 和 M5 包含新增范围；9 项 AIC 用例均 NOT_RUN。重点核对工具发现的范围、完整 tmux 与窗格身份、原生 ID 的可靠来源、目录/请求代次隔离、冷启动不重放及真实工具证据；所有既有任务状态、用例结果与执行证据不变。
