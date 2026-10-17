# Mosh 使用指南

写给想在这个 App 里用 Mosh 的人：从在服务器上装 mosh-server、手机上装插件，到连接、切换、排错，
再到不用了怎么卸干净。其余功能看 [使用手册](README.md)。

**Mosh 是什么**：给不稳定网络设计的终端协议。先用 SSH 登录一次、在服务器上启动 `mosh-server`，
之后终端全走 UDP，由 Mosh 自己重传和接续。说白了：登录靠 SSH，干活靠 UDP。

**现在测到什么程度**：只在 Android 模拟器和本机 Docker 测试环境里测过，见最后一节 [实测范围](#10-实测范围)。
手机换网络、锁屏后台时 Mosh 会话能不能接着用，还没测。

## 目录

1. [用之前要准备的三件事](#1-用之前要准备的三件事)
2. [在服务器上装 mosh-server](#2-在服务器上装-mosh-server)
3. [放行 UDP 端口](#3-放行-udp-端口)
4. [手机上装 Mosh 插件](#4-手机上装-mosh-插件)
5. [添加 Mosh 主机、连接](#5-添加-mosh-主机连接)
6. [和 SSH 标签不一样的地方](#6-和-ssh-标签不一样的地方)
7. [在终端里切换 SSH / Mosh](#7-在终端里切换-ssh--mosh)
8. [连不上、断了](#8-连不上断了)
9. [不用了：卸载和清理](#9-不用了卸载和清理)
10. [实测范围](#10-实测范围)

## 1. 用之前要准备的三件事

| 在哪 | 做什么 | 漏了会怎样 |
|---|---|---|
| 服务器 | 装 mosh（里面带 `mosh-server`），见 [第 2 节](#2-在服务器上装-mosh-server) | 连接时报「远端没有找到 mosh-server」 |
| 服务器防火墙、云服务器安全组 | 放行 UDP 60001–60999（或你指定的几个），见 [第 3 节](#3-放行-udp-端口) | SSH 登录成功、约 20 秒后终端里出现 `mosh did not make a successful connection` |
| 手机 | 装 Mosh 插件 App（「shun Mosh」）并在本 App 里批准，见 [第 4 节](#4-手机上装-mosh-插件) | 连接时报「没有装 Mosh 插件」，或者菜单里「切换到 Mosh」变灰 |

另外一条硬规矩：**Mosh 主机只能直连**。配了代理或跳板机的主机不能用 Mosh：UDP 要从手机直接发到服务器，
代理和跳板都只管 TCP。要经代理就用 SSH（想断线后接着用，配合 tmux，见使用手册 [第 10 节](README.md#10-tmux)）。

## 2. 在服务器上装 mosh-server

两种装法，结果一样。第一次用推荐 A：命令是 App 按服务器的发行版选好的。

### A. 在 App 里装

什么时候会出现：连 Mosh 主机或者把标签切到 Mosh 时，App 发现服务器上没有 mosh-server，就弹出「服务器上没有 mosh-server」。
从保险库连的那种，在失败页上点「看安装命令」。

1. 提示里写着「认出来的系统」和一条安装命令。这条是照服务器 `/etc/os-release` 里的发行版，从 App 里写死的表里选的，
   服务器发来的内容一个字都不会拼进命令。用 root 登录的主机命令里没有 `sudo`；普通用户登录的，需要 root 的那几段前面加了 `sudo`。
   你看到的就是会执行的。
2. 点「安装…」，弹出确认框，写着：
   - 会新开一个 SSH 标签「安装 mosh · 主机名」，登录这台后执行哪一条；
   - 要管理员权限时：`sudo` 会在那个终端里问你的密码，你自己输。**App 看不到、也不保存这个密码**；
   - mosh 从服务器自己配的软件源下载，服务器要能上网；
   - 装完还要放行哪几个 UDP 端口；
   - 以后不用了用哪条命令卸。
3. 点「取消」：什么都不发。点「打开 SSH 标签并安装」：新标签登录、执行这条命令**一次**。
   要密码、包管理器问「要不要继续（Y/n）」，都在这个标签里自己答。
4. 装完按 [第 3 节](#3-放行-udp-端口) 放行端口，再重新连接或者再点一次切换。安装标签用完关掉就行。

这个安装标签是一次性的：断线自动恢复时不会再执行一次、App 被系统结束后不会放回来（放回来也不会再装）、
不能切换连接方式。保险库里这台主机的设置不变。

不想让 App 执行，提示里还有两个按钮：「复制」；「填进 SSH 标签（不回车）」（只在开着这台的 SSH 标签时有，看过再自己按回车）。

**装的时候报错：**

| 看到的 | 意思 | 怎么办 |
|---|---|---|
| `sudo: not found` / `sudo: command not found` | 服务器上没装 sudo（精简系统、容器里常见） | 用 root 登录这台再装（命令里就不带 sudo 了），或者自己换成 `doas` |
| `xxx is not in the sudoers file` | 这个账号没有管理员权限 | 找服务器管理员装，或者用有权限的账号 |
| `Unable to locate package mosh` / `No match for argument: mosh` | 软件源里没有，或者源太旧 | Debian/Ubuntu 先 `sudo apt-get update` 再装；RHEL/CentOS/Rocky/Alma 的 mosh 在 EPEL 里，RHEL 本体要先按 EPEL 官方说明启用 EPEL |
| 卡在下载、`Could not resolve host` | 服务器上不了网 | 先让服务器能访问它的软件源，或者按各发行版的离线办法装 |
| 提示里没有安装命令，写「没认出的系统」或「没有这个发行版的现成命令」 | App 不认识这个发行版 | 用它自己的包管理器装，包名一般就叫 `mosh` |

### B. 自己装

登录服务器，按发行版执行下表「安装」一列。「要 root」是否的那几条，普通用户前面自己加 `sudo`。
这张表和 App 里用的是同一份（`lib/domain/plugins/mosh_install_hint.dart`）。

| 发行版 | 安装 | 卸载 | 要 root |
|---|---|---|---|
| Debian、Ubuntu、Linux Mint | `sudo apt-get install mosh` | `sudo apt-get remove mosh` | 命令里已带 sudo |
| Fedora | `sudo dnf install mosh` | `sudo dnf remove mosh` | 命令里已带 sudo |
| RHEL、CentOS、Rocky、AlmaLinux、Oracle Linux、Amazon Linux | `sudo dnf install epel-release && sudo dnf install mosh` | `sudo dnf remove mosh` | 命令里已带 sudo |
| Arch、Manjaro | `pacman -S mosh` | `pacman -R mosh` | 是 |
| openSUSE、SLES | `sudo zypper in mosh` | `sudo zypper rm mosh` | 命令里已带 sudo |
| Alpine | `apk add mosh` | `apk del mosh` | 是 |
| Gentoo | `emerge net-misc/mosh` | `emerge --deselect net-misc/mosh && emerge --depclean net-misc/mosh` | 是 |
| Void | `xbps-install -S mosh` | `xbps-remove mosh` | 是 |
| FreeBSD | `pkg install net/mosh` | `pkg delete mosh` | 是 |
| Guix | `guix package -i mosh` | `guix package -r mosh` | 否（装在你自己的 profile 里） |
| NixOS | 在 `configuration.nix` 里加 `programs.mosh.enable = true;`，再 `sudo nixos-rebuild switch`（顺带放行 Mosh 的 UDP 端口） | 删掉这一行，再 `sudo nixos-rebuild switch` | — |

**装好以后核对**：在服务器上执行 `command -v mosh-server`，打印出一个路径就是装好了。什么都没打印，
要么没装上，要么装在了登录 shell 的 PATH 以外：知道在哪就把完整路径填进主机的「mosh-server 路径」（[第 5 节](#5-添加-mosh-主机连接)）。

## 3. 放行 UDP 端口

mosh-server 每个会话占一个 UDP 端口，默认从 60001–60999 里挑。服务器本机防火墙和云服务器的安全组（阿里云、腾讯云、AWS 控制台里的那一层）
**都要**放行。只想开少数几个端口，比如 60001–60010，就把主机的「UDP 端口范围」填成 `60001:60010`，
放行的范围跟它一样。

| 服务器上用的是 | 放行 | 以后关回去 |
|---|---|---|
| ufw（Ubuntu 常见） | `sudo ufw allow 60001:60999/udp` | `sudo ufw delete allow 60001:60999/udp` |
| firewalld（Fedora、RHEL 系常见） | `sudo firewall-cmd --permanent --add-port=60001-60999/udp && sudo firewall-cmd --reload` | `sudo firewall-cmd --permanent --remove-port=60001-60999/udp && sudo firewall-cmd --reload` |
| 云服务器安全组 | 在控制台加一条入方向规则：UDP、端口 60001-60999 | 删掉那条规则 |

不确定用的是哪个：`sudo ufw status` 和 `sudo firewall-cmd --state` 各试一下，哪个说在跑就是哪个。
直接写 iptables / nftables 规则的，照你自己的规则文件加一条放行这段 UDP 的。

漏了放行不会在连接时就报错：SSH 那一段照常成功，约 20 秒后终端里才出现 `mosh did not make a successful connection`。

## 4. 手机上装 Mosh 插件

Mosh 不在本 App 里，由另一个 App「shun Mosh」（包名 `top.xdwa.shun.mosh`）提供。本 App 不下载、不安装插件。

1. 把 Mosh 插件的 APK 装到手机上。现在还没有发布的安装包，要自己从源码编，步骤见 `plugins/mosh/README.md`。
2. 打开本 App「设置 → 插件（实验）」，点「shun Mosh」，核对证书 SHA-256 后点「批准」。插件页各种状态是什么意思、
   怎么停用、撤销批准，见使用手册 [第 17 节](README.md#17-插件实验)。

批准以后插件拿得到的只有每次会话的 IP、端口和一次性密钥；你的密码、私钥、代理口令它拿不到。

**插件显示「已拒绝」、没有批准按钮**：本 App 只认登记过的那张证书签的 Mosh 插件。现在登记的是测试作者证书
`7feb5825…6e9d`（2026-10-17 起）。之前用旧测试钥匙（`ffb53d5a…`）编的插件会被当成冒充者：卸掉它，装新编的。

## 5. 添加 Mosh 主机、连接

建议先按 SSH 加好这台、连上，再点终端顶上的「SSH」徽标切到 Mosh（[第 7 节](#7-在终端里切换-ssh--mosh)），顺手把 Mosh 设为这台的默认。
直接建也行：

1. 新建连接选 **Mosh**，或者在编辑页「首选连接方式」里从 SSH 改成 Mosh。用户名、SSH 端口、密码或私钥照常填——Mosh 要先用 SSH 登录一次。
   「连接路径」只能是**直连**。
2. 「高级 → Mosh 启动参数」先留空，连不上、[第 8 节](#8-连不上断了)的表里让你改时再填：

   | 字段 | 什么时候填 | 例子 |
   |---|---|---|
   | mosh-server 路径 | 连接时报「远端没有找到 mosh-server」，而你知道它装在哪。留空时先按登录 shell 的 PATH 找，再查 `/usr/bin`、`/usr/local/bin`、`/opt/homebrew/bin`、`~/.local/bin`、nix profile | `/opt/mosh/bin/mosh-server`、`~/bin/mosh-server`（`~` 由服务器展开） |
   | UDP 端口范围 | 服务器或防火墙只放行了某几个 UDP 端口 | `60001`、`60001:60010` |
   | locale | 连接时报「远端没有可用的 UTF-8 语言环境」，服务器上又没有 `en_US.UTF-8` | `C.UTF-8`（服务器上 `locale -a` 能看到有哪些） |

   路径只接受 `/` 或 `~/` 开头、由字母数字和 `._+-` 组成的写法，不能带空格或 `..`；写错了保存时就报。
3. 保存，在保险库里点这台「连接」。等待页依次写：
   「正在核对本机的 Mosh 插件」→「SSH 握手、核对指纹、登录」→「第 1 段 SSH：…正在启动 mosh-server」→「第 2 段 UDP：SSH 已断开，Mosh 插件正在直连 IP:端口」。
   模拟器上从点连接到出提示符约 1.3 秒。

Mosh 主机不执行 SSH 的「连接后执行命令」；没有「测试连接」按钮：它只测得了 SSH 那一段，给 Mosh 主机一个「通过」反而误导。

## 6. 和 SSH 标签不一样的地方

- **两段走的是两条路。** SSH 只用来在服务器上启动 mosh-server、拿到这次会话的端口和一次性密钥，拿到就断开；
  之后终端全走 UDP，从手机直接发到刚才 SSH 实际连上的那个 IP。所以「SSH 能连上」不代表 Mosh 能通。
- **只能直连。** 选了代理、跳板机（包括 TailSocks 这种手机上的 SOCKS5）的 Mosh 主机，编辑器不让保存；从桌面端同步来的，
  点连接时直接报错，**什么都没发**：没连服务器、没启动 mosh-server，也不会改成直连绕过你选的路线。
- Mosh 标签没有文件（SFTP）、性能监控、端口转发、系统管理：这几样都要借 SSH 连接，而 Mosh 的 SSH 用完就断了。
  要用就点顶上的 MOSH 徽标切回 SSH。
- 终端和 SSH 标签一样是 Ghostty；中文输入法、语音输入见使用手册 [第 9 节](README.md#9-快捷键栏键盘与分屏)。
- **会话结束不自动重连，也不重发断开前的输入。** 标签留着，终端里用红字写明为什么结束；要再连就点顶上的「重新连接」——
  那是服务器上新起的一个 mosh-server，不是原来那个会话。新的连上以后顶替这个标签的位置，连不上时这个标签和画面不动。
  附着着 tmux 的 Mosh 标签（从 SSH 切过来的）重新连接时先核对服务器上还是不是原来那个 tmux 会话，是才附着；不是就停下写明原因，不新建。
- 关 Mosh 标签：服务器上这次的 mosh-server 和里面的 shell 一起退出（模拟器上实测约 0.3 秒后远端就没了）。
  附着着 tmux 的 Mosh 标签只带走 tmux 客户端，tmux 会话和里面的程序留在服务器上。
- 桌面端 Netcatty 不认 Mosh 主机的这些设置：同步过去的主机在桌面端还是按普通 SSH 连。

## 7. 在终端里切换 SSH / Mosh

终端标签条右边有个小徽标，写着当前标签走的是 **SSH** 还是 **MOSH**（Telnet、第三方插件的标签没有）。点它打开「连接方式」。

最上面写着这个标签连的是哪台（`用户@地址:端口`）、里面是**普通 shell** 还是哪个 **tmux 会话**（名字、`$3` 这样的编号、socket），
以及现在的状态：已连接 / 正在自动恢复 / 正在重新附着 / 已断开（终端里是断开前的画面，只是历史，不代表远端还开着）。

**切换**

| 标签里是 | 点「切换」会怎样 |
|---|---|
| 普通 shell | 用另一种方式**另开一个标签**（新的 shell，不跑「连接后执行命令」）。原来的标签和它的 shell 不动——普通 shell 跟着连接走，换不了底 |
| tmux 会话 | **原地切换**：还是这个标签、还是同一个 tmux 会话。新的一边先附着同一个会话、核对过确实是它，标签才换过去，然后分离旧的客户端、关掉旧连接。全程不往会话里发任何按键 |

- SSH → Mosh 走的是这个标签已经登录的 SSH，不再登录一次：在上面启动 mosh-server，让它附着同一个会话。
  这条 SSH 随后关掉，挂在它上面的**端口转发会停**：切之前列出会停哪几条，你确认了才切。确认以后又新开了转发，这次不切，再点一次会重新列。
- Mosh → SSH 要重新登录一次 SSH，沿用这个标签的路线和账号。
- 切的过程中旧的一边照常能用，终端顶上写进度，可以点「取消」。中途失败、取消或者关标签，新的一边全部关掉，原标签不动，
  弹出的提示写「没有切换，原来的连接不变」和原因。
- tmux 会话在切换前被结束了、tmux server 重启过、或者只剩一个同名的新会话：不切，写明原因。不会附着同名的那个，也不会新建，
  服务器上连 mosh-server 都不起。
- 服务器上没有 mosh-server：弹出安装提示，见 [第 2 节](#a-在-app-里装)。装好再点一次切换。

**灰掉的项写着原因**，常见的：Mosh 只能直连（这台配了代理或跳板）；Mosh 插件没装、没批准；标签已经断开（先点「重新连接」）；
AI 工具的专用标签、一次性命令标签（「系统管理」或安装 mosh 开的）不切。

**把 Mosh（或 SSH）设为这台主机的默认**：只在这个标签现在的方式和主机默认的不一样时出现。只改主机的「首选连接方式」，
以后从保险库连这台就用它；开着的标签不变，Mosh 启动参数照旧留着。

**选 tmux 会话…**：只读列出这台主机默认 socket（或这个标签所在的 socket）上的 tmux 会话，选一个在新标签里附着，
规则同使用手册 [第 10 节](README.md#10-tmux)。要借一个连着的 SSH 标签来查（Mosh 标签自己查不了）；要新建、结束、换 socket，用「系统管理 → tmux」。

## 8. 连不上、断了

| 看到的 | 意思 | 怎么办 |
|---|---|---|
| Mosh 只能直连，这台主机的连接路径是：… | 这台主机配了代理或跳板 | 改成直连，或者协议改回 SSH |
| 没有装 Mosh 插件 / Mosh 插件还没批准 / 被停用了 | 本机插件的问题，还没连服务器 | 到「设置 → 插件（实验）」处理，见 [第 4 节](#4-手机上装-mosh-插件) |
| 主机指纹没有通过校验 / 登录被拒绝 | SSH 那一段的问题，和普通 SSH 一样 | 见使用手册 [第 5 节](README.md#5-服务器指纹)、[第 6 节](README.md#6-连接中连接失败)。指纹没过时连登录信息都没发 |
| 远端没有找到 mosh-server | PATH 和常见安装位置里都没有：要么没装，要么装在别处 | 没装就点失败页上的「看安装命令」，见 [第 2 节](#2-在服务器上装-mosh-server)；装在别处就把完整路径填进「mosh-server 路径」 |
| 指定的 mosh-server 路径在服务器上不存在或不能执行 | 「mosh-server 路径」里写的文件在服务器上没有，或者没有执行权限 | 在服务器上 `ls -l 那个路径` 核对；不确定就清空，让 App 自动找 |
| 远端没有可用的 UTF-8 语言环境 | 服务器上没有 `en_US.UTF-8`（或你填的那个） | 服务器上 `locale -a` 看有哪些，比如有 `C.UTF-8` 就填进「locale」；或者请管理员 `locale-gen en_US.UTF-8` |
| 终端里：mosh did not make a successful connection to IP:端口，下面红字「mosh-client 没能正常收尾（退出码 1）」 | UDP 到不了服务器（模拟器上约 20 秒后出现） | 按 [第 3 节](#3-放行-udp-端口) 放行；只放行了几个端口的，把主机的「UDP 端口范围」填成一样的 |
| 终端里：Mosh 插件进程没了 | 插件被系统或手动结束 | 点「重新连接」。服务器上可能留着旧的 mosh-server，清理见 [第 9 节](#服务器上剩下的-mosh-server-进程) |

## 9. 不用了：卸载和清理

按顺序做：先把 App 里的主机改回 SSH，再清服务器，最后卸手机上的插件。只是暂时不用，做第一步就够了。

### App 里的主机改回 SSH

- 在保险库里编辑这台，「首选连接方式」改成 SSH。或者在这台的 **SSH** 标签上点 SSH 徽标 →「把 SSH 设为这台主机的默认」：
  「设为默认」设的是这个标签自己现在的方式，所以要在 SSH 标签上点；手上只有 Mosh 标签的，先用菜单里「用 SSH 另开一个」。
- 「高级 → Mosh 启动参数」会留着，SSH 连接不用它们，不影响什么；不想留就改成 SSH 前先清空那三格。
- 开着的 Mosh 标签关掉。普通 Mosh 标签一关，服务器上对应的 mosh-server 就退出；附着 tmux 的只带走 tmux 客户端。

### 服务器上卸载 mosh

用 [第 2 节表里](#b-自己装)「卸载」那一列，也就是当初确认框里写的那条。先确认这台服务器上没有别人在用 mosh。

那条命令只卸 mosh 这一个包。装 mosh 时顺带装上的依赖（比如 protobuf 的库）各家处理不同，想一起清掉：

| 发行版 | 顺带的依赖 | 想清就 |
|---|---|---|
| Debian、Ubuntu | 留着 | `sudo apt-get autoremove`。它会列出要删的包再问你，列表里可能有别的程序留下的、和 mosh 无关的包，看清楚再答 Y。连 mosh 的配置一起删用 `sudo apt-get purge mosh` |
| Fedora、RHEL 系 | dnf 默认在 `remove` 时一起删掉没人用的依赖 | —。当初为了 mosh 装的 `epel-release` 不会跟着删：别的软件也不用 EPEL 的话，`sudo dnf remove epel-release` |
| Arch、Manjaro | 留着 | 卸的时候用 `pacman -Rs mosh` 代替 `pacman -R mosh`，把没别人要的依赖一起删 |
| openSUSE、SLES | 留着 | 卸的时候用 `sudo zypper rm --clean-deps mosh` |
| Alpine | `apk del` 会一起删掉没人用的依赖 | — |
| Gentoo | 表里那条已经是 `--depclean` | — |
| Void | 留着 | 卸的时候用 `xbps-remove -R mosh` |
| FreeBSD | 留着 | 卸完再 `pkg autoremove` |
| Guix | 包还在 store 里 | `guix gc` 收回空间 |
| NixOS | 旧的系统版本还引用着 | 确定不回退了再 `sudo nix-collect-garbage -d` |

### 服务器上剩下的 mosh-server 进程

mosh-server 在客户端突然消失时（手机没电、插件被系统杀掉、网络一直不通）会一直等它回来，不自己退出。卸载前后清一下：

```bash
pgrep -a -u "$USER" mosh-server     # 列出你自己的，每行一个
pkill -u "$USER" mosh-server        # 结束你自己的：里面的 shell 和程序一起结束
```

带 `-u "$USER"` 是为了不碰别人的 Mosh 会话。你在 mosh-server 里直接跑（没套 tmux）的程序会跟着结束；
套了 tmux 的只是少一个客户端，tmux 会话还在。

### 关回防火墙端口

照 [第 3 节表里](#3-放行-udp-端口)「以后关回去」那一列做，云服务器安全组里那条 UDP 规则也删掉。不关也不会出错，
只是服务器对外多开着一段没人用的端口。

### 手机上卸 Mosh 插件

1. 只是不想让它再被用到：「设置 → 插件（实验）→ shun Mosh」点「停用」（以后点「启用」就恢复）或「撤销批准」（要再用得重新核对）。
2. 彻底卸掉：在手机「设置 → 应用」里找到「shun Mosh」卸载。本 App 的插件页会把它标成「已卸载」。

卸掉以后，还是 Mosh 的主机连接时会报「没有装 Mosh 插件」，不会去连服务器；主机的设置都还在，改成 SSH 就能连。
以后装回同一张证书签的插件，直接恢复可用，不用重新批准。

插件自己不存会话以外的东西：每次会话的一次性密钥用完就清掉了，卸掉以后手机上不留下什么要清的。

## 10. 实测范围

**测过的**（2026-10-17，Android 11 模拟器，arm64；装了真 Mosh 插件 shun Mosh 0.1.0，里面是官方 mosh-client 1.4.0；
服务器是本机 Docker 测试环境里的真 OpenSSH、mosh-server 1.4.0、tmux 3.5a）。全部从界面上点：

- tmux 标签 SSH → Mosh 原地切换，几轮里用了 0.5–1.0 秒；Mosh → SSH 用了 1.0–1.4 秒（要重新登录，第一次会弹指纹核对）。
  切了一个来回，tmux 会话的编号和创建时间都没变，会话里的程序一个字节都没收到；服务器上的 tmux 客户端从 sshd 那一侧换到
  mosh-server 那一侧，又换回来；切回 SSH 以后，服务器上的 mosh-server 跟着退出。
- 普通标签两个方向都是另开一个，原来的标签还连着；「设为默认」只改了主机的协议，Mosh 端口设置还在。
- 普通 Mosh 标签里 `exit` 以后点「重新连接」：服务器上新起了一个 mosh-server，新标签还在原来的位置。关掉普通 Mosh 标签，
  约 0.5 秒后服务器上它的 mosh-server 退出。
- Mosh-tmux 标签被服务器那边分离以后，点「重新连接」附着回同一个会话。服务器上把会话删掉、建一个同名的新会话，再点「重新连接」：
  不附着、不新建，也没起 mosh-server。
- 服务器没装 mosh-server（Alpine）：提示里是 `sudo apk add mosh`、卸载 `sudo apk del mosh`、放行 `UDP 60101–60108`（测试主机填的范围）。
  「安装…」点「取消」时服务器上 0 次安装；确认以后正好执行了 1 次 `sudo apk add mosh`。
- 经 SOCKS5 代理的主机：「用 Mosh 另开一个」变灰，写着「Mosh 只能直连…」，点了什么都不发。

**没测的**：

- 真手机。
- 手机换网络、锁屏、App 在后台时，Mosh 会话能不能接着用——这正是 Mosh 最该派上用场的地方，还没测，所以这份指南对它不做任何保证。
- 真的在服务器上装完 mosh 再连：测试环境里的 `sudo` 是记账脚本，只记一笔就返回失败，只证明了命令被原样执行一次。
- Alpine 以外的发行版：安装、卸载命令只核对了命令表，没在那些系统上执行过。
