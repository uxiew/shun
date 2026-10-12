# 20 参考 App：TermRover、LobiShell、OSH、meshTerm、NovaScale、Dokodemo CLI、ShellDiver

本页分两批证据：2026-10-10 的 Android 实地观察，以及 2026-10-11 的 App Store / 开发者资料研究。后一批没有安装或操作 App，功能描述均为官方公开声明，取舍和验收要求是 shun 的规划。

## 2026-10-10：TermRover、LobiShell 实地记录

2026-10-10，所有者同意后，在所有者的 Pixel 9 Pro 上打开看过两个 App：

- TermRover 1.2.2（`sh.termrover.app`）。另看了官网指南第 8 节和那段 50 秒的 Mosh 演示视频：https://termrover.sh/guide#how-to-mosh
- LobiShell 2.11.10（`de.lobianco.saftssh`）。它的 Mosh 也是单独安装的插件包（`de.lobianco.saftssh.mosh` 1.0.14），和我们的做法一样。

只点开菜单和表单看结构：没保存、没连所有者存着的真实主机、没打字，也没改设置。这些是参考 App 的事实，**不算本项目任何用例通过**（docs/00）。
只借鉴交互，不搬界面素材、文案和商标（docs/12）。

截图和界面结构树放在本机 `../.toolchain/artifacts/ref-apps-2026-10-10/`，**不进仓库**（里面有所有者的主机名和地址）。
LobiShell 带密码的编辑页禁止截屏，截出来是全黑的，那几页只有结构树。LobiShell 一打开就要指纹解锁，要所有者本人在场。

## 值得学的

| 看到的 | 出处 | 我们现在 | 任务 |
|---|---|---|---|
| 新建连接先选协议：SSH、Mosh、Telnet、串行/USB、本地 Shell、Linux（插件）、远程桌面（插件）、RustDesk（插件），表单跟着协议变 | LobiShell 连接编辑页 | 顶上四段 SSH / Telnet / Mosh / 插件；UU、RustDesk 挂在 SSH 主机上，只装了 RustDesk 的电脑得先填假的 SSH 地址和用户名 | R39 |
| Mosh 的表单就是 SSH 的表单，只在「高级」里多出 UDP 端口、mosh-server 参数、「连接时终止过期的 mosh-server」「在 tmux 中启动」（说明写着：Mosh 不保留回滚，靠 tmux 存历史） | LobiShell | Mosh 是独立协议，只多一个 UDP 端口范围 | R39、R41 |
| 编辑页有「首选连接方式 SSH / Mosh」两段，下面一句「建议先用 SSH，连上后随时能切 Mosh」 | TermRover 编辑页 | 没有 | R41、R42 |
| 跳板机是一个开关，打开后是一条链：「0 本机 START → ＋选跳板机 → ✓ 本主机 TARGET」，标题旁写「0 of 3 hops」。选跳板机是底部弹层，带搜索、按来源分组、显示在线状态 | TermRover 编辑页 | 「直连 / 经代理 / 经跳板机」三选一，加一个「先经代理（高级）」开关和预览卡；同一套代理表单出现在两种模式下；Tailscale 批量导入页又复制了一份 | R40 |
| 编辑页底部固定一栏：路线验证状态（未验证 / 路线未验证）+【测试连接】【取消】【保存】 | TermRover | 保存在右上角，测试连接夹在路线区块里 | R41 |
| 「高级」默认折叠，按组分：Mosh 覆盖、tmux 覆盖……每组开头一句「建议自动探测，起不来再改」。字段默认显示「自动」，端口范围旁有个「为什么？」 | TermRover | 高级选项平铺展开 | R41 |
| 可复用的「身份」：用户名 + 认证方式（密码 / 私钥 / 私钥+口令+密码 / FIDO2 / Tailscale），连接里选一个 | LobiShell 管理页 | 私钥能复用；代理只能从桌面端导入，手机上建不了 | R40（代理部分） |
| 终端顶栏有连接方式徽标 SSH / MOSH。点开是「切换连接方式」菜单；当前方式和默认不一样时，多一项「把 Mosh 设为默认」 | TermRover 演示视频 | 没有，Mosh 标签和 SSH 标签长得一样 | R42 |
| 断开的标签显示「上次的会话 · SSH」，加【重新连接】【选会话】 | TermRover | SSH 有自动恢复；Mosh 标签没有重新连接（X09 留下的） | R42 |
| 主机列表里 Tailscale 设备单独一节，带刷新、设置入口和在线/离线。每台主机的 ⋮：用 Mosh 连接 / 端口转发 / 编辑 / 隐藏 | TermRover 首页 | 目录在单独一页 | R43 |
| 带密码、私钥的页面禁止截屏，设置里可以显式打开。「IME 无痕模式」挡住密码自动补全和输入法学习 | LobiShell 安全设置 | 没有 | R44 |
| 特殊键栏能按连接分配布局；有模板：Windows、tmux/vim、AI CLI（Claude、Codex…）；按键高度、触觉反馈、方向键长按重复速度都能调 | LobiShell 界面设置 | 全局一套 | R45（后续） |
| 生物识别应用锁：宽限期、终端连着时不锁、可以直接用 PIN | LobiShell 安全设置 | 没有（10-08 定另开任务） | R46（后续） |
| 本地 Shell；Linux 用户态（Ubuntu，多个连接可以共用一个环境）；串行/USB（波特率、数据位、停止位、校验、流控、选 USB 设备） | LobiShell | 没有 | R47、R48（后续） |
| 远程桌面插件（VNC / RDP / Proxmox SPICE，noVNC 兜底）；RustDesk 插件（画面在 App 里） | LobiShell 插件页 | RustDesk 是交给外部 App；内嵌画面是 R38 | R49（后续）、R38 |
| 命令补全（远端 compgen 一次 + 自己的历史）、拼写纠正（suod→sudo）、右侧小地图 | LobiShell 终端行为设置 | 没有 | R50（后续） |
| 插件页每个插件一行状态：「已检测到插件 — Mosh 连接可用 ✓（v1.0.14）」或「未安装 — 不可用」+ 安装 | LobiShell | 插件页更细（证书、能力），但新建连接时看不出哪种方式现在能用 | R39 |

