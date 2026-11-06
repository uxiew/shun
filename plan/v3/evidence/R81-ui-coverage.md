# R81 UI 覆盖盘点

日期：2026-11-05。盘点基线：`shun/v3 @ a46a88854205c546c6c5d107073fcb70708166bd`。范围：实际页面、完整弹层、关键加载/空/错态、迁移责任与现有回归入口。

本文来自基线源码和测试定义的只读盘点，未执行测试、截图、服务或设备。**测试文件存在不等于本轮 PASS。** 本文记录的是本轮开始时的覆盖与缺口；后续图库修改、实跑结果、PNG/hash、目检和性能证据以 [R81.md](R81.md) 为准，不用本文替代执行证据。任务及用例状态仍以 tasks.json / verification-cases.json 为准。

路径缩写：`P/` = `lib/presentation/`，`S/` = `lib/presentation/screens/`，`W/` = `lib/presentation/widgets/`。均相对仓库根。测试文件默认位于 `test/`，设备测试另标 `integration_test/`。下表是 docs/24 的覆盖落实，不建立另一套任务队列。

实际外壳为 `lib/app.dart:121` 的 MaterialApp → `P/home_shell.dart:23` 的五页 IndexedStack。screens 目录有 22 个 Dart 文件（包含 part 文件）；没有 main_screen.dart 或 manage_screen.dart。

## 1. 页面、完整弹层与关键状态

“图库”仅指 a46a888 时 `test/ui_gallery_test.dart` 的场景定义，不表示历史 evidence 中绝无其他截图，也不表示后续补图尚未完成。

