# 24 FlClash / Prism UI 迁移实施方案

决策日期：2026-11-05，实施更新：2026-11-06。所有者决定：只选一个主要目标，不逐库试用；把移植落实为大模型按阶段可执行的任务。**R81/R82已完成、UIM01–UIM03及GU0 PASS；当前入口R83。R83–R98尚未开始，UIM04–UIM22保持NOT_RUN。** 实际进度以[STATUS](../STATUS.md)和对应证据为准。

## 1. 唯一目标与文档权威

**视觉/交互参照：FlClash。目标组件体系：prism_ui。业务继续是 shun。** 选型理由、固定 SHA 和接入代价只在 [UI 决策](../../../docs/decisions/ui-system-decision.md) 维护；原始资料在 [S89–S102](13-sources.md#s89)。

任务定义/状态以 [tasks.json](../tasks.json) 为准，[docs/08](08-implementation-tasks.md) 是可读副本；用例定义和结果以 [verification-cases.json](../verification-cases.json) 为准，[docs/09](09-verification.md) 是可读副本；当前入口是 [STATUS](../STATUS.md)。本方案说明实施边界、顺序、文件分工和验证方法，不建立另一套队列或任务状态文件。

选择已定，不安排 Material/Shadcn/Fluent 等多库试验，不增加 UI 方案切换器，不搬 FlClash 的业务。允许一个薄宿主和有消费者依据的 Material 兼容，目标仍只有 Prism。

## 2. 视觉要迁移什么

以下是 shun 的目标设计规则，不冒充已经移植的截图或实测效果。R81 在固定参考和当前页面上建立唯一对照；R86 用完整设置页校准后继续扩展。

| 层面 | 采用的方向 | shun 中的落点与约束 |
|---|---|---|
| 表面与层次 | FlClash 的分层表面、分组列表、连续圆角 | 列表、设置、表单、弹层共享语义 token；终端正文保持可读、稳定 |
| 配色与主题 | 单一语义主题驱动浅深模式 | 保留当前主题 ID、系统模式和自定义背景；不照抄品牌色/图标 |
| 信息密度 | 名称、状态、主要操作优先，解释进入帮助 | 沿用短文案限制；不把每行拉成大卡片，不给已有功能增加说明墙 |
| 导航 | 统一标题、导航表面、选中/按压反馈 | 五入口与 IndexedStack 保留，无新管理页；全屏/PiP 行为不变 |
| 表单 | 一致控件、分段选择、清楚的焦点和校验状态 | 类型/认证原地换；分组在名称下；高级一层；FormGap 20dp |
| 面板 | 统一表面、拖动反馈与普通确认弹层 | Tailscale 必须真非模态；其他已有模态确认保持正确阻断 |
| 动效 | 局部按压、展开、切换使用公开 Prism 动效 | 减少动画可用；不加全应用旧帧截图过渡；终端正文不加玻璃 |
| 终端与总览 | 外壳统一、预览紧凑、状态明确 | 单 live view、单输入所有者；总览仅用内存文字快照 |

不设多个备选视觉方向；发现比例、字阶或颜色问题就在这套规则内修正。界面统一的完成判据是全页面覆盖、行为一致和可测预算，不是“用了同一个包”或只有首页截图漂亮。

## 3. 已核实的起点与接入设计

### 3.1 当前实现

规划前源码为 `shun/v3 @ 92fe59340515ac26db51cb3a18397d2f42e3c012`，工作区干净。入口是 `lib/app.dart` → `lib/presentation/home_shell.dart`，后者用 IndexedStack 保存连接、终端、文件、片段、设置五页。没有 `main_screen.dart` 或 `manage_screen.dart`；不能按不存在的页面拆任务。

R82前MaterialApp的root key用于跨页面安全密钥询问；R82已由ShunUiHost保留同一把key。会话初始化、应用锁、后台保活、自动同步、目录前后台通知均在原应用状态中，职责未迁移。pubspec声明go_router不代表运行时使用了它，本迁移不启用或重构路由框架。

### 3.2 一个薄宿主，单个 Navigator

R82已新增 `lib/presentation/ui/shun_ui_host.dart`，用公开API实现单个WidgetsApp，保留原key、home、locale、delegates。以下层级通过GU0实际验证，构造、93项回归、隔离debug构建及未测边界见[R82](../evidence/R82.md)：

| 顺序 | 层级 | 硬约束 |
|---|---|---|
| 1 | SDK Material Theme、默认字样式、Prism Theme、MeasureScope、ViewScope | 同一解析主题生成两种表示；保留系统字号语义，不任意封顶大字 |
| 2 | GhosttyDetachedThemeSync | 必须读到正确的 Material Theme，未展示标签也同步 |
| 3 | AppLockGate | 所有路由、提示、Overlay、视觉效果都在锁罩内；保留语义/焦点/触摸排除 |
| 4 | ScaffoldMessenger、选择/滚动样式、BannerHost、必要视觉作用域 | 兼容当前消费者；不能把提示再放到锁罩外 |
| 5 | RemoteFocusAdapter(enabled: false)、Overlay.wrap、唯一 Navigator child | child 来自同一个 WidgetsApp；不启用TV/遥控方向键导航，不再造 App/Navigator |

保持 `_navigatorKey` 实例，不能换成 Prism 导出的另一把全局 key。保留 `initState/dispose/didChangeAppLifecycleState/didPopRoute` 的已有职责。WidgetsApp 指定 home 时必须显式提供 pageRouteBuilder（[S102](13-sources.md#s102)）。HomeShell 和承载 live 终端的 route 使用无截图实现，例如基于 Widgets PageRouteBuilder 的薄路由，不套 CardRouteMixin；它有独立的私有 SnapshotController，不能假设设置标准 allowSnapshotting:false 就能关闭（[S100](13-sources.md#s100)）。CardPageRoute 仅用于不承载 live 终端的普通二级页面，显式 MaterialPageRoute 不会自动换动画。需要 Hero 时使用稳定 controller 并正确释放。R82/R85 必须验证持续输出期间 push/pop 的视图身份、输出与焦点连续性，主 tab 不复制视图或整页截图。

**不安装 ThemeCrossFade。** 它在 child 之后画旧主题截图，公开 API 没有受锁控制的清图接口；仅关闭新捕获不足以处理已有截图。直接切主题可保留状态，不能通过更换主题树/key 让终端重挂载。这个决定来自已读源码，不是已复现用户数据泄漏；GU0 的交错锁定测试负责验证本方案。

Prism 的 UiLocalizations 由本地 delegate 映射到当前 `LText/localized()` 和 `translations_en.dart` 体系；不假设项目有 ARB/gen-l10n，不搬参考应用的产品文案。继续提供当前 Material/Widgets/Cupertino delegates。

### 3.3 依赖与兼容边界

R82 只增加固定 Git ref 的 prism_ui 和解析所需最小变更，提交 pubspec.lock。Dart、Flutter 声明约束满足不等于依赖解算/构建已过；必须实际验证。保持 Riverpod、dartssh2、libghostty/native 与存储实现，不因 FlClash 使用不同依赖而升级它们。

建议新增文件为 `shun_ui_host.dart`、`material_compat.dart`、`prism_localizations.dart`、`prism_theme.dart`、`components.dart`、`non_modal_panel.dart`（均在 `lib/presentation/ui/` 下）。只实现当前功能所需的薄适配；不要再做可插拔 UI 框架、全局万能控件或另一套状态管理。新增宿主回归集中在 `test/ui_host_test.dart`。

迁移期间可保留尚未替换控件的 Material 依赖；R96 根据真实消费者清理。终端/第三方部件必要的 Material Theme、Material、ScaffoldMessenger 属于兼容边界，不以“Material import 清零”作为完成标准。保留点逐项写文件、消费者、原因，不能掩盖未迁移页面。

### 3.4 非模态面板

Prism 的 showSheet/showSnapSheet/showFormSheet 走模态路由，透明遮罩仍会挡背景。R84 的本地 non_modal_panel 采用 Prism 表面/圆角/局部动效，复用已有非模态布局；R89 验证实际 Tailscale 流程。不要复制私有 SnapSheet 实现或另造全局导航器。

背景列表可点击、下滑/返回/切底栏关闭、未存草稿丢弃、已存 key 固定掩码且只能改/删，都是出口条件。判据是面板不新增阻断背景的遮罩和真实点击可达，不要求整棵树 ModalBarrier 数量为零；现有路由可能保留不拦点击的不可见 barrier。普通破坏性确认继续使用模态，不能为视觉一致让确认期间背景可操作。

## 4. 不能丢的项目契约

| 依据 | 保留行为 | 主要任务/用例 |
|---|---|---|
| F26/F30，[UI 文案规范](../../../docs/dev/ui-text.md) | FormGap 20dp；helper/subtitle ≤16 汉字；段落 ≤30；ⓘ 48dp、独立语义 | R84/R96，UIM05/UIM18 |
| F41，[交互复盘](23-ux-reference-review.md) | Tailscale 非模态、固定 key 掩码；隐藏主机在安全恢复；插件归组；刷新/旧状态时间保持 | R86/R87/R89，UIM07/08/11 |
| F42，同上 | ⊕ 直接表单；类型/认证原地换；密码/密钥/凭据/Tailscale；名称下分组；高级一层；无管理页 | R88，UIM09 |
| F34/F37/F38，R68/R70 | 监控 tab 左右滑；仅终端选中时任意区域双指上滑；更多入口；小预览/返回优先 | R91/R95，UIM13/UIM17 |
| 网络/安全/恢复契约 | RoutePlan 唯一、代理失败无直连、逐跳 host-key 先于认证、恢复不重放输入/startup | R89/R97，UIM10/UIM20 |
| 终端/应用锁契约 | 原始 VT、单 live view、单输入；锁罩覆盖全局层、焦点与语义不穿透；预览不落盘 | R82/R93–R95，UIM03/UIM15–17 |

应用身份仍是 `top.xdwa.shun`，debug/profile 仍用既有隔离标识；数据结构与存储不迁移。现有 R73–R79 源码已落地但真机结果未完成，这些任务不作为 UI 阶段的已测替代物，也不因为重新画了界面就标 DONE。R71/R80 及其他 DEFERRED 功能不随本次自动启动。

## 5. 六阶段、十八个任务

每项的完整落点、交付物、验收、停止条件在 docs/08 和 tasks.json；以下只给执行顺序与可见出口。一个任务可以分多个小提交，但未满足自己的完成条件就保持 IN_PROGRESS。

| 阶段 | 任务 | 本阶段用户可见结果 | 进入下一阶段前 |
|---|---|---|---|
| U0 接入前提 | R81 基线；R82 固定依赖与薄宿主 | 仍以原业务界面为主，基础接入可运行 | GU0：真实基线、构建、锁罩/焦点/非模态样例通过 |
| U1 视觉基础 | R83 主题；R84 公共控件；R85 主外壳 | 主题、导航、控件开始使用同一套规则 | GU1：五入口与状态留存、规则检测和返回行为通过 |
| U2 设置与连接 | R86 设置/安全/数据/片段；R87 连接列表；R88 主机表单；R89 凭据/代理/Tailscale | 最常用业务页面完成；设置是第一张完整校准页 | GU2：字段/保存/非模态/敏感保护不退化 |
| U3 工作与扩展页 | R90 SFTP/转发；R91 监控/管理；R92 插件/远控/AI | 二级工作页面统一，全部入口可达 | GU3：受控业务流程、取消、断线与资源释放通过 |
| U4 终端 | R93 外壳/标签；R94 输入；R95 总览 | 终端周边、输入与总览完成统一 | GU4：单视图/输入、IME 可测部分、手势、全屏/PiP 通过 |
| U5 收口与交接 | R96 覆盖/无障碍/清理；R97 性能/回归；R98 候选交接 | 全界面完成，并有供真机验收的明确候选 | GU5：UIM01–21 本地范围通过；UIM22 转 R26 |

依赖关系的唯一分叉在 R89 之后：R90/R91/R92 文件边界不同，可并行；R93 必须等待三项完成。其余按 tasks.json 的依赖推进，不能按任务数字猜测或一次领整阶段。

## 6. 文件分工和模型执行边界

- **基础负责人（R81–R85）**独占 app.dart、theme、HomeShell、公共控件、依赖与 lock；先冻结窄接口。
- **U2 按顺序完成。** R86 先校准设置；R87 与 R88 不同时改 vault 打开编辑器/保存回调；R89 接完敏感与非模态流程才并行 U3。
- **U3 可并行三个模块。** 文件任务负责 SFTP 和 port_forward_sheet；管理任务负责 system_management 及其 server_network_chart；扩展任务负责插件/远控/AI、remote_entry_widgets 及本模块测试。遇到共享控件缺陷由基础负责人修，模块不得各做一套主题。
- **R93–R95 同一终端负责人串行。** 共享 home_shell、输入焦点、手势、PopScope、全屏/PiP，期间其他模型不改这些文件。
- **集成人维护共享记录。** translations_en.dart、ui_gallery_test.dart、使用手册和计划状态由集成人合并；模块提供文案、截图场景和验收记录。并行使用独立 worktree/分支，集成到同候选后再验相关流程，不在同一工作区互踩。
- 业务模型、RoutePlan、存储、终端 engine/adapter 不在普通 UI 修改白名单。若 UI 接入确实需要接口修复，先指出调用链和最小差异；不要把重构整个控制器混进视觉任务。

完整弹层也有唯一负责人：R88管connection_probe_sheet；R89管connection_prompts/host_key_dialogs/security_key_actions；R93管connection_transport_sheet的协议/tmux选择与Mosh确认。R86同时核对terminal_key_feel_tiles/terminal_engine_status。R96只收口遗漏，不用它代替前述主流程归属。

## 7. 验证入口：复用现有测试，修正选择器

以下是已经存在的文件，不是本轮已经运行的结果。设备脚本与环境准备只按 [开发手册](../../../docs/dev/README.md) 执行；不把 integration_test 文件直接当桌面单测命令。

| 范围 | 优先复用的回归入口 |
|---|---|
| 宿主/锁/主题 | app_lock_test.dart、secret_content_test.dart、security_key_prompt_test.dart、terminal_detached_theme_test.dart、vault_logo_theme_test.dart；新增 ui_host_test.dart |
| 公共控件/布局 | ui_rules_test.dart、ui_spacing_regression_test.dart、hint_test.dart、localization_coverage_test.dart、ux02_a11y_test.dart、r25_large_text_test.dart |
| 设置/数据 | r25_settings_test.dart、cloud_backup_screen_test.dart、lan_transfer_screen_test.dart、known_hosts_screen_test.dart、snippets_screen_test.dart；integration_test/r79_settings_test.dart |
| 首页/表单/Tailscale | vault_catalog_section_test.dart、vault_host_menu_test.dart、host_editor_r41_test.dart、host_editor_layout_test.dart、host_route_editor_test.dart、credentials_identity_test.dart、tailscale_catalog_screen_test.dart；r73/r75/r40/r41/r43 integration 流程 |
| 文件 | sftp_service_cache_test.dart、sftp_terminal_usability_test.dart、sftp_editor_test.dart、r24_borrowers_test.dart；integration_test/r24_files_test.dart |
| 管理/扩展 | server_panel_test.dart、system_management_confirm_test.dart、plugins_screen_test.dart、plugin_session_test_screen_test.dart、rustdesk_screen_test.dart、ai_chat_sheet_test.dart、ai_cli_tools_sheet_test.dart；r68/r39/x12 integration 流程 |
| 终端/输入/总览 | terminal_view_ownership_test.dart、terminal_reparent_test.dart、terminal_input_panel_test.dart、terminal_input_routing_test.dart、terminal_pip_update_test.dart、session_overview_test.dart；r19/r25_input/r70 integration 流程 |

表中无目录前缀的 Dart 测试位于 `test/`。具体 test_ids 是 UIM 用例，以上文件负责实际执行；旧 UX/UXR/SWP/CRD 等结果保留原候选证据，新局部测试不替换其整体真机结果。

现有 UI 规则扫描只识别部分 Material 控件，旧测试还有 TextField/Scaffold/BottomSheet 类型断言。R84 必须纳入实际 Prism/封装控件，并扩展 secret_content_test.dart 的秘密输入识别，维持禁学习/联想/自动更正和敏感屏保护的扫描及运行时断言。改用稳定 ValueKey、语义与行为断言；**禁止通过改控件名让规则漏检、删除原失败场景或放大文字上限。** 每个模块改动时运行相关回归，R97 再集成，不能把所有测试留到最后。

### 图库与视觉矩阵

复用现有出图入口，先按开发手册准备 Flutter/native/字体环境，再运行：

```bash
# 仓库根；目录改为当次实际绝对路径，并写入 evidence。
SHUN_UI_GALLERY=/absolute/path/to/ui-artifacts flutter test --no-pub test/ui_gallery_test.dart
```

该测试依赖环境变量和 macOS 字体，缺条件会 skip；它负责保存截图，**不是自动视觉比对**。R81 已补首页、终端、总览、SFTP 场景，26项测试生成44张明暗图并逐张目检；R96继续对全清单出图。证据写图片路径/hash、场景与检查结论，不能只写“测试退出码 0”。

所有页面至少覆盖浅/深和正常字号；代表性长表单、输入/总览和双栏再覆盖中文/英文、至少 360dp 窄屏、横屏、≥600dp 宽屏，以及 1.3/2.0 字号、键盘/加载/空/错态。不要求无意义的全笛卡尔积，但每个高风险组合必须点名；大字可以滚动，不可缩小字体满足首屏。Android 14+ 非线性字体和真实预测返回若本机没有设备，进入 UIM22 的明确待测项，不能用 API 30 模拟器替代。

## 8. 性能预算与测量口径

**以下是迁移出口预算，R81已采集完整迁移前基线，实测结果及未测范围见[R81](../evidence/R81.md)。** R97 用同设备/API/ABI/刷新率、profile 模式、构建参数、主题、数据量与脚本复测。取得基线不表示预算已通过，也不表示新UI更快；模拟器只证明同环境回归趋势，真机“流畅”由 UIM22/R26 补充。

固定入口为 `integration_test/r81_ui_baseline_test.dart` 与 `tool/r81-ui-baseline.py`；最终正式记录为 `profile-20261106/`。R85/R97若因控件换型需要更新定位方式，只调整稳定key/语义适配，保留数据量、交互、计时与采样口径，重新构建并记录新指纹，不能跳过原场景。

R81实际观察需由R95/R97跟进：模拟器raster耗时与轮次波动偏高；VT/总览后关闭四会话，Native allocated仍比载入高28.76MiB、PSS高25.55MiB。它尚不能直接定性为泄漏，但也没有完全回落；100次独立生命周期循环的较小增长不能抵消此项。若测量噪声仍不足以分辨原1个百分点门槛，采用受控旧/新候选对照复测并如实记录阻塞，不放宽下表预算。

每个基础交互场景预热 5 秒、采集至少 30 秒、重复 3 次，记录原始 trace 与每次值，报告重复测量中位数；记录 UI/build 和 raster 两条耗时，不用 debug FPS。场景包括设置/主机列表滚动、表单/非模态面板开合、tab 切换、终端持续输出时打开总览。固定基线的负载、字体、设备和数据，环境不一致先解释重采，不直接比较。

| 指标 | 迁移出口门槛 |
|---|---|
| UI/build、raster 的 p95 | 分别不超过 max（设备一帧预算 1000/Hz ms，原基线 p95 ×1.10） |
| 卡顿帧占比 | 统一以任一阶段超一帧预算计；不高于原基线 +1 个百分点 |
| 稳态总资源 | 同负载/同稳定时点的进程总内存增量不高于 max（20MiB，原基线的 10%）；同时记录 Dart heap 与 native/进程值 |
| 重复开关 | 100 次开关/切换后会话、controller、view 与监听释放正确，无持续单调资源增长；不能只看 Dart GC |
| 输入与 VT | 沿用现有本地提交输入→SSH 写入 p95 50ms 目标；4 活动会话/受控 scrollback/5MiB VT、50 次键盘变化不丢字节、不重放 |

既有更严格的原业务预算继续生效。预算超限先定位重建、布局、blur、动画或资源生命周期；允许减去装饰性效果，不能通过丢 VT、关测试或降低交互能力换绿。基线异常、测量噪声或硬件缺失有证据就记录具体阻塞，不能事后改阈值让当前实现通过。

## 9. 每个任务的固定完成方式

1. 读取 AGENTS、STATUS、docs/24、对应 tasks.json 条目及依赖 evidence；看真实 HEAD/dirty、源码和已有测试。只领取依赖已完成的最小任务。
2. 在自己的 code_targets 内实现最小可运行纵向切片；相关行为用现有测试验证，公共规则也运行。不能只交截图/空壳，也不能一口气换完整 lib 目录。
3. 更新实际改变的使用手册、英文文案和测试；新旧图像采用相同 fixture/视口。无用户可见改变的基线任务不用提前改用户手册。
4. 在 `evidence/Rxx.md` 记录源码/lock/SDK、命令/退出码、测试数量与 skip、设备/fixture、截图/trace、未测风险和独立审查结论。UNIT/INTEGRATION/EMULATOR/USER_DEVICE 分开，安全内容使用 fixture 占位。
5. 完成一个可回退的小提交；用既有 set_status.py 记录真实任务/用例状态，再运行 sync_docs.py 和 validate_plan.py。DONE 必须有交付、关联用例的实际证据、提交与审查，计划检查不能算 App 测试。
6. 交接仅报告完成 ID/commit/证据、明确未测、下一项依赖。任务尚未结束就保留 IN_PROGRESS，不用“基本完成”掩盖缺口。

每阶段出口要求本阶段列出的任务完成及 GU 门禁证据齐全；任务脚本只验证依赖图结构，不会代替模型检查依赖是否实际 DONE。

## 10. 新候选与原日用/发布链衔接

R98 是 UI 代码与本地验证的交接出口，**不依赖 R26、R27、R30**。R26 增加 R98 作为新 UI 候选完成依赖；旧包反馈可继续记录，原 IN_PROGRESS 不改。R30 保留 X13 直接依赖，并纳入全部 210 条当前用例，修正原 160 条列表漏掉后来用例的问题。

执行链为 U0–U5 → R26 新候选真机 → 原 R27/R29/X13 → R30 → R31，实际并行/先后以 tasks.json 的依赖为准。R28/X12 等既有前提保留，不把这一简写当成新串行调度器。

- **UIM01–UIM21**：各 UI 任务本地/受控环境范围；全部通过才交 R98。
- **UIM22**：用户真实输入法、手指/系统导航、锁屏、长会话、VPN+TailSocks 和受影响原日用清单；由 R26 执行，在 U5 可保持 NOT_RUN/BLOCKED。
- UIM22 与原硬件/真实账号缺口仍约束最终交付；GU5 不意味着 CORE_READY/FULL_READY，原 G/GX 门禁不被重置或跳过。
- 新候选用独立记录绑定源码、lock、APK hash/类型、签名、设备、输入法。旧 33 包安装/结果保留原归属；改了代码后重跑受影响项，不能将 33 包和新候选拼成“全部通过”。

R98 生成 `evidence/R98-candidate.json`（实施时新增），字段至少含：source_commit、lock_sha256、SDK、reference_shas、built_artifacts（类型/hash/路径）、device_matrix、test_evidence、screenshot_index、performance_evidence、not_run、rollback_commit。未产出的正式签名 APK 字段写 null，不能填未来值。正式签名和安装用户手机遵循现有当次授权；规划阶段无需先请求，普通可逆代码/本地验证按已确定任务推进。

回退采用任务粒度提交或独立 worktree，保留当前业务/数据与旧证据；不得清理用户数据或通过降低应用版本强行回滚安装。依赖/宿主失败只阻断依赖它的任务，不要求回到多库选型。

## 11. 后续模型的唯一启动任务

现在只执行 **R83**：统一Prism语义主题、字阶、形状与动效，保留旧主题ID、系统模式、背景/字体及终端配色同步。R81已提供基线，R82已通过单宿主/锁罩/焦点/非模态与隔离构建，UIM01–UIM03及GU0 PASS；先读对应证据。执行提示词见[模型交接](10-agent-handoff.md)。按UIM04完成主题回归和浅深对照图后交R84；没有第二套候选UI，也不自动执行DEFERRED功能。