## 不学的

| 看到的 | 为什么不学 |
|---|---|
| 串行/USB、本地 Shell 的表单里照样有「通过跳板机路由」「通过 SOCKS5 代理路由」「连接前需要 VPN」 | 对这些类型没有意义，用户会以为设了就生效。我们按类型只显示用得上的项（R39） |
| TermRover 根本没有代理选项 | 我们的用户要走 TailSocks、公司代理（R06、R07），不能删 |
| TermRover 在服务器缺 mosh-server 时帮你装 | 要 sudo。AGENTS 和 R25 的停止条件都写了不扩大 sudo。我们只给对应发行版的安装命令，让用户自己执行（R42） |
| TermRover 网页示意图里 Mosh 后面标着「ROAM」（漫游） | X10 没在真机上过之前，界面和手册都不说「漫游」「切网不断」 |
| LobiShell 的「连接时终止过期的 mosh-server」 | 这是杀远端进程。要做也得用户每次明确点、看清杀哪几个，不放进自动连接流程；先不做 |
| LobiShell 的 Wake-on-LAN、Wake webhook、Port Knocking、NFC/二维码标签 | 已经在 R37（后续） |
| LobiShell 的转发 SSH agent、FIDO2 | 已经在 R36（后续） |
| LobiShell 的「sudo 密码」（给特殊键栏的 sudo 键自动填） | 把密码拿去喂 sudo，属于扩大 sudo 功能，R25 停止条件不做 |
| LobiShell 的 Mosh 表单里也能选跳板机、SOCKS5（实际怎么走没测） | 我们 Mosh 首版只直连（AGENTS）；经代理是 R34 |
| 两个 App 的主题、图标、文案原样照搬 | 闭源素材（docs/12） |

## 2026-10-11：App Store 与开发者资料

所有者要求继续参考以下三款。按 App Store ID 确认产品，避免名称变化认错；访问日期统一为 2026-10-11。没有登录账号、连接网关、安装服务端或验证手机恢复行为。