| 负责人 | 真实文件 | 实际入口、完整表面与需保留状态 | 已有回归入口（本盘点未执行） | 基线图库覆盖 / 尚缺 |
|---|---|---|---|---|
| R82 宿主与锁罩 | `lib/app.dart`；`W/app_lock_gate.dart`；`P/terminal/ghostty_terminal_view.dart` | 全应用入口；冷启动锁罩、后台遮挡、验证中、取消/失败、解锁；安全密钥通过 root Navigator 询问；后台终端主题同步 | app_lock_test.dart、secret_content_test.dart、security_key_prompt_test.dart、terminal_detached_theme_test.dart | 缺锁罩/失败、覆盖二级页及弹层、解锁后状态留存 |
| R83 主题与背景 | `P/theme.dart`；`W/custom_background.dart` | 浅/深/系统；既有主题 ID；局部/全局自定义背景、图片失效；主题切换保持终端身份 | background_image_service_test.dart、vault_logo_theme_test.dart、terminal_detached_theme_test.dart、r25_large_text_test.dart | 原图库仅默认深色；缺浅色、背景、失效、主题切换 |
| R84 公共控件 | `W/form_gap.dart`、`hint.dart`、`choice_segments.dart`、`empty_state.dart`；`P/localization/localized_widgets.dart` | 表单间隔、字段/校验/禁用、分段、空状态、全局 ⓘ 帮助面板；普通模态确认和非模态表面区分；英文/大字 | ui_rules_test.dart、ui_spacing_regression_test.dart、hint_test.dart、ux02_a11y_test.dart、localization_coverage_test.dart、secret_content_test.dart | 缺独立公共控件与帮助长文/横屏/大字场景 |
| R85 五入口外壳 | `P/home_shell.dart` | 连接/终端/文件/片段/设置；IndexedStack 留存；全屏/PiP 导航隐藏；返回优先级；UU 全局回调确认仍受锁罩 | session_overview_test.dart、terminal_reparent_test.dart、terminal_pip_update_test.dart | 缺真实 HomeShell、五入口选中态、全屏/PiP/返回 |
| R86 设置、主题选择、片段 | `S/settings_screen.dart`、`settings_screen_dialogs.dart`、`snippets_screen.dart`；`W/terminal_key_feel_tiles.dart`、`terminal_engine_status.dart` | 全设置分组；主题选择面板；背景选择/移除/失效；语言/字号/按键手感/引擎状态；更新检查中/失败重试；片段空/列表、新建编辑面板、删除确认 | r25_settings_test.dart、snippets_screen_test.dart、r25_large_text_test.dart；integration_test/r79_settings_test.dart | 已定义 settings-data；缺设置其他段、主题面板、片段及引擎错误态 |
| R86 安全与日志 | `S/app_lock_settings_screen.dart`、`hidden_hosts_screen.dart`、`known_hosts_screen.dart`、`app_log_screen.dart`；`W/connection_event_tile.dart` | 应用锁开启/关闭验证及选项；隐藏主机空/恢复；可信指纹列表/删除确认；日志筛选、空/列表、详情面板、导出前预览/复制、清除确认 | app_lock_test.dart、known_hosts_screen_test.dart、app_log_screen_test.dart、r25_connection_log_screen_test.dart、vault_catalog_section_test.dart | 全部缺 |
| R86 备份/恢复 | `S/cloud_backup_screen.dart`；`W/github_manual_config.dart`、`vault_import_dialog.dart`、`vault_passphrase_dialog.dart` | WebDAV/S3 配置、测试/同步/恢复/忙碌/失败、版本；备份口令及重复确认、解密口令、导入合并/替换确认；GitHub 登录/手动配置仅在既有 feature gate 打开时 | cloud_backup_screen_test.dart、encrypted_vault_file_test.dart、vault_import_test.dart、secret_content_test.dart、ui_spacing_regression_test.dart | 已定义 WebDAV、S3 静态表单；缺全部确认/口令、忙碌/失败、条件 GitHub 表面 |
| R86 局域网收发 | `S/lan_transfer_screen.dart` | LanSendScreen 准备/二维码等待/已送达/停止/无网络/失败；LanReceiveScreen 扫描、接收、解密、导入确认、成功/失败 | lan_transfer_screen_test.dart；integration_test/r62_lan_transfer_test.dart、r62_qr_scan_test.dart | 全部缺；系统扫码/文件选择另归设备验证 |
| R87 连接首页与主机菜单 | `S/vault_screen.dart`；`W/vault_host_items.dart`、`catalog_host_sections.dart`、`host_actions_sheet.dart`、`host_address_line.dart`、`host_type_icon.dart`、`host_system_icon.dart` | 列表/网格/树；分组/搜索；主机详情对话框、⋮ 动作面板、删除确认、隐藏撤销；首次加载、真正空、筛选无结果、全部隐藏、秘密不可读；目录来源刷新中/旧缓存时间/在线状态 | vault_loading_test.dart、vault_host_menu_test.dart、vault_catalog_section_test.dart、vault_group_chip_test.dart、vault_unreadable_secrets_test.dart、r25_host_details_test.dart | 缺首页全部核心状态，是 R81 优先补图项 |
| R87 Tailscale 目录/来源 | `S/tailscale_catalog_screen.dart`；`W/catalog_source_section.dart`、`catalog_text.dart` | 多来源列表、CatalogSourceScreen、恢复缺失来源的 _FieldsDialog；空来源、缺来源、无 key、未读取、空设备、缓存完整/不完整、失败保留旧数据、隐藏设备 | tailscale_catalog_screen_test.dart、catalog_auto_refresh_test.dart、vault_catalog_section_test.dart | 全部缺；这两页及恢复对话框仍有生产入口，不可当旧页直接删除 |
| R88 主机表单、类型与分组 | `W/host_editor.dart`、`connection_endpoint_fields.dart`、`connection_type_sheet.dart`、`host_group_field.dart`、`credential_field.dart`、`unsupported_connection_page.dart` | ⊕ 直达表单；SSH/Mosh/Telnet/更多类型原地切换；密码/密钥/凭据/Tailscale；分组选择/新建；高级一层；保存校验、键盘底栏、放弃修改确认；unknown protocol 只读保留页 | host_editor_r41_test.dart、host_editor_layout_test.dart、connection_type_sheet_test.dart、credentials_identity_test.dart、plugin_host_editor_test.dart；integration_test/r73_editor_walkthrough_test.dart | 已定义首屏、密钥、凭据、分组、更多类型、RustDesk、高级；缺编辑/失败/键盘、Tailscale 认证、UU/插件/unknown、放弃/新分组 |
| R88 路线与测试连接 | `W/connection_route_editor.dart`、`connection_route_draft.dart`、`jump_route_choice_dialog.dart`、`route_legs_view.dart`、`connection_probe_sheet.dart` | 代理选择、跳板加/删/排序、展开跳板路线确认；路线错误/警告；探测阶段、认证等待、成功/失败/tmux 状态、取消 | connection_route_editor_test.dart、host_route_editor_test.dart、jump_route_choices_test.dart、r25_probe_record_test.dart、host_editor_r41_test.dart | 高级长图只间接涉及；缺路线确认、完整探测面板及各态 |
| R89 凭据与代理 | `W/keychain_sheet.dart`、`identity_editor.dart`、`proxy_profiles_page.dart`、`proxy_profile_editor.dart`、`ssh_key_import.dart`、`secret_content.dart` | 凭据/私钥空/列表；新建/编辑身份、删除引用确认；导入私钥与口令；代理空/加载/错误、选择/编辑/删除影响确认 | r25_keychain_test.dart、credentials_identity_test.dart、proxy_profiles_page_test.dart、secret_content_test.dart | 仅 proxy-editor；缺凭据/密钥/代理列表及所有敏感与删除弹层 |
| R89 登录与信任 | `W/first_login_dialog.dart`、`connection_prompts.dart`、`host_key_dialogs.dart`、`security_key_actions.dart`、`security_key_prompt.dart`、`tailscale_check_card.dart` | 首次登录、交互认证；首次指纹/指纹变化阻断；安全密钥新建/读取选择、创建选项、公钥复制、等待触碰/PIN/失败/取消；Tailscale check URL 允许/拒绝/打开失败 | first_login_dialog_test.dart、connection_prompts_test.dart、host_keys_test.dart、security_key_actions_test.dart、security_key_prompt_test.dart、tailscale_ssh_ui_test.dart | 全部缺；tailscale_check_card 被探测、终端连接状态、AI CLI 共用，由 R89 统一负责 |
| R89 Tailscale 非模态设置 | `S/tailscale_settings_screen.dart` | 默认两项、已存 key 固定掩码、修改/取消修改、删除 key 确认、移除来源确认；高级路线/端口/分组；读写中/拒绝/失败/保留缓存；背景可操作及下滑/返回/切底栏关闭 | tailscale_catalog_screen_test.dart、tailscale_key_input_test.dart、tailscale_ssh_ui_test.dart | 已定义高级长图 tailscale-settings；缺真正背景叠层、已存掩码、修改失败、确认及关闭行为图 |
| R90 文件与传输 | `S/sftp_screen.dart`、`sftp_screen_pane.dart`；`W/sftp_transfer_dialogs.dart`、`sftp_permissions_dialog.dart` | 单/双栏、远端/手机切源、未挂载、加载/空/读取失败/断线；操作菜单、多选、目录/重命名/压缩输入；权限；大文件下载、远端文件变化、删除、移动、跨机路径/手机中转、覆盖、续传确认；传输进度/取消/失败 | sftp_terminal_usability_test.dart、sftp_service_cache_test.dart、r24_borrowers_test.dart、server_transfer_test.dart；integration_test/r24_files_test.dart | 全部缺，是 R81 优先补图项；顶层初始化错误边界见第 5 节 |
| R90 编辑器与转发 | `W/sftp_editor.dart`、`port_forward_sheet.dart` | 编辑、行号、高亮、缩放、换行、搜索/无匹配/正则错误、保存/冲突/未保存离开确认；端口转发创建/列表/停止及断线禁用 | sftp_editor_test.dart、sftp_terminal_usability_test.dart、r24_borrowers_test.dart | 全部缺；端口转发不能漏在主机/终端菜单之间 |
| R91 监控与管理 | `W/system_management/server_panel_sheet.dart`、`server_overview_panel.dart`、`process_manager_panel.dart`、`tmux_manager_panel.dart`、`docker_manager_panel.dart`、`docker_compose_panel.dart`、`service_manager_panel.dart`、`caddy_manager_panel.dart`、`sudo_prompt.dart`；`W/server_network_chart.dart` | 概览/进程/tmux/Docker/服务/Caddy 六 tab 左右滑；图表提示；加载、空/过滤空、不可用、错误、断线禁用/旧概览数据；进程信号/优先级、tmux socket/创建/结束/鼠标、镜像拉取/容器/Compose 操作、服务操作、Caddy 新建编辑删除、sudo 密码完整确认 | server_panel_test.dart、monitor_details_test.dart、server_network_chart_test.dart、tmux_manager_panel_test.dart、caddy_manager_panel_test.dart、system_management_confirm_test.dart、system_management_sudo_test.dart | 全部缺；破坏性确认继续模态；该行同组无目录前缀文件均位于 W/system_management/ |
| R92 插件 | `S/plugins_screen.dart`、`plugin_detail_screen.dart`、`plugin_session_test_screen.dart` | 发现/检查列表与无结果/失败；来源/签名/授权状态、批准确认、启停/撤销；诊断会话 unavailable/启动/输出/输入/关闭 | plugins_screen_test.dart、plugin_session_test_screen_test.dart、official_plugins_test.dart；integration_test/r42_plugin_test.dart、x12_plugin_host_test.dart | 全部缺，保留实验入口和能力限制 |
| R92 外部远控 | `S/uuremote_screen.dart`、`rustdesk_screen.dart`；`W/remote_connections.dart`、`remote_entry_widgets.dart` | UU/RustDesk 主机页与设置页；命名/重命名/删除；未安装/过旧/待信任/签名变化/就绪；不继承 SSH 路线确认；UU 绑定回调确认、等待/结束/重试；RustDesk ID 保存/启动状态 | uuremote_screen_test.dart、rustdesk_screen_test.dart、remote_entry_migration_test.dart；integration_test/r39_remote_entries_test.dart、rustdesk_bridge_test.dart | 主机表单有 RustDesk 输入图；缺真实远控页及全部确认/状态 |
| R92 AI | `W/ai_providers_page.dart`、`ai_chat_sheet.dart`、`ai_panel.dart`、`ai_markdown.dart`、`ai_cli_tools_sheet.dart` | 服务商列表/编辑/删除；风险确认；聊天空/生成/错误/内容、隐私/发送预览/新对话/切服务商/执行命令/链接确认；CLI 检测/取消/失败/空/最近工作、检测范围、项目目录/tmux 启动确认 | ai_settings_test.dart、ai_chat_sheet_test.dart、ai_cli_tools_sheet_test.dart、ai_markdown_test.dart、ai_cli_fault_matrix_test.dart | 全部缺；沿用现有 feature gate，不因补图开启默认禁用功能 |
| R93 终端外壳与连接状态 | `S/terminal_screen.dart`、`terminal_screen_pane.dart`；`W/session_tab_actions.dart`、`terminal_link_sheet.dart` | 空终端、标签/多会话/分屏、连接中/失败/取消/重试、连接横幅/恢复/切换、全屏/PiP；关闭单窗/整机确认；链接确认及危险链接拒绝 | terminal_connection_banner_test.dart、terminal_connection_dialog_test.dart、terminal_links_test.dart、terminal_view_ownership_test.dart、terminal_reparent_test.dart、terminal_pip_update_test.dart | 全部缺，是 R81 优先补图项 |
| R93 协议/tmux/Mosh | `W/connection_transport_sheet.dart` | 协议状态与切换、设默认、切换取消、端口转发停止确认；tmux 只读选择的加载/空/不可用/失败；Mosh 安装提示、命令复制/粘贴、安装执行确认 | terminal_transport_ui_test.dart、mosh_install_hint_test.dart、connection_switch_test.dart；integration_test/r42_transport_test.dart | 全部缺；这是完整表面，不只是 badge |
| R94 输入与剪贴板 | `S/terminal_screen_input.dart`；`W/terminal_input_panel.dart`、`terminal_compose_box.dart`、`terminal_key_button.dart`、`terminal_keys.dart`、`terminal_special_keys.dart`、`terminal_key_settings_sheet.dart`、`terminal_paste_sheet.dart`；`P/terminal/terminal_view.dart` 中 _TerminalCopySheet | 快捷键/大输入框/系统键盘；草稿保留、目标失效/孤立草稿/改目标、发送失败；快捷键模板/排序/主机范围/自定义键对话框；粘贴风险/换行/控制字符/确认；全文文字快照选择复制面板 | terminal_input_panel_test.dart、terminal_input_routing_test.dart、terminal_compose_drafts_test.dart、terminal_hardware_keys_test.dart、terminal_paste_page_test.dart、r25_copy_screen_test.dart | 全部缺；复制面板由 terminal_screen.dart:794 实际调用，R94 只改该 UI，不碰 engine 适配 |
| R95 会话总览 | `W/session_overview.dart`、`two_finger_swipe.dart`、`session_tab_actions.dart`；共享 `P/home_shell.dart` | 机器分组、小型文字预览、空/连接中/失败/断开/恢复中；单窗/整机关闭确认、全部重连；手势/更多入口、返回先关总览、最后标签回连接页 | session_overview_test.dart、terminal_gestures_test.dart、terminal_view_ownership_test.dart；integration_test/r70_walkthrough_test.dart | 全部缺，是 R81 优先补图项 |
| R96 全覆盖收口 | 全 `P/`；`P/localization/translations_en.dart`；`test/ui_gallery_test.dart` | 统一补浅深/中英/字号/窄宽横屏、键盘与状态图；确认所有入口可达；记录必要 Material 兼容消费者；清理已确认无入口表面 | ui_rules_test.dart、secret_content_test.dart、localization_coverage_test.dart、ux02_a11y_test.dart、r25_large_text_test.dart | 上表全部未覆盖状态的最终收口，不替代模块主流程归属 |

