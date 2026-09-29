# 08 实施路线与任务分解 V3

共53项：46项主线、7项后续；142个验收用例当前全部NOT_RUN。Rxx保留原二开任务编号，Xxx是本轮插件主线。任务ID不按数字简单串行，必须按depends_on推进。

首批R00–R04与X00；随后网络/终端/插件三条主线，独立测试APK先于真实Mosh。R30现在依赖X13，V2核心通过不能替代完整V3验收。

任务DONE必须实现、测试、证据、文档和审查齐全；证据包含commit、APK哈希、signer、依赖与真实执行者。状态合法值：NOT_STARTED/READY/IN_PROGRESS/REVIEW/DONE/BLOCKED/DEFERRED。

## 阶段门禁

|阶段|出口|必需任务|要求|
|---|---|---|---|
|P0 基线与高风险排除|G0|R01, R03, R04|已冻结基座；旧路径可构建；危险默认有回归；Ghostty Android可行性有实际证据|
|P1 连接路线复用与加固|G1|R10|Direct/外部SOCKS/ProxyJump及明确高级组合，真实PTY与无旁路门禁通过|
|E0 插件契约与IPC基础|GX0|X00, X01, X03|真实独立测试APK、双向鉴权、FD、故障与版本协商通过|
|P2 Tailscale目录与外部认证|G2|R15|最小权限目录/非破坏导入/源身份/check支持矩阵实测|
|P3 Ghostty替换|G3|R20|flterm成为实际默认，CJK/TUI/资源/16KiB通过；旧引擎不是完成替代物|
|E1 目录与外部远控adapter|GX1|X04, X05, X06, X07|插件管理、UU绑定/启动、RustDesk显式调用与设备作用域通过|
|E2 真实Mosh插件|GX2|X10|真实native/Direct UDP/VT/移动恢复与代理拒绝矩阵通过|
|P4 恢复与既有能力回归|G4|R23, R24, R25|恢复不重放，tmux目标可靠，SFTP/转发同路线，UI与状态真实|
|P5 真机、release和独立交接|G5|R31|同候选完整证据；签名/分发授权另算|
|E3 插件组合交付|GX3|X13|同候选组合证据及插件作者SDK通过|
|P6 后续候选|—|另行决定|另行授权，不自动执行|

## R00 基座、授权、许可与源码冻结

阶段：P0；状态：DONE；依赖：无；角色：架构代理。

**范围**：确认指定新仓库；默认Netcatty，记录个人实验/分发意图、dirty、原HEAD与依赖lock。无路径只保留本包，不使用历史项目路径。

**落点**：observed-baselines.json；docs/architecture/base-decision.md；上游LICENSE/NOTICE/pubspec.lock。

**交付物**：evidence/R00.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 取得真实SHA而不是版本号
- 保留作者归属与GPL选择条件
- 不得覆盖原App身份或自动公开仓库

**关联用例**：BAS03、BAS04、SUP01、SUP02、REL01。

**停止条件**：未接受GPL分发条件可继续个人隔离研究；正式基座需明确决定，不能暗换许可证。

## R01 原基座绿色构建与继承能力清单

阶段：P0；状态：DONE；依赖：R00；角色：实施代理。

**范围**：先运行原有测试并构建；列出保留/禁用AI、同步、Telnet/Mosh/系统管理入口；不批量升级或重写UI。

**落点**：pubspec.yaml/pubspec.lock；Android应用标识与构建配置；现有app启动及feature入口。

**交付物**：evidence/R01.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 原xterm2路径可复现或有具体失败记录
- 新app身份与原安装隔离
- 非授权AI/同步初始化不可触发

**关联用例**：BAS01、BAS02、BAS03、REL01。

**停止条件**：原基座构建失败先修最小原因，不用删测试或大量重构换取通过。

## R02 隔离网络、SSH、目录与VT支架

阶段：P0；状态：DONE；依赖：R00；角色：实施代理。

**范围**：建立受控SOCKS/多跳OpenSSH/假目录API及原始VT素材；记录目标直连、解析、auth和副作用计数。

**落点**：test/fixtures/；integration_test/；tool/fixture-environment/。

**交付物**：evidence/R02.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 测试使用临时凭据和限定监听地址
- 具备仅代理可解析目标和可直连陷阱目标
- 不接用户生产主机或真实额度

**关联用例**：NET01、NET02、NET03、TER01、TSC01。

**停止条件**：缺真实设备不影响纯Dart测试，真机用例保持NOT_RUN。

## R03 先修危险默认与字节/重连最小回归

阶段：P0；状态：DONE；依赖：R01, R02；角色：实施代理。

**范围**：固定SHA复验A01/A03/A04：无效代理失败关闭、输出增量解码、Restore/Probe不运行startup。先小补丁，不等全架构迁移。

**落点**：lib/infrastructure/ssh/ssh_service.dart；lib/application/session_controller.dart；对应回归测试。

**交付物**：evidence/R03.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 三类失败可由测试捕捉且修复
- 未实现新RoutePlan前也无无效配置直连
- 中文随机分片和startup计数正确

**关联用例**：RTE02、TER01、REG02、NET03、NET11。

**停止条件**：缺陷未复现时保留观察和差异，不编造上游问题；fail-closed未通过禁止日用。

## R04 flterm Android可行性门禁

阶段：P0；状态：BLOCKED；依赖：R01, R02；角色：终端代理。

**范围**：用固定libghostty/flterm和Android SDK做最小字节回环、IME、native打包实验；基准不是Flutter页面截图。

