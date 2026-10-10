# 20 参考 App 实地记录：TermRover、LobiShell

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