### 无生产入口与容易遗漏的完整表面

- `W/catalog_import_sheet.dart` 的 showCatalogImportSheet / CatalogImportPage：在基线 lib 全树搜索仅有本文件定义与内部调用，未找到生产调用点。R87 判定保留或删除，R96 确认清理；不为补图新造入口。其现有表面为导入主机页、认证/默认值/路线、校验与保存忙碌/失败。
- `S/tailscale_catalog_screen.dart:158` 的 _restore 调用 _askSource，进而展示 _FieldsDialog；恢复来源对话框仍现役。多来源目录由 openTailscale 及 Tailscale 设置“来源”进入，不能按旧页删除。
- `W/unsupported_connection_page.dart` 是 `W/host_editor.dart:248` 的 unknown protocol 分支，归 R88；原配置保持，不能默认为 SSH。
- `W/jump_route_choice_dialog.dart` 由 connection_route_editor.dart:81 调用，归 R88。
- `P/terminal/terminal_view.dart:173–243` 的全文复制面板由 terminal_screen.dart:794 调用，归 R94；仅该 UI 范围，终端核心适配不属于普通视觉改动。
- `W/tailscale_check_card.dart` 同时被 connection_probe_sheet.dart:169、terminal_screen_pane.dart:98、ai_cli_tools_sheet.dart:894 使用，认证提示统一归 R89，使用方负责其场景回归。
- R93–R95 共享 session_tab_actions/HomeShell，由同一终端负责人串行；R96 只收遗漏，不改变主负责人。