**落点**：独立可回收的terminal spike；pubspec依赖与native制品锁定；integration_test/terminal_spike。

**交付物**：evidence/R04.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- ARM64真机能初始化并输入中文/控制键
- 原始字节双向及16KiB验证计划可复现
- 性能与资源测量预算冻结

**关联用例**：GST01、GST03、TER01、TER02、REL03。

**停止条件**：无真机只能记部分证据；阻断引擎问题单独开ADR，不能默默以xterm完成目标。

## R05 统一RoutePlan与旧配置规范化

阶段：P1；状态：DONE；依赖：R03, X00；角色：实施代理。

**范围**：新增System/SOCKS入口+有序jump列表；旧hostChain/proxy引用转为单一路线，冻结attempt配置。

**落点**：lib/domain/models/host.dart；lib/domain/connection_route.dart（建议）；路由解析与迁移测试。

**交付物**：evidence/R05.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 缺失/冲突/循环/无效字段拨号前拒绝
- 目标和跳板身份与代理分离
- 保留未知数据且不隐式递归route

**关联用例**：RTE01、RTE02、RTE03、JMP03、BAS03、NET04。

**停止条件**：多套配置歧义先要求用户选择，不给隐藏优先级。

## R06 SOCKS5 CONNECT生产加固

阶段：P1；状态：DONE；依赖：R05, R02；角色：网络代理。

**范围**：从现有实现提取有期限、可取消、认证策略明确的代理dial；允许本地和远程代理，严格分离目标DNS。

**落点**：lib/infrastructure/transport/（建议）；原_SocketCursor/_ProxySshSocket；ProxyProfile编辑与secret引用。

**交付物**：evidence/R06.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 各认证/地址/分片/粘包正确
- 要求认证无降级
- 失败无Direct、无本地目标解析
- 外部隧道不被App启动停止

**关联用例**：NET01、NET02、NET03、NET04、NET05、NET06、NET07、NET08、SOX01、SOX02、SOX03、SOX04、RTE02。

**停止条件**：不支持的代理协议明确拒绝；不能关host key或改直连来排错。

## R07 ProxyJump与显式SOCKS入口组合

阶段：P1；状态：DONE；依赖：R05, R02；角色：网络代理。

**范围**：复用dartssh2 forwardLocal串联，最大3跳初始范围，每跳独立trust与auth；入口只开一次明确物理dial。

**落点**：lib/infrastructure/ssh/ssh_service.dart；RouteExecutor（建议）；jump fixtures。

**交付物**：evidence/R07.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 1/2/3跳及高级组合实测
- 错误定位对应hop
- 不依赖remote ssh命令或agent forwarding
- 非法链未发起连接

**关联用例**：JMP01、JMP02、JMP03、JMP04、SEC01、SEC02、SEC03。

**停止条件**：所锁dartssh2 API不匹配先小型适配/补丁；不得猜造SDK方法。

## R08 连接代次、取消和资源所有权

阶段：P1；状态：DONE；依赖：R06, R07；角色：实施代理。

**范围**：串行化阶段事件，统一attempt cancellation；无全局jump池；关闭所有部分构建资源且不停止外部SOCKS。

**落点**：lib/application/session_controller.dart；ConnectionCoordinator/Lease（建议）；SSH client/channel cleanup。

**交付物**：evidence/R08.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 迟到结果不能复活旧连接
- 各stage取消有界
- routeSnapshot稳定
- 资源释放幂等

**关联用例**：NET07、NET09、NET10、LIFE06、SOX03、RTE03。

**停止条件**：取消标UI完成但socket仍活跃不算验收通过。

## R09 每跳主机信任、凭据与所有SSH入口统一

阶段：P1；状态：DONE；依赖：R08, R01；角色：安全代理。

**范围**：将连接测试/SFTP/监控/转发纳入route；完善普通SSH认证回调与Vault lease、错误脱敏。

**落点**：host trust UI/store；lib/infrastructure/ssh各消费者；lib/infrastructure/storage/vault_repository.dart。

**交付物**：evidence/R09.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 最终trust身份不被代理地址污染
- keyboard-interactive不自动对所有问题填密码
- 所有新连接走同一resolver
- 秘密不进普通日志

**关联用例**：SEC01、SEC02、SEC03、SEC04、SEC05、SEC06、SEC07、RTE04、REG03、NET10。

**停止条件**：任何辅助入口发现Direct旁路均阻断G1；不能只修主终端。

## R10 连接路径编辑器与最小SSH闭环

阶段：P1；状态：DONE；依赖：R09；角色：实施代理。

**范围**：三选一普通UI+显式高级组合；保留主机/身份设计，显示路径和失败阶段；旧引擎先验证网络独立可用。

**落点**：lib/presentation/widgets/host_editor.dart；主机/代理页面；路径诊断组件。

**交付物**：evidence/R10.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- SSH端口与proxy端口不混
- 真实PTY而非本地echo
- 测试连接不执行startup
- 原VPN不被替换

**关联用例**：UX01、UX04、NET12、RTE05、SOX01、JMP01。

**停止条件**：没有真实外部代理证据不宣称与所有VPN兼容。

## R11 只读Tailscale目录授权与HTTP适配

阶段：P2；状态：NOT_STARTED；依赖：R05, R01, R02；角色：实施代理。

**范围**：支持短期设备读取token；高级用户自有scope受限OAuth可选持久化；固定官方API，不实现管理员管理功能。

**落点**：lib/infrastructure/tailscale/（建议）；独立catalog secret store；HTTP fixture tests。

