# 10 V3模型交接

## 开始前

读取AGENTS、STATUS、docs/00/01/03/04/05/06/07/15/19及tasks.json。旧Txx是退役计划，V2草稿不再作为门禁。目标repo未指定时不写入历史powell/xdo等仓库；此包可放入指定新fork，已有AGENTS/README先合并不覆盖。

## 当前入口：UI迁移 R89（2026-11-14）

R81–R88已完成，UIM01–UIM09及GU0、GU1 PASS；实际范围见[evidence/R81](../evidence/R81.md)–[evidence/R88](../evidence/R88.md)。R88把主机表单里输入框以外的表面、四个选择面板、路线编辑器和测试连接页换成Prism（输入框按R84保留Material），`ShunListRow` 加了 `selected`；读屏并节点的修法和「只留必要的容器」见R88第2.1、2.2节。继续采用FlClash / prism_ui单一目标，读[docs/24](24-ui-migration.md)与[UI决策](../../../docs/decisions/ui-system-decision.md)。

### Claude Code 首次接手

本机代码仓库是 `/Users/bing/xdw/shun/shun`，上一层是工具链工作区；在代码仓库内开始。最近已核验分支为 `shun/v3`，R88实现提交见tasks.json的R88.commit，验收与本交接在其后提交。这些是历史核验锚点，后续文档提交会使HEAD前进，不要求回退。

先读取现场分支、HEAD、dirty以及适用的CLAUDE.md（若存在）；显式读取根AGENTS.md和plan/v3/AGENTS.md，不依赖宿主自动加载。保留他人改动，不为对齐交接执行reset、强制checkout或清理工作区。若R89已有进展，按tasks.json和实际diff续接，不重复实现。

环境按 `docs/dev/README.md`：当前已核验Flutter 3.47.7、Dart 3.13.5、Zig 0.16.0；重新核对实际版本并设置项目Zig、环境脚本及NO_PROXY。**静态检查用 `flutter analyze --no-pub`**（不加时会按全局镜像改写pubspec.lock，见R84第7节）。整文件 `dart format` 前，先在项目目录里对HEAD版本跑 `dart format --output=none --set-exit-if-changed`，没有变化才整文件格式化；HEAD本来不合格式的文件只整理自己新写的段落（R88第6节列了哪些）。**全量单测用手册命令 `flutter test -j 4 --exclude-tags ai-cli-ssh-fixture`**（R87第5节）。debug构建加 `--target-platform android-arm64` 才能和R82归档条目对照。R81–R88归档在 `../.toolchain/artifacts/` 下各自目录。Flutter测试、截图与构建串行运行。

下面是本轮执行提示词；任务定义只维护在tasks.json，结果只按实际验证填写。

```text
在 /Users/bing/xdw/shun/shun 接手shun，按V3计划直接完成R89的实现、验证、证据和本地提交。
先读根AGENTS、plan/v3/AGENTS、STATUS及规定的契约文档，再读docs/24、
docs/decisions/ui-system-decision.md、tasks.json的R89条目和evidence/R84、R87、R88，以及docs/23的F41相关段落。
记录实际分支/HEAD/dirty/SDK/lock，核对R88证据仍对应当前代码；保留他人改动。
Prism固定63450c0ac0e8e1b2c0f3ed4ad7926dc94e083185，不重选库、不升级业务依赖；
静态检查用flutter analyze --no-pub，pubspec.lock有任何变动先还原再继续。
先清点：Tailscale设置面板（新建/已有来源、存过key的掩码、高级、管理tailnet、移除）、首次登录框、
凭据选择/新建/编辑/删除（引用数、删除影响）、凭据页（keychain_sheet）、代理列表与编辑、私钥导入、
安全密钥添加与询问、交互式认证框、服务器指纹确认框，迁移前后各导出一次读屏节点和key逐项对照
（做法见R86第2.1节、R88第2.1节；读屏并节点按R88第2.2节逐个实验，只留必要的容器）。
控件用ui/components.dart（ShunSection、ShunListRow、ShunSwitchRow、ShunOptionsRow、ShunSectionItem、
ShunButton、ShunSecretField）和ChoiceSegments；普通输入框保持Material浮动标签与FormGap 20dp（R84第2节）。
Tailscale面板继续用showNonModalPanel：无遮罩、背后列表可点，下滑/返回/切底栏关闭，未存草稿丢弃；
存过的key固定掩码，只能改或删，新key被拒时旧的还在，删除先确认；默认只有API key和登录两项，其余在高级。
秘密输入一律ShunSecretField或等价的三个输入法开关全关，敏感页防截屏；锁屏期间不弹安全密钥询问；
每跳host key先于认证的全局询问照常显示，代理失败不直连；RoutePlan预览不显示秘密。不改RoutePlan与存储。
新文字和输入框受R84扫描器约束（details按副标题16字查），不放宽上限、不加白名单；类型断言改稳定key/语义/行为。
单独装页面的测试用test/support/prism_test_host.dart补Prism宿主。
运行UIM10、UIM11及受影响的凭据、代理、Tailscale设置、首次登录、指纹、安全密钥、秘密输入、规则回归和静态检查；
图库补各面板与弹层浅深截图并逐张看；r75/r40设备测试若定位方式受影响只改稳定key。
本批仅做R89。完成后GU2的四项（R86–R89）齐了，按GU2的门禁定义实际核对再决定是否标PASS，不因R89通过就直接标。
不操作正式签名、用户手机或push/发布；不连真实tailnet、不用真实钥匙。
写evidence/R89.md并同步使用手册中实际变化、任务/用例及状态，作粒度提交；
使用plan/v3/scripts/set_status.py登记实际结果，再运行sync_docs.py和validate_plan.py。
完成本批后停止，报告完成ID、commit、验证数量/skip、截图位置、未测、GU2结论及下一任务。
透明模态冒充非模态、key可回显、锁屏穿透或新增隐藏连接/保存副作用即停，不能削弱原安全测试。
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