## 2. 必须冻结的行为契约

| 契约 | 基线源码/测试证据 | 迁移要求 |
|---|---|---|
| F26/F30 | W/form_gap.dart:7 为 20；W/hint.dart:65 为最小 48×48；hint.dart:91–94 说明独立语义；ui_rules_test.dart:19,107,114,124 | 相邻输入框 FormGap 20dp；helper/subtitle ≤16 汉字、段落 ≤30；ⓘ 单独可点/可读，不合并进开关语义 |
| F41 非模态 | S/tailscale_settings_screen.dart:43–76 使用 Scaffold.showBottomSheet；tailscale_catalog_screen_test.dart:513,530 覆盖背景点击、下滑及切底栏 | 背景可点；下滑/返回/切 tab 关闭并丢未存草稿；不能换成透明遮罩的模态 sheet。判据是实际可点击，不要求整棵树 ModalBarrier 数量为零 |
| F41 key 与目录 | tailscale_catalog_screen_test.dart:383–495 覆盖掩码、修改、拒绝新 key 保留旧值；:254 约束缓存时间/不完整/在线措辞 | 已存 key 无 reveal；修改/删除出口保留；目录在线不是 SSH 已连接；首次进入/回前台刷新与间隔保留 |
| F41 设置归组 | S/settings_screen.dart:554–593 为插件/UU/RustDesk；:643 为安全区隐藏主机恢复 | 入口归组与恢复路径不改变 |
| F42 表单 | W/host_editor.dart:354–408,639–678；host_editor_r41_test.dart:447；S/vault_screen.dart:867–898 | ⊕ 直接表单；协议/认证原地换且留草稿；分组在名称下；高级一层；密码/密钥/凭据/Tailscale 保留；不增管理页 |
| 终端单所有者 | terminal_view_ownership_test.dart:28；terminal_layering_test.dart:99；W/session_overview.dart:62 | 原始 VT 不动；同终端一个 live view/输入所有者；总览仅内存文字快照，不另挂 live view、不落盘 |
| 总览/手势 | P/home_shell.dart:119–126 限定选中终端；session_overview_test.dart:271,317,377,585,765,1049 | 任意区域双指上滑；普通滚动/双键/鼠标输入不误吞；更多入口保留；打开总览底页无焦点；返回先关总览、最后标签回连接页 |
| 监控手势 | W/system_management/server_panel_sheet.dart:152–178 为 TabBar + TabBarView；server_panel_test.dart | 概览/进程/tmux/Docker/服务/Caddy 六 tab 可左右滑；断线时管理操作禁用、概览保留既有数据并提示断开 |
| 应用锁 | W/app_lock_gate.dart:44–56 为 ExcludeSemantics、ExcludeFocus、IgnorePointer；lib/app.dart:103–109,139–140 | 锁罩包住全部 Navigator/提示/Overlay/效果；不重建底页；解锁恢复原焦点；锁着返回不弹底页 |
| 秘密输入 | secret_content_test.dart:381–421；W/secret_content.dart | Prism 输入继续进入扫描和运行时验证；IME 学习/联想/自动更正关闭，敏感屏保护保留；不得改类型逃扫描 |
| 连接安全与恢复 | plan/v3/AGENTS.md；host_keys_test.dart、route_fail_closed_test.dart、connection_prompts_test.dart | RoutePlan 唯一；代理失败无直连回退；逐跳 host key 先于认证；恢复不重放输入/startup、不暗建/暗杀 tmux |