**交付物**：evidence/R11.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- scope devices:core:read，不打包共享secret
- 只允许必要端点，redirect不泄密
- 以expires_in与受控401刷新
- 参数schema来自固定官方来源

**关联用例**：TSC01、TSC02、TSC09、SEC05、SEC12。

**停止条件**：无真实token授权用fixture；全权限token不得标只读；不索要管理员密码。

## R12 设备缓存、来源映射与非破坏合并

阶段：P2；状态：NOT_STARTED；依赖：R11；角色：实施代理。

**范围**：按catalogId+deviceId稳定识别；区分provider字段和用户覆写，处理未知字段/缺失设备/错误快照。

**落点**：DeviceBinding/CatalogSnapshot（建议）；catalog repository；import merge tests。

**交付物**：evidence/R12.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- API未知状态不伪造在线或SSH-ready
- 同名不同id不合并
- 地址变化不自动信任新key
- 未完成快照不会删主机

**关联用例**：TSC03、TSC04、TSC05、TSC10、BAS03。

**停止条件**：无法证明完整快照时只更新可确认记录，不推断删除。

## R13 设备选择、批量导入与路由绑定

阶段：P2；状态：NOT_STARTED；依赖：R12, R10；角色：实施代理。

**范围**：增加目录页和导入流程，应用共享代理/跳板profile与Unix用户，不改变已有手动主机。

**落点**：Tailscale目录screen/controller（建议）；主机导入与编辑；目录刷新状态。

**交付物**：evidence/R13.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 不因导入自动拨号/启动VPN
- 来源、刷新时间、路由明确
- 缺用户名需填，不默认root
- 删凭据默认不删主机

**关联用例**：TSC04、TSC06、TSC10、UX01、UX04。

**停止条件**：目录可见不等于连接可用，不用绿色状态掩盖网络失败。

## R14 显式Tailscale SSH外部认证与check

阶段：P2；状态：NOT_STARTED；依赖：R09, R11；角色：安全代理。

**范围**：核对锁定dartssh2的none/banner路径；独立外部认证配置；安全展示check链接，等待真实auth结果。

**落点**：SSH认证策略adapter；外部check UI及URL策略；受控Tailscale SSH fixture/授权真机。

**交付物**：evidence/R14.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 普通SSH默认不因100.x自动改none
- 外部模式不递交key/password
- host trust先于外部浏览器
- 源节点不是API账号
- 取消/拒绝/check超时正确

**关联用例**：TSC07、TSC08、SEC01、SEC02、SEC12。

**停止条件**：无实际check证据不得声称完整支持；普通SSH进口可继续，但G2功能清单保留缺口。

## R15 目录到三类路由的端到端验收

阶段：P2；状态：NOT_STARTED；依赖：R13, R14；角色：测试代理。

**范围**：同一目录设备经本地SOCKS/远程SOCKS/跳板选择连接，验证权限、缓存和源身份分离。

**落点**：integration_test/catalog_route_matrix；evidence/R15.md；能力支持矩阵。

**交付物**：evidence/R15.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 目录/API/路由/认证错误能区分
- API故障不破坏已存主机
- secret不穿越层
- 不用App启动第二VPN

**关联用例**：TSC01、TSC02、TSC04、TSC06、TSC07、TSC08、TSC09、TSC10、NET12。

**停止条件**：无生产授权继续fixture，实际设备部分保持NOT_RUN。

## R16 Session与xterm2解耦

阶段：P3；状态：NOT_STARTED；依赖：R04, R05, X01；角色：终端代理。

**范围**：提取最薄TerminalSessionAdapter，保持现有UI状态；字节流和输入动作标准化，避免大范围架构重写。

**落点**：ActiveTerminalSession；lib/infrastructure/terminal/（建议）；terminal_screen及pane。

**交付物**：evidence/R16.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- SSH层不依赖xterm2具体类型
- 字节不按包String转换
- UI重建不控制SSH生命周期
- legacy baseline仍可用于对比

**关联用例**：TER01、NET09、GST02、SEC09。

**停止条件**：不能只换import却保留大量xterm专用访问穿透。

## R17 flterm生产适配与native生命周期

阶段：P3；状态：NOT_STARTED；依赖：R16；角色：终端代理。

**范围**：安装双向byte callback、终端view、theme、resize、资源释放；先核对真实包API签名。

**落点**：GhosttyTerminalAdapter（建议）；flterm controller/view glue；native build pins。

**交付物**：evidence/R17.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 先接onOutput再feed，无重入
- 单controller单view
- 代次失效停止发送
- 初始化失败状态真实

**关联用例**：GST01、GST02、GST03、TER03、TER06、TER10、LIFE06。

**停止条件**：native crash不能承诺无缝catch回退；缺资源清理证据不进入默认。

## R18 中文IME与软硬键盘迁移

阶段：P3；状态：NOT_STARTED；依赖：R17；角色：终端代理。

**范围**：复用flterm输入能力并移植现有特殊键栏；单一输入所有权，修饰键、composing、commit和resize实机验收。

**落点**：terminal_special_keys.dart；TerminalView输入/focus；IME device scripts。

**交付物**：evidence/R18.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 中文不重复不丢失
- Ctrl/Alt/Esc/Tab正确
- 键盘/候选不遮挡
- 切标签不送错会话

**关联用例**：TER02、TER04、TER05、TER06、UX02。

**停止条件**：只能通过多行编辑框输入中文不算直接终端IME通过。

