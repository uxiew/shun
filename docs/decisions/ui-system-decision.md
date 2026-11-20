# UI 体系选择：FlClash + prism_ui

日期：2026-11-05，实施更新：2026-11-20。状态：**R81–R89已完成，GU0、GU1、GU2 PASS；下一项U3的R90文件页与端口转发（R91、R92可并行）。**

## 决定

shun 以 **FlClash 为唯一主要视觉和交互参照，prism_ui 为唯一目标 UI 组件体系**。沿用 Flutter、Riverpod、dartssh2 和现有 libghostty/flterm，按页面逐步替换呈现层。TermRover/LobiShell 的既有交互结论仍约束业务流程，但不再作为第二套视觉移植对象。

所有者要求“不要个个都试，选一个作为主要的目标 UI，进行移植，最后确立落地规划，细化拆解为大模型可按阶段执行的任务计划”。已落实单一目标与分阶段计划，不添加多库试用或新的设计确认门槛。R81基线、R82固定依赖和薄宿主、R83语义主题、R84公共控件与规则识别、R85主导航外壳、R86设置与安全数据页、R87连接首页与目录列表、R88主机表单、R89凭据/代理/Tailscale面板已完成；R90–R98仍为NOT_STARTED，下一项R90，R91、R92文件边界不同可并行。

## 固定参考

| 项目 | 固定版本 | 用途 |
|---|---|---|
| shun 规划前基线 | `shun/v3`，`92fe59340515ac26db51cb3a18397d2f42e3c012`，工作区干净 | 当前功能、页面、测试和数据行为依据；R81 实施时重新记录实际 HEAD/dirty |
| FlClash | `be84736605527034689c95bf27828ff27d912c5e` | 唯一视觉参考，冻结当时源码与官方截图 |
| prism_ui | `63450c0ac0e8e1b2c0f3ed4ad7926dc94e083185`，pubspec 版本 `0.1.2` | FlClash 该快照实际 submodule 指向；Git 依赖按完整 ref 固定 |

官方证据见 [S89–S102](../../plan/v3/docs/13-sources.md#s89)。prism_ui声明Flutter >=3.47.0、Dart >=3.10.0 <4.0.0；R82在Flutter 3.47.7/Dart 3.13.5上实际完成依赖解析、宿主/安全/终端回归和Android debug构建，详见[R82证据](../../plan/v3/evidence/R82.md)。后续版本升级仍需单独验证。

## 选择依据与代价

FlClash 的统一主题、表面、连续圆角、分组控件和流畅过渡，正是这次希望收敛的方向；它实际使用 prism_ui，复用组件比在另一套库里重新描摹这些细节更直接。shun 继续保留终端产品自身的字段顺序、状态语义和操作流程。

prism_ui是0.1.2，GU0通过只证明本仓库当前接入边界可用，长期稳定性和新UI性能仍需后续验证。继续固定完整提交、维护窄兼容层，不跟随main或连带升级业务框架。发现阻塞先修同一目标内的适配；重大范围变化另记决定，不静默切换UI库。

## 接入形态

R82前入口是 `lib/app.dart` 的 `MaterialApp(home: HomeShell())`；现已接入 `ShunUiHost(home: HomeShell())`。保留单个Navigator和原 `_navigatorKey`，没有附带go_router重构。

R82已实装一个窄 `ShunUiHost`：以单个 `WidgetsApp` 组合公开 Prism 主题、测量、视图、提示、焦点和 Overlay 组件。显式提供 pageRouteBuilder；HomeShell/live 终端根路由不用 CardRouteMixin，遥控焦点导航关闭，避免私有路由截图和方向键处理影响终端。SDK Material 主题放在 `GhosttyDetachedThemeSync` 外，保留已有消费者需要的 `ScaffoldMessenger` 与本地化。现有 `AppLockGate` 覆盖全部提示、路由和视觉层。

不直接机械替换成 `PrismApp`：其 `BannerHost` 和 `ThemeCrossFade` 位于应用 builder 外，原锁罩仅包 builder child 时可能被提示或旧主题截图覆盖（[S93](../../plan/v3/docs/13-sources.md#s93)、[S98](../../plan/v3/docs/13-sources.md#s98)、[S99](../../plan/v3/docs/13-sources.md#s99)）。本方案不安装全应用截图式主题切换，也不靠更换 key 重建导航/终端树来清图。上述层级已在R82实际验证并冻结；AppLockGate同时封闭covered期间的硬件输入和旧IME连接，恢复时保留原焦点。

Tailscale 设置使用本地非模态面板，采用 Prism 表面/形状/动效；不能以透明模态 barrier 代替背景可操作。终端渲染、单 view 和单输入所有者继续由现有终端模块负责。

## 范围与出口

迁移覆盖五个主入口及全部现有二级页面、弹层和状态，包含 SFTP、监控、凭据、插件/远控、AI、备份/安全；不只重做首页。保留 FormGap 20dp、短文案与独立帮助语义、F41 非模态与固定 key 掩码、F42 原地选择/无管理页、双指总览及可见入口。数据格式、应用身份、路线、认证与远端副作用不变。

不移植FlClash的代理核心、平台服务、状态管理或资源品牌，不新增R71/R80等延后功能。R82通过固定Git依赖接入；Prism GPL、上游NOTICE和五项嵌入组件许可已核对实际APK，额外署名全文经 `licenses/prism_ui-third-party.txt` 收录。正式分发仍纳入R27/R29检查，未复制Prism私有实现。

详细执行、文件分工、预算与模型交接见 [UI 迁移方案](../../plan/v3/docs/24-ui-migration.md)。机器权威是 `plan/v3/tasks.json` 与 `verification-cases.json`。GU5 只表示 UI 代码及本地验证交接完成；完整验收仍走 R26、新候选发布与原 V3 门禁。
