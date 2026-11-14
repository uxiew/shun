# 10 V3模型交接

## 开始前

读取AGENTS、STATUS、docs/00/01/03/04/05/06/07/15/19及tasks.json。旧Txx是退役计划，V2草稿不再作为门禁。目标repo未指定时不写入历史powell/xdo等仓库；此包可放入指定新fork，已有AGENTS/README先合并不覆盖。

## 当前入口：UI迁移 R88（2026-11-14）

R81–R87已完成，UIM01–UIM08及GU0、GU1 PASS；实际范围见[evidence/R81](../evidence/R81.md)–[evidence/R87](../evidence/R87.md)。R87把连接首页、Tailscale分节和目录两页换成Prism分组卡片，`ShunListRow` 加了长按、念左侧图标、展开状态三个可选项；单独装页面的测试统一用 `test/support/prism_test_host.dart` 补Prism宿主。继续采用FlClash / prism_ui单一目标，读[docs/24](24-ui-migration.md)与[UI决策](../../../docs/decisions/ui-system-decision.md)。

### Claude Code 首次接手

本机代码仓库是 `/Users/bing/xdw/shun/shun`，上一层是工具链工作区；在代码仓库内开始。最近已核验分支为 `shun/v3`，R87实现提交见tasks.json的R87.commit，验收与本交接在其后提交。这些是历史核验锚点，后续文档提交会使HEAD前进，不要求回退。

先读取现场分支、HEAD、dirty以及适用的CLAUDE.md（若存在）；显式读取根AGENTS.md和plan/v3/AGENTS.md，不依赖宿主自动加载。保留他人改动，不为对齐交接执行reset、强制checkout或清理工作区。若R88已有进展，按tasks.json和实际diff续接，不重复实现。

环境按 `docs/dev/README.md`：当前已核验Flutter 3.47.7、Dart 3.13.5、Zig 0.16.0；重新核对实际版本并设置项目Zig、环境脚本及NO_PROXY。**静态检查用 `flutter analyze --no-pub`**（不加时会按全局镜像改写pubspec.lock，见R84第7节）。整文件 `dart format` 前，先在项目目录里对HEAD版本跑 `dart format --output=none --set-exit-if-changed`，没有变化才整文件格式化；放到项目外检查会换语言版本、误判（R86第7节；`ui_gallery_test.dart` 等在HEAD上就不合格式，见R87第6节）。**全量单测用手册命令 `flutter test -j 4 --exclude-tags ai-cli-ssh-fixture`**，不排除会多出64个AI夹具跳过，数字和前几批对不上（R87第5节）。debug构建加 `--target-platform android-arm64` 才能和R82归档条目对照。R81–R87归档在 `../.toolchain/artifacts/` 下各自目录。Flutter测试、截图与构建串行运行。

下面是本轮执行提示词；任务定义只维护在tasks.json，结果只按实际验证填写。