## R19 滚动选择、多行编辑与远端effect约束

阶段：P3；状态：NOT_STARTED；依赖：R18；角色：终端代理。

**范围**：迁移选择/scrollback/tmux鼠标语义，区分sendKey/sendText/paste；保留编辑预览并约束剪贴板/URL/图像。

**落点**：终端composer/selection；flterm effect callbacks；链接及粘贴策略。

**交付物**：evidence/R19.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 选择不误发按键或打开链接
- 多行默认不加Enter
- OSC读剪贴板禁止
- 会话切换取消旧目标发送

**关联用例**：TER07、TER08、TER09、GST04、SEC08、SEC09、SEC10、UX03。

**停止条件**：不把bracketed paste或库清洗视为阻止远端执行保证。

## R20 TUI/性能门禁与Ghostty成为默认

阶段：P3；状态：NOT_STARTED；依赖：R19, R08；角色：测试代理。

**范围**：同素材与旧引擎对比，实际PTY跑TUI；通过后清除生产xterm2路径并核对实际引擎标识。

**落点**：VT corpus/performance tests；生产依赖与feature flags；终端支持矩阵。

**交付物**：evidence/R20.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- CJK/全屏/协议回应无关键错误
- 高水位背压不丢VT
- 100轮释放无持续增长
- 完整目标构建实际用Ghostty

**关联用例**：TER01、TER02、TER03、TER10、TER11、TER12、TER13、GST05、REL03。

**停止条件**：Ghostty阻断可交中间构建但不能标替换完成；改目标需要用户决策。

## R21 已有tmux能力整理与安全恢复目标

阶段：P4；状态：NOT_STARTED；依赖：R08, R17；角色：实施代理。

**范围**：复用基座tmux面板/命令，建立只读探测、稳定目标、显式create/attach/detach；修复拼接和自动新建默认。

**落点**：tmux_manager_panel.dart；tmux command builder/controller；resume metadata。

**交付物**：evidence/R21.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 目标含host/user/socket/server代次
- 缺失不新建同名
- 查询无副作用、命令不注入
- 关标签不kill/Ctrl-C

**关联用例**：TMX01、TMX02、TMX03、TMX04、TMX05、TMX06、TMX07、TMX08、SEC11。

**停止条件**：不支持版本/自定义配置先退到普通SSH，不自动修改远端配置。

## R22 Flutter与Android连接生命周期

阶段：P4；状态：NOT_STARTED；依赖：R08, R20；角色：实施代理。

**范围**：复用平台service，处理锁屏/进程死亡/网络事件/force-stop；不盲信基座保活承诺。

**落点**：connection_platform_service.dart；Android SshKeepAliveService/MainActivity；session controller。

**交付物**：evidence/R22.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 通知/系统停止后不复活
- Foreground类型符合真实用途
- 不无条件杀仍存活流
- 新secret解锁遵守策略

**关联用例**：LIFE01、LIFE02、LIFE03、LIFE04、LIFE05、LIFE06、LIFE07、SEC07。

**停止条件**：无OEM设备仅保留已测范围；不得假媒体/永久wakelock规避限制。

## R23 恢复不重放与旧终端状态隔离

阶段：P4；状态：NOT_STARTED；依赖：R21, R22；角色：实施代理。

**范围**：把P0启动命令防重放扩展到所有恢复/管理/测试入口；草稿、旧画面、协议回应与新连接隔离。

**落点**：ConnectionPurpose/ResumeState；composer/session restore；managed actions。

**交付物**：evidence/R23.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- Restore/Probe无startup副作用
- 旧画面不代表新shell状态
- 不重发旧VT/键/粘贴
- 目标缺失请用户重选

**关联用例**：NET11、REG02、REG04、TMX04、TMX05、LIFE04、LIFE05。

**停止条件**：无法确认远端是否收到时显示未知，不实现假exactly-once。

## R24 SFTP、监控与转发无旁路回归

阶段：P4；状态：NOT_STARTED；依赖：R09, R23；角色：实施代理。

**范围**：保留上游能力，验证借用client和各入口在Direct/SOCKS/Jump矩阵下行为；限制高风险自动管理。

**落点**：sftp_service.dart；server_monitor_service.dart；port_forward_controller.dart；消费者生命周期。

**交付物**：evidence/R24.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 借用client同一目标/代次
- 关闭SSH后借用者失效
- 不自动重传有副作用请求
- 路由无旁路

**关联用例**：RTE04、REG01、SEC12、NET11。

**停止条件**：当前未审查入口可明确禁用，不留可点击的失效菜单或默走Direct。

## R25 日用UI、诊断与参考交互收敛

阶段：P4；状态：NOT_STARTED；依赖：R10, R13, R19, R21；角色：实施代理。

**范围**：整理主机/目录/route/终端设置和无障碍；参考图片的分组，而非复制所有高级功能或闭源素材。

**落点**：screens/widgets与本地文案；diagnostics；用户操作说明草稿。

**交付物**：evidence/R25.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 三种凭据/目标/代理端口明确
- 引擎和路径真实
- 功能无空壳
- 字体/主题/横屏/TalkBack可用

**关联用例**：UX01、UX02、UX03、UX04、SEC12。

**停止条件**：视觉改动不能替代网络和输入门禁；不扩大WOL/NFC/sudo功能。

## R26 用户手机VPN + TailSocks真实日用

阶段：P5；状态：NOT_STARTED；依赖：R15, R20, R23, R24, R25；角色：测试代理。