R82 的单 Navigator、原 root key、锁罩范围、无 HomeShell/live 终端快照路由、无 ThemeCrossFade，以及 Material 兼容顺序遵循 docs/24。应用身份/数据结构/存储不变；本盘点不授予默认关闭功能、真实账号、发布或用户设备的额外权限。

## 3. 稳定选择器

以下均为基线现有 ValueKey，可用于替代 Material 控件类型断言；动态 ID 沿用真实 fixture ID，以所在表面限定查找范围。相同短 key 可在不同表面复用，不据此假定全树唯一。

| 范围 | 现有选择器 |
|---|---|
| 宿主/锁 | `home-navigation-bar`、`app-lock-cover`、`app-lock-unlock` |
| 设置/数据 | `settings-cloud-backup`、`settings-hidden-hosts`、`settings-known-hosts`、`settings-app-lock`、`settings-key-height`、`settings-key-repeat`、`terminal-engine-status`、`backup-passphrase`、`vault-import-merge` / `vault-import-replace` |
| 主机/目录 | `vault-empty-add-host`、`vault-empty-tailscale`、`vault-host-menu-${host.id}`、`vault-catalog-refresh-$id`、`vault-catalog-age-$id`、`catalog-refresh-saved`、`catalog-incomplete` |
| 表单/路线/探测 | `host-type-SSH` / `host-type-Mosh` / `host-type-Telnet`、`host-type-more`、`login-kind-password` / `login-kind-key` / `login-kind-credential` / `login-kind-tailscale`、`host-group`、`host-group-new-name`、`advanced-all`、`host-editor-save`、`host-editor-discard`、`route-choice-direct` / `route-choice-proxy`、`connection-probe-sheet`、`probe-succeeded` / `probe-failed` |
| 凭据/认证/Tailscale | `identity-password`、`identity-save`、`keychain-confirm-delete`、`proxy-save`、`first-login-dialog`、`first-login-connect`、`delete-old-host-key`、`security-key-pin`、`security-key-cancel`、`ts-settings-saved-key`、`ts-settings-change-key`、`ts-settings-save` |
| 文件/管理 | `sftp-left-pane`、`sftp-right-pane`、`sftp-pane-mode-toggle`、`sftp-mount-phone-directory`、`sftp-editor-field`、`editor-search-field`、`editor-search-count`、`sftp-permissions-input`、`port-forward-disconnected`、`server-panel-tabs`、`system-management-disconnected`、`sudo-password` |
| 扩展 | `plugin-entry-$package`、`plugin-approve-confirm`、`session-test-output`、`rd-route-accept`、`rd-trust-confirm`、`uu-offer-confirm`、`uu-route-accept`、`ai-chat-error`、`ai-chat-send`、`ai-cli-confirm-launch` |
| 终端/输入 | `terminal-tab-strip`、`terminal-area`、`terminal-pane-input-target`、`terminal-connection-status-dialog`、`terminal-connection-banner`、`transport-switch`、`tmux-pick-${row.sessionId}`、`mosh-install-confirm-run`、`terminal-input-panel`、`terminal-compose-editor`、`terminal-compose-send`、`terminal-paste-send`、`terminal-copy-snapshot`、`copy-terminal-snapshot` |
| 总览 | `session-overview`、`session-overview-scrim`、`overview-machines`、`overview-window-${window.id}`、`overview-preview-${session.id}`、`overview-close-machine-${machine.id}`、`overview-close-confirm`、`overview-reconnect-all` |