```text
在 /Users/bing/xdw/shun/shun 接手shun，按V3计划直接完成R88的实现、验证、证据和本地提交。
先读根AGENTS、plan/v3/AGENTS、STATUS及规定的契约文档，再读docs/24、
docs/decisions/ui-system-decision.md、tasks.json的R88条目、evidence/R86、R87和docs/23「新建主机学了什么（F42）」。
记录实际分支/HEAD/dirty/SDK/lock，核对R87证据仍对应当前代码；保留他人改动。
Prism固定63450c0ac0e8e1b2c0f3ed4ad7926dc94e083185，不重选库、不升级业务依赖；
静态检查用flutter analyze --no-pub，pubspec.lock有任何变动先还原再继续。
先清点主机表单：新建/编辑、SSH/Mosh/Telnet/插件/RustDesk/UU类型、密码/密钥/凭据/Tailscale认证、
分组选择与新建、高级（路线/Mosh参数/启动命令/超时/标签置顶/目录来源）、底部栏验证状态、测试连接页，
迁移前后各导出一次读屏节点和key逐项对照（做法见R86第2.1节、R87第2.1节）。
按F42流程迁移主机编辑器、类型行、分组字段、路线编辑、凭据字段和测试连接页；业务仍调原控制器。
控件用ui/components.dart（ShunSection、ShunListRow、ShunSwitchRow、ShunOptionsRow、ShunSectionItem、
ShunButton、ShunSecretField）和ChoiceSegments；普通输入框保持Material浮动标签与FormGap 20dp（R84第2节）。
Prism卡片本身是按钮语义节点，名字要并进它，别再套自己的语义节点；共享控件缺陷回到基础层修。
⊕直接进表单；类型、认证原地换且已填内容保留；名称下方选择或新建分组；高级只有一层；
旧主机字段和自定义端口不丢；Mosh带代理/跳板仍拒绝保存；未保存退出确认、下滑不关保持；
测试连接只由用户点、可停止、不自动保存、不连生产主机、记录脱敏；不改RoutePlan与存储。
编辑器的打开/保存/删除回调接口不变（R87没动vault_screen里的这些）；「目录来源」小节R87已换成ShunSection，
迁表单时核对它在表单里的间距。不恢复管理页，不强迫先建凭据。
新文字和输入框受R84扫描器约束（R87起 details 也按副标题16字查），不放宽上限、不加白名单；
类型断言改稳定key/语义/行为。单独装页面的测试用test/support/prism_test_host.dart补Prism宿主。
运行UIM09及受影响的编辑器、类型、路线、凭据、测试连接、规则与秘密输入回归和静态检查；
图库补表单各分支、键盘弹出、大字号浅深截图并逐张看；r73/r41设备测试若定位方式受影响只改稳定key。
本批仅做R88；R89凭据/代理/Tailscale留给下一批。不操作正式签名、用户手机或push/发布。
写evidence/R88.md并同步使用手册中实际变化、任务/用例及状态，作粒度提交；
使用plan/v3/scripts/set_status.py登记实际结果，再运行sync_docs.py和validate_plan.py。
R88/UIM09满足验收后才完成；GU2还依赖R89，不因本批通过而标PASS。
完成本批后停止，报告完成ID、commit、验证数量/skip、截图位置、未测及下一任务R89。
认证语义改变、字段丢失、类型被删或首屏/可访问性要求降低即停，不以截图好看代替契约。
```

继续时重新读取下一项的scope/code_targets/acceptance/test_ids/stop_condition，不只替换提示词任务ID。U3可按docs/24文件边界并行，终端R93–R95必须串行。每次交接说明改动、受保护行为、真实验证、缺口与下一项。

R81的raster耗时及VT/总览后Native/PSS未完全回落仍交R95/R97定位；R82/R83单元测试和debug构建不证明新UI更流畅。R83留下的按钮字黑白取舍归R96，见evidence/R83第2.5节。Prism Measure只接受线性比例，宿主保留原MediaQuery TextScaler，Android 14+真实非线性字号另归UIM22。

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

## 历史插件实施入口（不作为当前任务）

第二批按依赖做X01–X03（registry、独立fixture APK、签名与FD），同步R05–R10路线。
X06 UU以本次raw协议为基准，先复核已安装版本：全屏不回调，小窗才可能回调；nonce不等于签名认证。
X07 RustDesk先外部启动，不传密码URL，不擅自复制native核心。
X08–X10 Mosh必须真实runtime；不支持SOCKS CONNECT/ProxyJump的UDP，启动前拒绝，不偷直连。

## 通用续接提示词（当前任务以STATUS为准）

```text
读取V3 STATUS、tasks.json、实际git diff及上一批evidence，只领依赖满足的最小批次。
维持单一RoutePlan、每跳host key、无代理回退、无用户输入/startup重放；Ghostty原始字节与单view所有权。
插件逐事务核验UID+签名+授权+session代次，秘密最小授予；死亡/升级/撤销不伤及其他连接。
UU/RustDesk外部启动不代表连接成功，也不继承SSH代理；Mosh缺UDP路由明确拒绝。
运行本任务test_ids并记录真实结果，mock和reference App不替代设备证据。
完整V3要X00–X13，R30全量用例；只通过核心不得标FULL_READY。
```

## 独立审查重点

以下是全V3审查索引，按当前任务的影响范围选取；不因交接自动重跑全部项。

读源码而非仅实施摘要，复现：无效SOCKS无直连、每跳指纹改变、旧startup不重放、跨包UTF8；再复现未授权Binder caller、换签插件、跨session handle、插件crash不影响SSH、撤销挂死、UU callback重放/全屏误判、RustDesk密码URI拒绝、Mosh proxy route在bootstrap前拒绝。核对同候选APK哈希、签名、依赖、FGS/native/16KiB与许可证来源。

每批只报完成ID与证据、具体阻塞、下一项依赖；不重复整套规划。项目名称和applicationId沿用根AGENTS的既定值；分发、正式签名和公开发布按当次有效授权执行。