**范围**：明确授权后在用户手机验证同一候选，比较LobiShell行为基线；测试网络切换、目录、跳板、IME和SFTP。

**落点**：evidence/R26.md；device/version matrix；故障复现与问题清单。

**交付物**：evidence/R26.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 不占VPN且完整核心路径可用
- 关键负向场景实测
- 源设备身份差异说明
- 真实模型额度使用另获授权

**关联用例**：NET12、TER13、LIFE03、LIFE04、LIFE07、SOX01、JMP01、TSC06、REL04。

**停止条件**：无设备/权限标BLOCKED；用户之前LobiShell成功不可计本App通过。

## R27 Release、native与依赖制品验收

阶段：P5；状态：NOT_STARTED；依赖：R26, X10, X06, X07；角色：发布代理。

**范围**：检查Flutter AOT、native ABI/16KiB、FGS、目标SDK、release混淆与供应链；只用测试签名除非授权。 V3同时检查主App及Mosh APK的signer、IPC契约和native制品；外部App只记录可验证安装版本。

**落点**：Android build/CI；依赖锁/native manifest；release artifact evidence。

**交付物**：evidence/R27.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 同源码冷环境可重建
- native hash失败不能跳过
- 仅声明已测ABI/API
- 不自动上架或借原签名

**关联用例**：GST01、SUP01、REL01、REL02、REL03、BAS04。

**停止条件**：不能用debug运行替代release通过；发布政策实时复核。

## R28 凭据、外连与继承功能对抗审查

阶段：P5；状态：NOT_STARTED；依赖：R15, R23, R24, R25, X11；角色：独立审查代理。

**范围**：独立审查新目录凭据与上游raw model/export/AI/同步/管理路径；复现负向路由和host trust。

**落点**：Vault/exports/sync/diagnostics；route/auth code；security evidence。

**交付物**：evidence/R28.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 没有secret明文或非授权外连
- 每跳trust不能被任何入口绕过
- 输入/startup不重放
- 恶意远端输出不执行本地动作

**关联用例**：SEC01、SEC02、SEC03、SEC04、SEC05、SEC06、SEC07、SEC08、SEC09、SEC10、SEC11、SEC12、BAS02、TSC09、REG03。

**停止条件**：不能以框架secure_storage名称替代实际检查；安全硬项失败不豁免。

## R29 用户文档、迁移与许可交付

阶段：P5；状态：NOT_STARTED；依赖：R26, R27, R28, X12；角色：实施代理。

**范围**：README精简；详细route/Tailscale/引擎/隐私/恢复放docs；记录独立品牌、上游归属、支持与未测矩阵。

**落点**：README.md；docs/user/；LICENSE/NOTICE；CHANGELOG与UPSTREAM记录。

**交付物**：evidence/R29.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 不宣传双VPN/永不断线/只读全权限token
- 未测能力不写支持
- 旧Txx计划明确退役
- 分发义务检查可追溯

**关联用例**：UX04、BAS04、SUP02、REL04。

**停止条件**：截图仅使用真实候选且无秘密，不将参考App图片作为本产品实现。

## R30 同一候选全量回归与独立复现

阶段：P5；状态：NOT_STARTED；依赖：R27, R28, R29, X13；角色：独立审查代理。

**范围**：重跑本包全部硬用例及保留功能的上游回归；安全和设备证据都绑定同SHA/APK。

**落点**：verification-cases.json结果副本；evidence/R30.md；independent review。

**交付物**：evidence/R30.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 全部用例有真实证据
- 无跳过测试伪绿
- 同候选完成网络/目录/Ghostty/平台
- 已知缺陷与未测如实记录

**关联用例**：verification-cases.json全部142项。

**停止条件**：任何必需NOT_RUN或FAIL不标完整READY；不能借另一版本或基座结果补齐。

## R31 最终状态、交接与可交付范围

阶段：P5；状态：NOT_STARTED；依赖：R30；角色：架构代理。

**范围**：核对G0–G5、最终引擎、上游来源、用户授权和产物；区分本地候选READY与公开发布。 完整范围包含X00–X13；不能仅用V2核心完成结论标V3 READY。

**落点**：STATUS.md；tasks.json；发布候选manifest与交接。

**交付物**：evidence/R31.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 实现完成不等于已发布
- 完整目标是Ghostty而非只剩fallback
- 下一阶段另行授权
- 不自动push/上架

**关联用例**：REL04、REL05、SUP02、GST05。

**停止条件**：只放行有证据的范围；未完成部分具体列出，不靠一句大致完成。

## R32 内置用户态Tailscale transport

阶段：P6；状态：DEFERRED；依赖：R31；角色：实施代理。

**范围**：只有外部TailSocks摩擦经日用证明才评估tsnet、节点身份、Android生命周期和升级；目录接口保持独立。

**落点**：后续独立ADR与任务。

**交付物**：evidence/R32.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 新增范围须授权
- 补充专用安全/测试矩阵
- 本阶段不自动启动

**关联用例**：后续范围启动时新增专门用例，不使用既有PASS代替。

**停止条件**：不读取外部App私有身份，不加VpnService，不影响已有SOCKS。

## R33 托管动态SOCKS与跳板连接池

阶段：P6；状态：DEFERRED；依赖：R31；角色：实施代理。

**范围**：用户明确需要时再增加App管理ssh -D或跨会话jump池，单独设计owner/refcount/credential generation与停止。

**落点**：后续独立ADR与任务。

**交付物**：evidence/R33.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 新增范围须授权
- 补充专用安全/测试矩阵
- 本阶段不自动启动