`test/ui_rules_test.dart:20–25` 目前仅识别 TextField / TextFormField / DropdownButtonFormField；`test/secret_content_test.dart:381–405` 同样依赖旧输入类型识别。这是 R84 必须扩展的检查器边界。不得删除失败场景、放宽文案上限或以改控件名逃过检查。

## 4. 本轮开始时的图库与补图范围

冻结口径：a46a888 的 `test/ui_gallery_test.dart` 为 **8 个 testWidgets / 13 个 PNG 文件名**。后续新增测试、实际执行/skip、截图及哈希由 R81.md 记录。

| 原始 PNG 文件名 | 场景 |
|---|---|
| proxy-editor | 代理新建 |
| host-editor | 新建连接长页 |
| host-new-first | 新建首屏 |
| host-new-key | 密钥认证 |
| host-new-credential | 凭据认证 |
| host-new-group | 分组选择面板 |
| host-new-more | 更多连接类型面板 |
| host-new-rustdesk | 原地切 RustDesk 表单 |
| host-new-advanced | 展开高级长页 |
| tailscale-settings | 展开高级的 Tailscale 设置长页 |
| cloud-backup-webdav | WebDAV 静态表单 |
| cloud-backup-s3 | S3 静态表单 |
| settings-data | 设置“数据”段 |

