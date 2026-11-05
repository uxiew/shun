# UI 体系选择：FlClash + prism_ui

日期：2026-11-05。状态：**目标已确定；迁移尚未实施，接入待 GU0 实测**。

## 决定

shun 以 **FlClash 为唯一主要视觉和交互参照，prism_ui 为唯一目标 UI 组件体系**。沿用 Flutter、Riverpod、dartssh2 和现有 libghostty/flterm，按页面逐步替换呈现层。TermRover/LobiShell 的既有交互结论仍约束业务流程，但不再作为第二套视觉移植对象。

所有者要求“不要个个都试，选一个作为主要的目标 UI，进行移植，最后确立落地规划，细化拆解为大模型可按阶段执行的任务计划”。本次落实选择与计划，不添加多个库试用任务、不设置新一轮选型或设计确认门槛。实施任务 R81–R98 均从 NOT_STARTED 开始，唯一下一项是 R81。

## 固定参考

| 项目 | 固定版本 | 用途 |
|---|---|---|
| shun 规划前基线 | `shun/v3`，`92fe59340515ac26db51cb3a18397d2f42e3c012`，工作区干净 | 当前功能、页面、测试和数据行为依据；R81 实施时重新记录实际 HEAD/dirty |
| FlClash | `be84736605527034689c95bf27828ff27d912c5e` | 唯一视觉参考，冻结当时源码与官方截图 |
| prism_ui | `63450c0ac0e8e1b2c0f3ed4ad7926dc94e083185`，pubspec 版本 `0.1.2` | FlClash 该快照实际 submodule 指向；Git 依赖按完整 ref 固定 |

官方证据见 [S89–S102](../../plan/v3/docs/13-sources.md#s89)。prism_ui 声明 Flutter >=3.47.0、Dart >=3.10.0 <4.0.0；shun 本机手册记录 Flutter 3.47.7/Dart 3.13.5，满足声明下限，**不是已经求解依赖或编译成功的证明**。

## 选择依据与代价

FlClash 的统一主题、表面、连续圆角、分组控件和流畅过渡，正是这次希望收敛的方向；它实际使用 prism_ui，复用组件比在另一套库里重新描摹这些细节更直接。shun 继续保留终端产品自身的字段顺序、状态语义和操作流程。

prism_ui 是 0.1.2，不能把它表述为已经在 shun 验证过的成熟稳定基础。接受这一代价的方法是固定完整提交、只维护窄兼容层、先完成 GU0 的实际构建/焦点/锁屏/非模态门禁。后续升级单独验证，不跟随 main，也不连带升级业务框架。发现阻塞先修同一目标内的适配；重大范围变化另记决定，不静默切换到另一套 UI 库。

## 接入形态

当前入口是 `lib/app.dart` 的 `MaterialApp(home: HomeShell())`，不是 `MaterialApp.router`。本次保持单个 Navigator 和现有 `_navigatorKey`，不附带 go_router 重构。

目标接入是新增一个窄 `ShunUiHost`：以单个 `WidgetsApp` 组合公开 Prism 主题、测量、视图、提示、焦点和 Overlay 组件。显式提供 pageRouteBuilder；HomeShell/live 终端根路由不用 CardRouteMixin，遥控焦点导航关闭，避免私有路由截图和方向键处理影响终端。SDK Material 主题放在 `GhosttyDetachedThemeSync` 外，保留已有消费者需要的 `ScaffoldMessenger` 与本地化。现有 `AppLockGate` 覆盖全部提示、路由和视觉层。

不直接机械替换成 `PrismApp`：其 `BannerHost` 和 `ThemeCrossFade` 位于应用 builder 外，原锁罩仅包 builder child 时可能被提示或旧主题截图覆盖（[S93](../../plan/v3/docs/13-sources.md#s93)、[S98](../../plan/v3/docs/13-sources.md#s98)、[S99](../../plan/v3/docs/13-sources.md#s99)）。本方案不安装全应用截图式主题切换，也不靠更换 key 重建导航/终端树来清图。上述层级是已核对公开 API 后的接入设计，实际构造在 R82 验证后冻结。

Tailscale 设置使用本地非模态面板，采用 Prism 表面/形状/动效；不能以透明模态 barrier 代替背景可操作。终端渲染、单 view 和单输入所有者继续由现有终端模块负责。

## 范围与出口

迁移覆盖五个主入口及全部现有二级页面、弹层和状态，包含 SFTP、监控、凭据、插件/远控、AI、备份/安全；不只重做首页。保留 FormGap 20dp、短文案与独立帮助语义、F41 非模态与固定 key 掩码、F42 原地选择/无管理页、双指总览及可见入口。数据格式、应用身份、路线、认证与远端副作用不变。

不移植 FlClash 的代理核心、平台服务、状态管理或资源品牌，不新增 R71/R80 等延后功能。接入时记录 Prism GPL 和各第三方 NOTICE，纳入原 R27/R29 交付检查；本次规划不复制其实现到仓库。

详细执行、文件分工、预算与模型交接见 [UI 迁移方案](../../plan/v3/docs/24-ui-migration.md)。机器权威是 `plan/v3/tasks.json` 与 `verification-cases.json`。GU5 只表示 UI 代码及本地验证交接完成；完整验收仍走 R26、新候选发布与原 V3 门禁。