**关联用例**：后续范围启动时新增专门用例，不使用既有PASS代替。

**停止条件**：不把当前消费外部SOCKS偷换成管理隧道；不得共享不同安全身份。

## R34 Mosh经代理UDP与高级datagram路线

阶段：P6；状态：DEFERRED；依赖：R31, X10；角色：实施代理。

**范围**：Mosh基础插件在X08–X10完成；此任务仅扩展SOCKS UDP ASSOCIATE、datagram provider或明确的UDP网关能力，不从TCP CONNECT推导支持。

**落点**：后续独立ADR与任务。

**交付物**：evidence/R34.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 实际UDP路线、DNS、认证、移动恢复和失败无直连证据齐全
- 没有合法UDP通道时保留unsupported
- 复核native适配与许可而非重写Mosh协议

**关联用例**：后续范围启动时新增专门用例，不使用既有PASS代替。

**停止条件**：没有真实UDP路由支持就不启用；不把SSH+SOCKS引导成功当Mosh已支持。

## R35 iOS及其他平台发布

阶段：P6；状态：DEFERRED；依赖：R31；角色：实施代理。

**范围**：在Android日用后，利用Flutter共享目录/route/终端合同，逐平台做后台/native/Keystore等差异验收。

**落点**：后续独立ADR与任务。

**交付物**：evidence/R35.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 新增范围须授权
- 补充专用安全/测试矩阵
- 本阶段不自动启动

**关联用例**：后续范围启动时新增专门用例，不使用既有PASS代替。

**停止条件**：有Flutter代码不等于iOS生产支持，不改Android安全合同。

## R36 高级硬件密钥、agent forwarding与同步

阶段：P6；状态：DEFERRED；依赖：R31；角色：实施代理。

**范围**：按真实用户需求单独评估硬件签名、授权转发与跨设备加密备份；继续不默认同步管理token。

**落点**：后续独立ADR与任务。

**交付物**：evidence/R36.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 新增范围须授权
- 补充专用安全/测试矩阵
- 本阶段不自动启动

**关联用例**：后续范围启动时新增专门用例，不使用既有PASS代替。

**停止条件**：不把外部签名权限长期自动授给所有远端，不忽略GPL分发条件。

## R37 Wake、NFC、Port Knocking及其他高级交互

阶段：P6；状态：DEFERRED；依赖：R31；角色：实施代理。

**范围**：用户截图仅作为后续参考，先说明网络范围、授权动作、标签数据与webhook秘密风险。 附件路径插入若保留上游已有能力仅回归；新增附件/OCR/云处理不属于本次核心。

**落点**：后续独立ADR与任务。

**交付物**：evidence/R37.md（实际执行后填写）；与范围对应的实现、测试及文档；不能只交截图或接口空壳。

**验收**：
- 新增范围须授权
- 补充专用安全/测试矩阵
- 本阶段不自动启动

**关联用例**：后续范围启动时新增专门用例，不使用既有PASS代替。

**停止条件**：不以静态NFC tag暗存secret或无需确认执行生产命令。

## X00 插件能力、信任和SDK v1契约

阶段：E0；状态：DONE；依赖：R00；角色：架构/安全代理。

**范围**：冻结bundled/android-service/external-app边界，独立签名授权、三类会话、route capability及协议来源。

**落点**：docs/15-plugin-architecture.md；contracts/；packages/plugin_api（初始类型）。

**交付物**：evidence/X00.md（实际执行后填写）；对应实现、测试、版本及文档，不以接口空壳或参考App成功代替。

**验收**：
- 描述符不授予任意exec/文件/Vault
- 同签名与独立签名策略不矛盾
- 记录Mosh与UU协议局限和真正未测事项

**关联用例**：PLG01、PLG02、PLG14、SDK02、SDK03、DEV01。

**停止条件**：不扩大成插件商城或任意Dart VM；不把独立APK当许可豁免。

## X01 轻量registry与设备/会话分型

阶段：E0；状态：DONE；依赖：X00, R05；角色：实施代理。

**范围**：用现有Riverpod装配内置能力；统一设备引用，区分Terminal/RemoteDesktop/ExternalLaunch，保留旧入口可回归。

**落点**：domain/plugins；application/plugin_registry；domain/device_references；session model。

**交付物**：evidence/X01.md（实际执行后填写）；对应实现、测试、版本及文档，不以接口空壳或参考App成功代替。

**验收**：
- 不按名字/IP自动合并设备
- 没有所有能力共用connected布尔值
- 核心SSH不依赖外部插件存在

**关联用例**：PLG01、PLG02、DEV01、DEV02、RTE01。

**停止条件**：不一次拆几十个package；保留已验证功能路径。

## X02 Android独立插件发现、桥接与双向签名

阶段：E0；状态：NOT_STARTED；依赖：X00, R01, R02；角色：Android/安全代理。

**范围**：建立最小Kotlin桥及独立测试APK；显式组件、queries与每方法UID/证书鉴别，实际安装版本记录。

**落点**：AndroidProviderBridge；plugins/fixture-echo；provider AIDL SDK。

**交付物**：evidence/X02.md（实际执行后填写）；对应实现、测试、版本及文档，不以接口空壳或参考App成功代替。

**验收**：
- 独立作者签名能在用户批准后接入
- 拒绝伪装包/未授权caller
- 不是只改onBind或信任Intent字符串

**关联用例**：PLG03、PLG04、PLG05、PLG15。

**停止条件**：无Android安装证据保留NOT_RUN；echo不得标Mosh完成。

