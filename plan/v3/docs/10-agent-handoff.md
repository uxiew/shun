# 10 V3模型交接

## 开始前

读取AGENTS、STATUS、docs/00/01/03/04/05/06/07/15/19及tasks.json。旧Txx是退役计划，V2草稿不再作为门禁。目标repo未指定时不写入历史powell/xdo等仓库；此包可放入指定新fork，已有AGENTS/README先合并不覆盖。

## 当前入口：UI迁移 R82（2026-11-06）

R81已完成当前界面、唯一参考、覆盖表与profile基线，实际范围和限制见[evidence/R81](../evidence/R81.md)。UIM01 PASS；GU0仍为NOT_RUN，必须完成R82后按真实证据判定。继续采用FlClash / prism_ui单一目标，读[docs/24](24-ui-migration.md)与[UI决策](../../../docs/decisions/ui-system-decision.md)。

```text
在shun当前分支按V3计划执行UI迁移，本批只做R82。
先读根AGENTS、plan/v3/AGENTS、STATUS及规定的契约文档，再读docs/24、
docs/decisions/ui-system-decision.md、tasks.json的R82条目和evidence/R81.md。
记录实际HEAD/dirty/SDK/lock，不覆盖其他人的改动。
锁定prism_ui 63450c0ac0e8e1b2c0f3ed4ad7926dc94e083185，
只做依赖解析所需最小变更；不连带升级Riverpod、dartssh2、libghostty或存储。
实现一个薄ShunUiHost和一个WidgetsApp/Navigator，保留原_navigatorKey、
HomeShell及初始化/生命周期；显式提供pageRouteBuilder。
HomeShell/live终端route不用CardRouteMixin；
不要把allowSnapshotting:false当作Prism私有快照已关闭。
Material Theme放在GhosttyDetachedThemeSync外；按真实消费者保留ScaffoldMessenger、
Material/Widgets/Cupertino delegates，接通当前LText/localized的Prism文案代理。
AppLockGate包住BannerHost、Overlay、路由和全部视觉层；
RemoteFocusAdapter(enabled:false)，不安装ThemeCrossFade，不靠换key重建会话树。
用持续输出的终端验证push/pop时view身份、输出和输入焦点连续；
验证锁罩覆盖视觉/语义/输入，以及能实际点击背景的真非模态最小样例。
本批只接入最小宿主，不批量迁移页面，不操作正式签名或用户手机。
完成UIM02/UIM03关联检查、测试及隔离Android debug构建，记录GPL与NOTICE。
按真实结果写evidence/R82.md、同步任务/用例/GU0证据，作粒度提交；
运行sync_docs.py和validate_plan.py。报告完成ID、commit、未测及下一任务R83。
任何锁罩、根导航、终端焦点或非模态契约失败，先修同一目标内的薄适配。
```

继续时只把任务ID替换为当前依赖满足的一项，重新读取它的scope/code_targets/acceptance/test_ids/stop_condition，不复用R82的实施内容。U3可按docs/24文件边界并行，终端R93–R95必须串行。每次交接说明改动、受保护行为、真实验证、缺口与下一项。

R98先交代码/本地验证，R26再验新候选真机；R98不能反向等待R26。GU5不是FULL_READY。历史PASS保留原候选来源，UIM22和真实账号/硬件缺口不靠截图、mock或规划检查补齐。

## 历史首批提示词（R00–R04/X00，不是当前入口）

```text
按Flutter移动终端V3二开计划实施，本批只做R00–R04与X00。
默认以Netcatty-mobile为基座，保留作者版权/GPL；不接受其分发条件时先记录Conduit替代ADR，
不搬运GPL代码后改贴Apache。读取当前HEAD/dirty/lock，先跑原基座测试和构建。
建立SOCKS/SSH/VT/目录fixture；修代理失效转直连、按块UTF8解码、恢复startup重放等可复验风险。
验证elias8/libghostty + flterm的Android可行性与输入，不从零写Compose/SSHJ/WebView。
完成插件能力/签名/路由/会话分型契约。外置APK采用受控IPC，非动态下载Dart/.so。
本批不一次实现全部UI或插件，不操作生产VPN/主机/密钥/账号/模型额度，不自动push/发布。
有设备才记录真机证据；无设备完成独立测试并保留NOT_RUN/BLOCKED。
同步tasks、verification、STATUS和evidence，粒度commit，结束给出门禁与下一批依赖。
```

## 插件实施入口

第二批按依赖做X01–X03（registry、独立fixture APK、签名与FD），同步R05–R10路线。
X06 UU以本次raw协议为基准，先复核已安装版本：全屏不回调，小窗才可能回调；nonce不等于签名认证。
X07 RustDesk先外部启动，不传密码URL，不擅自复制native核心。
X08–X10 Mosh必须真实runtime；不支持SOCKS CONNECT/ProxyJump的UDP，启动前拒绝，不偷直连。

## 继续提示词

```text
读取V3 STATUS、tasks.json、实际git diff及上一批evidence，只领依赖满足的最小批次。
维持单一RoutePlan、每跳host key、无代理回退、无用户输入/startup重放；Ghostty原始字节与单view所有权。
插件逐事务核验UID+签名+授权+session代次，秘密最小授予；死亡/升级/撤销不伤及其他连接。
UU/RustDesk外部启动不代表连接成功，也不继承SSH代理；Mosh缺UDP路由明确拒绝。
运行本任务test_ids并记录真实结果，mock和reference App不替代设备证据。
完整V3要X00–X13，R30全量用例；只通过核心不得标FULL_READY。
```

## 独立审查重点

读源码而非仅实施摘要，复现：无效SOCKS无直连、每跳指纹改变、旧startup不重放、跨包UTF8；再复现未授权Binder caller、换签插件、跨session handle、插件crash不影响SSH、撤销挂死、UU callback重放/全屏误判、RustDesk密码URI拒绝、Mosh proxy route在bootstrap前拒绝。核对同候选APK哈希、签名、依赖、FGS/native/16KiB与许可证来源。

每批只报完成ID与证据、具体阻塞、下一项依赖；不重复整套规划。项目名称、applicationId、分发、正式签名及公开发布仍须所有者确认。