| 应用 | 官方描述与产品定位 | 证据边界 |
|---|---|---|
| [OSH - Zero Trust SSH](https://apps.apple.com/us/app/osh-zero-trust-ssh/id6785531354)（6785531354） | SSH 访问审批器：扫码登记设备，手机展示请求，以生物识别授权硬件密钥签署审批，兼容网关再签发短期 SSH 证书；有角色、规则与审批记录 | 手机审批签名不等于 SSH 客户端签名，也不等于手机签发证书。未取得可核实的网关协议或 SDK；不能推导与 Tailscale SSH/check 兼容。[S70](13-sources.md#s70) |
| [meshTerm SSH Client Tailscale](https://apps.apple.com/us/app/meshterm-ssh-client-tailscale/id6761196011)（6761196011） | 移动 SSH/SFTP，内置 Tailscale、多 tailnet；指南把会话持久性分为 None、tmux、mtRoam，提供命名会话、键盘工具和诊断 | 内置网络、远端 shell、手机终端历史是不同层。商店抓取为 2.2.0，指南仍有 2.1/2.1.11 文案，不拼成一份已实测支持矩阵。[S72](13-sources.md#s72) [S73](13-sources.md#s73) |
| [NovaScale, Built for Tailscale](https://apps.apple.com/us/app/novascale-built-for-tailscale/id6749938291)（6749938291） | 以主机为入口整合内置 Tailscale、SSH/tmux、监控、SFTP、私有网页，以及远程 Codex/Herdr 工作区；也列出传统 SSH 与 Headscale | 商店页为 1.7.0；官网另列 Android 版，不能将 iOS 的整套能力直接推给 Android 或 shun。高级工作区需要相应的用户自有主机服务。[S76](13-sources.md#s76) [S77](13-sources.md#s77) |

### 并入已有任务

以下是结合现有代码与契约作出的设计取舍，不是对竞品实现的保证。已完成任务的证据不变；新增验收均从 NOT_RUN 开始。

| 借鉴点 | shun 的落地范围 | 任务 / 验收 |
|---|---|---|
| meshTerm 的持久性选择；NovaScale 的终端与 tmux 返回入口 | 编辑页把「SSH / Mosh 连接方式」和「普通 shell / 指定 tmux 会话」分开说明；标签显示主机、远端目标和恢复阶段，失联时只称历史画面。tmux 按 R21 的完整目标核对；不按名字自动附着，不把普通重连称为恢复原 shell | R41、R42；UX07、UX11；R42 增加 R23 前置 |
| meshTerm 的每主机事件记录 | 在已有诊断入口显示连接阶段、失败位置、耗时和重连次数；只保留有限本地元数据，可清除。没有采样就显示未知，不拿 SSH 握手耗时当网络 ping | R25、R43；UX10 |
| 两款终端的多 tailnet / 主机工作入口 | 主机列表按目录来源分组；同名同 IP 不合并。控制面连接状态、SSH 连接状态、缓存时间分开；换来源不改活动会话身份和路线，不以列表切换冒充已经加入另一 tailnet | R43；扩充尚未执行的 UX09 |
| 两款终端把 SFTP 与主机工作放在一起 | 回归已有文件浏览、预览、上传/下载、取消与覆盖流程，保持同一目标 client 和代次；大文件有界，断线明确中断或未知。此轮不加入新编辑器、自动上传剪贴板或附件云处理 | R24；UX12 |
| meshTerm 的键盘分组；NovaScale 的常用按键和建议 | R45 评估分页、折叠和会话快捷入口；R50 仍只显示待确认建议，数据源保持已有规划的受限探测和本机历史，不自动读 shell history 或写 shell rc | R45、R50，仍为 P6 |
| OSH 的逐次审批 | 应用解锁、硬件签名、证书签发分别建边界。应用解锁宽限期不授权任何外部签名；Android 是否硬件支持必须按设备测，不能从 iPhone Secure Enclave 宣称迁移得出 | R36、R46；短期证书另列 R51 |
| meshTerm / NovaScale 的进程内 Tailscale | 复用已有 R32，不另造重复任务；评估节点身份与退出、控制面凭据隔离、多来源、DNS、系统 VPN 共存、Android 生命周期和资源。NovaScale 的 libtailscale 仓库只是候选实现线索 | R32；[S79](13-sources.md#s79)，仍为 P6 |

### 新增后续候选

OSH / meshTerm / NovaScale 这一批只授权继续研究和完善规划。R51–R54 保持 P6 / DEFERRED，不进入 V3 主线依赖；启用前按任务补专用用例。所有者随后明确新增的 AI CLI 快速启动与继续需求另列 R55–R57 主线，见下节。

| ID | 范围 | 最先要解决的问题 |
|---|---|---|
| R51 | 短期 SSH 证书与访问审批接入研究 | 先分清本机作为请求端还是审批端，取得网关协议及证书认证能力证据；不自建 CA/团队管理平台，不把 Tailscale check 改成 OSH |
| R52 | 主机服务书签与受控内网网页 | URL、DNS、重定向和子资源均遵守所选路线；外部浏览器不能自动继承 App 内隧道，无法保证时明确不可用；TLS 信任另行核对 |
| R53 | 主机与容器只读概览 | 先基于已验证 SSH client 展示资源/容器状态；探测能力和权限不足可说明。停止、重启、部署、exec 和 sudo 不随只读看板启用 |
| R54 | 远程开发工作区适配研究 | 终端显示 AI CLI 与协议级工作区是不同能力；先冻结用户自有服务的协议、认证、版本和会话归属，区分查看与写入/审批；不默认开启继承 AI、云同步或推送 |

### 不照搬的行为与待核实项

- **mtRoam 不是 Mosh。** [官方 mtroamd 仓库](https://github.com/AG-Studio-Apps/mtroamd)描述的是独立服务端、QUIC、SSH 引导及持久输出协议，声明 AGPL-3.0-or-later；未审计全部源码及依赖。它不算 R34 的 UDP 路线扩展，也不纳入 R42；原生 tmux control-mode 窗格 UI 同样不随本批进入。[S74](13-sources.md#s74)
- **进程内网络不保证 shell 持久。** NovaScale FAQ 明说 iOS 进程被终止后不能依赖原内存会话恢复；shun 的 tmux、Mosh 和冷启动分别按 R23、X10 验证。手机缓存的旧屏也不能当远端还在运行的证据。[S78](13-sources.md#s78)
- **不采用绕过系统 VPN 的恢复策略。** NovaScale FAQ 描述 FakeIP 场景下可绑定非 VPN 网卡；这与 shun 的 docs/04 相冲突。R32 即使进入研究也不得照搬；DNS 失败应明确报错。[S78](13-sources.md#s78)
- **不照搬一键安装与自动降级。** 安装 daemon/agent、公钥部署、容器写操作和开放端口均增加远端副作用；不因竞品支持就开启。失败不直连、不自动切协议、不暗建/杀 tmux、不重放输入的规则保持。
- **不从应用锁推导硬件保护。** OSH 声称 Secure Enclave 密钥不可导出，只能作为目标体验参考；shun 的现有保险库加密不等于硬件 SSH 签名。审批通过也不等于 SSH 已连接。[S70](13-sources.md#s70)
- **隐私声明不是网络审计。** OSH 不同地区抓取的更新说明有差异，另一地区页的 1.0.6 提到推送中继与团队通知，不能将旧简介“只连网关”作为全量外连结论；商店所链隐私页本轮未成功读取。[S71](13-sources.md#s71) meshTerm 的旧隐私段落与新版同步说明对私钥/known-host 同步范围有差异，需按版本复核；推送中继不能归为纯本地。[S75](13-sources.md#s75)
- **不复制默认同步、语音服务或文案素材。** shun 保持秘密和终端内容默认不上云；已有中文 IME 不因 iOS 语音功能而更换。高级能力先走 P6，现有字段和命令边界不因参考应用自动放宽。

完整任务与验收见 [docs/08](08-implementation-tasks.md) 和 [docs/09](09-verification.md)；来源 S70–S79 的 URL、访问日期与证据层级同时登记在 [docs/13](13-sources.md) 和 `sources.json`。

## 2026-10-11：Dokodemo CLI、ShellDiver 与 AI CLI 快速继续

所有者继续指定两款 iOS App，并明确要求识别已有 Claude/Codex 等命令行 AI 工具、快速启动、再次打开时接着最后的工作。本节仍只读官方资料，没有安装或操作这两款 App；新增产品需求进入主线规划，未开始实现。

| 应用 | 核实的官方资料 | 可借鉴与限制 |
|---|---|---|
| [Dokodemo CLI - SSH Terminal](https://apps.apple.com/us/app/dokodemo-cli-ssh-terminal/id6771627844)（6771627844） | 所有者写的 Dokdemo 对应官方名称 Dokodemo CLI（どこでもCLI），开发者 Satoshi Sakuma / Koyomi App Lab；介绍多终端及 AI 状态提示。[S80](13-sources.md#s80) | 借鉴从会话列表看到工具状态；只把状态作为有来源、会过期的提示，不能作为恢复目标或审批依据 |
| [ShellDiver: SSH Client](https://apps.apple.com/us/app/shelldiver-ssh-client/id6794262497)（6794262497） | Mathias Oysmueller / Ostrong Studios，抓取版本 1.2.0；连接由 session 持有，支持 snippets 和启动命令，连接窗口显示 jump 与 startup；自动重连会启动新 shell。[S83](13-sources.md#s83) | 借鉴启动信息可见、页面切换不丢会话；重连不等于原 AI 进程或对话恢复 |

Dokodemo 的 [FAQ](https://shopkoyomi.com/article/?id=78&lang=en) 说明 AI 状态受终端标题信号、工具版本/配置影响；命令参考和字典不等于自动检测。目录选择会向当前终端发 `cd`，shun 的启动器不采用这一方式，避免文本进入 AI 输入框或其他 TUI。连接测试只说明所测握手/认证层，不证明交互工作已经可用。[S81](13-sources.md#s81) 它的 Tailscale 教程依赖独立 Tailscale App，不作为进程内组网证据。[S82](13-sources.md#s82)

ShellDiver 的 [开发者隐私说明 §5.5](https://www.ostrongstudios.de/datenschutzerklaerung/) 区分普通 Keychain 密钥与硬件绑定密钥，并描述默认关闭的可选同步/Vault。此类声明只作 R36/R46 的边界参考，不作为 Android 硬件签名或 shun 同步功能已具备的证据。[S84](13-sources.md#s84)

本轮读取的两款官方材料中，**未找到“自动发现远端所有 AI CLI”或“准确恢复最后 AI 对话”的声明**。以下是所有者新增的 shun 产品需求，不冒充竞品已经验证的能力，也不等待 R54 的协议级工作区研究。

| 新增主线 | 预期体验 | 关键验收 |
|---|---|---|
| R55 工具发现 | 选定主机后识别 Claude/Codex/Gemini/OpenCode，显示路径、版本和扫描范围；能补充其他工具 | 发现不等于登录；非交互 PATH、别名、多安装和未知工具有解释及手动入口；不扫描全盘、不发模型请求 |
| R56 项目启动器 | 选工具、项目目录，一次点击进入；有 tmux 时可显式保留远端会话 | 使用专用目标，安全处理目录和参数；重复点击/重连不重复启动，不向当前 AI/vim 粘命令 |
| R57 继续最后工作 | 首页/主机显示最后成功打开的工具和项目；先回活标签或指定 tmux，结束后继续原生 ID 对话 | 绑定主机、用户、工具、项目/worktree、完整 tmux 与窗格、原生 ID；缺失不猜 `--last`，不以新会话顶替；冷启动不重放 |

三项均为 P4：R55 已完成本机隔离验收，R56/R57 已接入功能、仍在验收；G4 纳入 R57，R25 已接入最近工作入口。AIC01/AIC02 有本机隔离证据，AIC03/04/05/07/08 已完成[无账号故障与模拟器矩阵](../evidence/R56-R57-fault-matrix.md)，AIC06/AIC09 仍需真实原生对话证据。Claude/Codex 首批分别验证启动、tmux 返回与原生 ID 继续；其他工具逐模式声明支持。命令语义与 ID 获取条件见 [产品范围](02-product-scope.md)，官方 CLI 来源 S85–S88 见 [来源表](13-sources.md)。现有 R20 未登录欢迎页测试不转移为新功能证据。