## X03 FD流、版本协商与插件故障基础

阶段：E0；状态：NOT_STARTED；依赖：X02；角色：实施代理。

**范围**：实现typed session control、FD数据、generation、背压和death/revoke行为，在独立fixture APK故障注入。

**落点**：plugin_api Android IPC；AndroidProviderBridge stream adapter；plugins/fixture-echo。

**交付物**：evidence/X03.md（实际执行后填写）；对应实现、测试、版本及文档，不以接口空壳或参考App成功代替。

**验收**：
- 控制事件不阻塞UI/Binder线程
- 字节流保序和有界
- 无响应close显示未确认不假停止

**关联用例**：PLG02、PLG06、PLG07、PLG08、PLG09、PLG10、PLG12。

**停止条件**：不使用大型Base64/Binder帧冒充高吞吐管道。

## X04 插件管理、安装检测与用户授权UI

阶段：E1；状态：NOT_STARTED；依赖：X01, X03, R10；角色：实施代理。

**范围**：展示来源/签名/版本/能力/路由支持，启停、撤销、更新/卸载检测和设置入口；安装由用户操作。

**落点**：presentation/plugins；plugin trust store；Android package events。

**交付物**：evidence/X04.md（实际执行后填写）；对应实现、测试、版本及文档，不以接口空壳或参考App成功代替。

**验收**：
- 初次未授权不自动启用
- 签名/major变化阻断
- 卸载插件不破坏其他设备能力

**关联用例**：PLG03、PLG04、PLG11、PLG12、PLG15、SDK04、DEV02。

**停止条件**：不得申请全包扫描或自动下载执行代码。

## X05 Tailscale目录接入内置provider

阶段：E1；状态：NOT_STARTED；依赖：X01, R13；角色：实施代理。

**范围**：包装R11–R13既有目录实现，不重写HTTP；source IDs与设备关联/权限存储一致。

**落点**：infrastructure/plugins/tailscale_catalog；device capability actions。

**交付物**：evidence/X05.md（实际执行后填写）；对应实现、测试、版本及文档，不以接口空壳或参考App成功代替。

**验收**：
- provider只访问本来源控制面凭据
- 目录下线不删SSH用户覆写
- 发现不等于网络或SSH认证

**关联用例**：TSC01、TSC02、TSC04、DEV01、DEV02、PLG14。

**停止条件**：不为简单目录功能生成额外APK。

## X06 UU官方绑定、全屏与PiP适配

阶段：E1；状态：NOT_STARTED；依赖：X04；角色：实施代理。

**范围**：实现已验证包/scheme的绑定回调、opaque ID、安全关联、全屏launch和PiP结果，不读取UU账号秘密。

**落点**：infrastructure/plugins/uuremote_adapter；external callback validator；device bindings UI。

**交付物**：evidence/X06.md（实际执行后填写）；对应实现、测试、版本及文档，不以接口空壳或参考App成功代替。

**验收**：
- 冻结实际4.42.0+协议/安装版本；目标Windows/macOS
- 全屏无回调不标Active
- nonce/state一次性且回调后不自动远控

**关联用例**：UUR01、UUR02、UUR03、UUR04、UUR05、UUR06、UUR07、UUR08、DEV01、DEV02。

**停止条件**：无UU账号/目标授权用mock不填真实PASS；Linux明确不支持。

## X07 RustDesk外部客户端联动

阶段：E1；状态：NOT_STARTED；依赖：X04；角色：实施代理。

**范围**：实现peer绑定和显式连接URI、签名/包检测、外部状态边界，保留自建服务由RustDesk配置。

**落点**：infrastructure/plugins/rustdesk_external；remote action UI。

**交付物**：evidence/X07.md（实际执行后填写）；对应实现、测试、版本及文档，不以接口空壳或参考App成功代替。

**验收**：
- 不在URL发密码或修改服务器配置
- 只有launch证据不能标远控已连
- 不继承并伪称SSH SOCKS有效

**关联用例**：RDX01、RDX02、RDX03、RDX04、RDX05、DEV01。

**停止条件**：嵌入客户端核心或画面属于R38，不顺手扩张。

## X08 Mosh运行时选择与独立APK可行性

阶段：E2；状态：NOT_STARTED；依赖：X03, R04, R09；角色：Native/Android代理。

**范围**：先对比dart_mosh与官方native客户端的真实mosh-server互操作、包/密钥处理、VT重绘、移动恢复与独立APK成本，再冻结一种运行时。Dart候选用插件自身AOT/FlutterEngine与Kotlin bridge；native候选验证PTY/JNI/退出。不是只引pub包，也不复制binary到宿主files执行。

**落点**：plugins/mosh；runtime-selection ADR与可重建构建脚本；Mosh runtime/ABI/license ledger。

**交付物**：evidence/X08.md（实际执行后填写）；对应实现、测试、版本及文档，不以接口空壳或参考App成功代替。

**验收**：
- 真实运行时通过独立APK运行，至少arm64证据；记录Dart与native候选选择理由
- 与官方mosh-server互操作，重传/重放边界、坏包及key处理有证据；只固定一套生产实现
- 退出、信号或isolate/engine生命周期不拖垮宿主；记录所有传递native ABI/16KiB与来源

**关联用例**：MOS01、MOS08、PLG13、SDK02、REL03。

**停止条件**：候选都未通过则保持阻塞；不能用echo或仅宿主内pub依赖替代独立插件，不规避Android执行限制。

## X09 Mosh受控bootstrap与终端session接入