基线参数：默认 412dp、DPR 2、深色 midnight，高度按场景变化；依赖 macOS Arial Unicode。未配置 SHUN_UI_GALLERY 或缺字体会跳过。入口保存 PNG，**没有自动 golden 比对**。

R81 直接补齐真实连接首页、终端、总览、SFTP，优先登记加载/空/错 fixture。R96 按完整表完成各页浅深正常字号；代表性长表单、输入/总览、双栏覆盖中文/英文、至少 360dp 窄屏、横屏、≥600dp 宽屏、1.3/2.0 字号及键盘/加载/空/错态。无需无意义全笛卡尔积，但每个高风险组合要点名。Android 14+ 非线性字体和真实预测返回无合适设备时归 UIM22，不能拿 API 30 替代。

图片路径/hash、具体 fixture/视口/字体、执行退出码/skip 及人工目检结论必须来自真实出图；本表不表示已执行。历史用例结果保持原候选归属。

## 5. 已知基线边界

1. **SFTP 顶层初始化无独立错误表面。** `S/sftp_screen.dart:115–117` 仅判断 !snapshot.hasData，本地服务 Future 抛错仍进入加载指示。不能把不存在的初始化失败页标为已有覆盖；由 R90 实施时处理或明确记录。
2. **SFTP 工具栏最小命中区为 32×32，且使用 compact。** `S/sftp_screen_pane.dart:460–465`，归 R96 无障碍核对项；当前不能声称全 UI 都满足 48dp。本次仅源码检查，未作设备测量。
3. **表面存在不等于入口可达。** catalog_import_sheet.dart 无生产调用；来源恢复对话框、unknown protocol 页、终端全文复制面板均有真实调用，分别按第 1 节归属。清理前仍须核验实际消费者。

本文件只落盘盘点结论；未修改业务源码、图库、计划状态或用例结果，未触发测试/设备操作。