阶段：E2；状态：NOT_STARTED；依赖：X08, R17, R08；角色：实施代理。

**范围**：宿主SSH核验与受控mosh-server启动，临时key通过IPC，VT接flterm，Direct route capability前置检查。

**落点**：MoshBootstrapCoordinator；MoshTerminalProvider；plugins/mosh session implementation。

**交付物**：evidence/X09.md（实际执行后填写）；对应实现、测试、版本及文档，不以接口空壳或参考App成功代替。

**验收**：
- SOCKS/Jump在bootstrap前拒绝
- 不把SSH/代理/Tailscale秘密交插件
- 输入和resize只走单一所有者

**关联用例**：MOS01、MOS02、MOS03、MOS04、MOS05、PLG14、NET11。

**停止条件**：不自动安装远端mosh-server，不直连绕过用户选定代理。

## X10 Mosh移动恢复与运行时生命周期验收

阶段：E2；状态：NOT_STARTED；依赖：X09, R22；角色：实施代理。

**范围**：实测Wi-Fi/蜂窝/后台、断流、native退出、stop和跨App资源；建立诚实支持矩阵。

**落点**：Mosh runtime lifecycle；device test matrix；provider release fixture。

**交付物**：evidence/X10.md（实际执行后填写）；对应实现、测试、版本及文档，不以接口空壳或参考App成功代替。

**验收**：
- 不因网络事件重复bootstrap或输入
- stop和崩溃不影响已有SSH
- 用户当前TailSocks路径继续SSH+tmux

**关联用例**：MOS01、MOS02、MOS03、MOS04、MOS05、MOS06、MOS07、MOS08、PLG09、PLG10、PLG13、PLG16、LIFE06。

**停止条件**：没有可达UDP的授权目标或真机则BLOCKED，不改用生产主机试验。

## X11 插件信任、撤销、外部调用对抗回归

阶段：E3；状态：NOT_STARTED；依赖：X04, X05, X06, X07, X10, R23；角色：独立安全代理。

**范围**：独立复现伪造provider、跨UID、签名升级、挂死关闭、callback重放、权限/秘密和外部路由边界。

**落点**：integration_test/plugins；evidence/plugin-security-review。

**交付物**：evidence/X11.md（实际执行后填写）；对应实现、测试、版本及文档，不以接口空壳或参考App成功代替。

**验收**：
- 任何敏感操作都有实际边界证据
- 不将第三方APK当可强制网络沙箱
- 缺证据不能risk-accept安全失败

**关联用例**：PLG01、PLG02、PLG03、PLG04、PLG05、PLG06、PLG07、PLG08、PLG09、PLG10、PLG11、PLG12、PLG13、PLG14、PLG15、PLG16、UUR06、UUR08、RDX02、RDX04、DEV02。

**停止条件**：发布硬阻断，审查者不能仅照实施总结填通过。

## X12 插件作者SDK、样例和维护文档

阶段：E3；状态：NOT_STARTED；依赖：X03, X06, X07, X09；角色：实施代理。

**范围**：完成可独立构建的样例、契约/错误/兼容文档、签名说明、升级和诊断；由未参与作者流程复验。

**落点**：packages/plugin_api；plugins/example；docs/plugin-authors。

**交付物**：evidence/X12.md（实际执行后填写）；对应实现、测试、版本及文档，不以接口空壳或参考App成功代替。

**验收**：
- 不要求私有源码或签名私钥
- 区分样例、Mosh真实现和外部adapter
- 文档说明Android范围和源码许可

**关联用例**：SDK01、SDK02、SDK03、SDK04、PLG02、PLG15。

**停止条件**：只写接口无样例安装/通信证据不能DONE。

## X13 主App与插件组合候选验收

阶段：E3；状态：NOT_STARTED；依赖：X11, X12, R26, R27；角色：人工/独立验收。

**范围**：同一候选安装主App/Mosh及实测UU/RustDesk版本，完整走SSH/Ghostty/Tailscale/Jump/SOCKS与插件兼容。

**落点**：evidence/X13-composed-dogfood；release matrix；STATUS.md。

**交付物**：evidence/X13.md（实际执行后填写）；对应实现、测试、版本及文档，不以接口空壳或参考App成功代替。

**验收**：
- core-ready与完整含插件范围分开
- UU及Mosh未授权测试不伪填
- 所有APK hash/signer与观察结果关联

**关联用例**：NET12、GST05、MOS01、MOS04、UUR03、UUR04、RDX01、PLG09、PLG12、PLG16、REL04、REL05。

**停止条件**：缺任何主线必需真机证据，完整V3保持BLOCKED；可明确交付已验证子集。

## R38 RustDesk独立APK内嵌画面provider

阶段：P6；状态：DEFERRED；依赖：R31；角色：Native/远控代理。

**范围**：按docs/17评估AIDL+Surface/PlatformView和RustDesk native核心；通过许可、输入、渲染、媒体与IPC单独门禁后扩展。

**落点**：plugins/rustdesk；RemoteDesktopSurfaceAdapter。

**交付物**：单会话真实画面/输入PoC；完整源码/许可证及native再构建记录；新增测试与显式授权。

**验收**：
- 不传每帧Base64过Dart/Binder
- AGPL及组合关系审查完成
- 密码/剪贴板/媒体独立授权，外部基础模式仍可用

**关联用例**：后续范围启动时新增专门用例，不使用既有PASS代替。

**停止条件**：没有许可/ABI/画面证据不合入主线；不直接伪装LobiShell宿主身份。
