# 05 Tailscale设备发现与SSH认证

## 三件不同的事情

目录API返回设备；外部TailSocks/系统已有路由负责到达；SSH独立认证。API token不能入网，节点auth key不是设备列表API token，SSH私钥也不是这两者。TermRover可参考导入交互，不复制其“API key天然只读”表述；官方提供更细的trust credential scope。[S23](13-sources.md#s23) [S25](13-sources.md#s25) [S27](13-sources.md#s27)

## 首版目录授权

**低风险入口**：用户提供具有设备读取权限的短期access token，完成列表读取/导入后可以删除；本地目录与主机仍可使用。App不能仅凭token前缀判断权限，scope无法确认时显示“范围未验证”，不能伪报只读。

**可选持续刷新**：高级设置允许用户配置自己创建、限定为 `devices:core:read` 的OAuth client ID/secret。仅保存到本机独立安全存储，用官方client_credentials endpoint换取短期token，按实际expires_in与安全余量续期。不是把开发者共享client secret打进APK，也不是宣称已经实现“用Tailscale登录第三方App”的PKCE流程。创建该凭据需要相应Tailnet管理角色。[S23](13-sources.md#s23) [S24](13-sources.md#s24)

客户端持有用户自有secret仍有设备被攻陷的风险；默认导入后不保留secret，用户显式启用持续刷新才持久化。泄露后在Tailscale撤销原client；仅从App删除副本不等于上游撤销。普通全权限API token不作为推荐设置，首版不提供长期保存该类token的快捷入口。无管理权限可手动输入或导入用户提供的最小设备清单，不索要管理员账号。

## 网络与API边界

生产仅允许官方 `https://api.tailscale.com` 的设备GET与token endpoint；不允许从导入JSON改写认证服务器，不跟随跨origin携带Authorization的重定向。API请求走系统网络并遵守现有VPN，不自动使用某个SSH主机的SOCKS profile。token不进入SSH握手或SOCKS密码字段。

设备端点语义为 `GET /api/v2/tailnet/{tailnet}/devices`；精确schema、字段选项和分页方式见下方「R11 固定的官方口径」，不发明cursor参数，也不请求只在 `fields=all` 才有的 sshEnabled。tailnet作为单个path segment编码；`-`等别名在本地以catalogId隔离，获得明确canonical ID后才合并来源。429尊重Retry-After，401一次受控刷新后要求用户；没有无限轮询或后台保活。

## R11 固定的官方口径（2026-09-29）

**来源**：api.tailscale.com 自带的 OpenAPI（`https://api.tailscale.com/api/v2?outputOpenapiSchema=true`，`openapi: 3.1.0`，`info.version: v2`）。
官方在规范里写明它 unstable、可能不经通知变化，且没有日期字段，所以只能按内容固定：sha256 `b416d98eaf58a5e2b974a8c9424f1f33849866eb45344ecba59e95d6140a742d`（246351 字节，2026-09-29 下载；响应 ETag 即此 sha256）。
原件存在仓库外 `../.toolchain/artifacts/tailscale-openapi-b416d98e.yaml`。重新下载后 sha256 变了，就是官方改了规范，要重新核对下面各条。来源 [S61](13-sources.md#s61)，另参考 [S23](13-sources.md#s23) [S24](13-sources.md#s24) [S62](13-sources.md#s62)。

| 项 | 官方口径 | R11 的做法 |
|---|---|---|
| 换 token | `https://api.tailscale.com/api/v2/oauth/token`，「符合 OAuth 2.0 client credentials」；官方示例只用 `-d client_id -d client_secret`；可选 `scope`、`tags`（空格分隔）。有效期固定 1 小时 | POST 表单：`grant_type=client_credentials`（RFC 6749 §4.4.2 必填项）、client_id、client_secret、`scope=devices:core:read`；按实际 `expires_in` 续期，留 10%（至少 60 秒）余量；缺 `expires_in` 按 5 分钟算 |
| 换 token 失败 | **官方未写**。假凭据实测：`401 {"message":"API token invalid"}`，不是 RFC 的 `error` 字段 | 401 → 要求重新授权；其余按通用状态码处理 |
| scope | `devices:core:read` 只放行列设备、读单个设备；`devices:read` 是 2024-11-14 前的旧名，旧凭据仍有效。OAuth client 现归入 trust credentials | 只请求 `devices:core:read`；返回 scope 全是这两个才算「只读设备」，带任何非 `:read` scope 直接丢弃 token |
| 列设备 | `GET /tailnet/{tailnet}/devices`；`-` 表示凭据所属 tailnet（官方推荐）；参数 `fields=default|all` 和 `<字段>=<值>` 精确过滤 | 只发默认字段集，不带任何查询参数；tailnet 作为单个路径段，含 `/`、空白、控制字符的在发请求前拒绝 |
| 分页 | 「does not currently support pagination. All results are returned at once」 | 一个结构完整的响应就是整个 tailnet；不发明 cursor |
| 响应 | 顶层 `{"devices":[…]}`；Device schema **没有 required**，默认字段 23 个 | 只留 id、nodeId、name、hostname、addresses、os、user、tags、lastSeen、connectedToControl、authorized、isExternal、keyExpiryDisabled、expires、blocksIncomingConnections；缺字段或类型不对记为不知道 |
| SSH 字段 | `sshEnabled` 存在，但**只在 `fields=all`** 返回，含义是「Tailscale SSH 已启用」 | 不请求（`all` 还会带回含公网端点的 clientConnectivity、含序列号的 postureIdentity）；SSH 能力一律「尚未验证」 |
| 错误 | 错误体 `{"message": "..."}`；403/404/429 只有一句通用说明；**401 在规范里没出现**（实测无 token、假 token 都是 401） | 403/404/429/5xx 不重试；报错里附服务器 message（截短、抹掉凭据原文） |
| 429 | **官方未说是否带 Retry-After**，规范里没有任何响应头定义 | 有就带回（秒或 HTTP 日期），没有就是未知；不自动重试 |
| 重定向 | **官方未写**。实测 `http://` 会被 302 到 https | 一律不跟随（307/308 会把带 client secret 的 POST 原样重发） |
| key 前缀 | `tskey-api-`（API access token）、`tskey-client-`（OAuth client secret）；OAuth 换来的 token 前缀未见明确说明 | 不按前缀判断权限：粘贴的 token 一律「范围未验证」 |
| 已知缺陷 | 官方 issue tailscale#16911 [S63](13-sources.md#s63)：OAuth client 换来的 token 看不到共享进来的外部设备，普通 API token 能看到 | 目录可能比普通 token 读到的少；R12/R13 在界面上说明，不当作设备被删 |

## 缓存与导入

source key使用 `(catalogId, deviceId)`，不是hostname/IP。保存provider拥有的name/addresses/os/lastSeen等和用户覆写的label/username/port/identity/route为两组字段。schema缺字段则UNKNOWN；不能通过lastSeen“很近”推断在线，更不能推断SSH开放。

IP/FQDN均来自当前设备记录或用户覆写。初始可优先IPv4减少MagicDNS依赖，IPv6和FQDN可显式选择；任何地址失败都不能改为系统Direct。地址变化要重新做目标身份验证，设备id不能自动授权新host key。

刷新仅更新provider字段；目标编辑、认证方式、排序、route和known_hosts不被覆盖。删除/缺失设备只标missing，用户选择断开来源或删除；分页不完整、响应损坏和空快照不能触发批量删除。缓存和导出不含token/client secret，不保存全部不需要的管理数据。

R12 落地时定下的两条细则：空快照（合法的 0 台设备）也**不**把已有设备标 missing——和 tailscale#16911（OAuth token 看不到共享设备）叠加时，「这次没看到」太容易被误读成「删掉了」；主机地址只在仍等于上次由目录写入的值时才跟随刷新，用户改过就不再跟随。缓存格式升级后装回旧版，旧版不读、不改名、不覆盖新格式文件。实现与验证见 evidence/R12.md。

## 连接入口

选择若干设备 → 应用一个已有路由profile，例如“TailSocks-本机” → 填用户名/默认SSH身份 → 保存 → 正常连接。用户也可使用当前官方Tailscale VPN下的Direct，App不启动/切换它；远程SOCKS必须实际能到达这些设备，导入不创造连通性。

R13 落地时定下的细则：用户名必填、不默认 root；批量导入不填密码（导入后逐台在编辑器填）；已导入过的设备跳过，已有主机（含手动建的）一台不改；路线用和连接时同一个检查，设置本身不成立整批拒绝、只和某台地址有关的只跳过那台。手机端没有新建代理配置的入口，导入页提供和编辑器同样的「自定义代理」。界面上设备只说 Tailscale 控制面「已连接 / 未连接 / 不知道」，不说在线。实现与验证见 evidence/R13.md。

## 普通SSH与Tailscale SSH

普通SSH是默认：支持已验证的key/password/keyboard-interactive，并保持host key检查。Tailscale SSH设置为单独明确的“Tailnet外部身份认证”，不因为100.x地址或导入标记自动启用。

在此模式中，实际源节点是承载连接的TailSocks节点或远程代理之后的节点；不是目录API账号，也不一定是官方Tailscale手机节点。必须满足网络策略和SSH策略；尤其共享远程SOCKS服务会改变身份边界。[S26](13-sources.md#s26)

R14需核对**锁定版本**dartssh2的none认证和banner回调；master源码的同名API不能直接视为所选版本可用。明确外部认证时不提供SSH密码/私钥，不能对所有prompt自动填密码。普通认证若库自动落到none，应用仍需可检测的策略保证；必要时做小型、可上游提交的依赖补丁，禁止伪造SDK参数。[S31](13-sources.md#s31)

check授权链接只从已验证SSH主机的受控banner获取；显示原host、域名和用途，用户点击后用外部浏览器，不自动访问或截图/记录含token链接。仅允许HTTPS和固定批准的认证域名，未知域名不自动放行。浏览器回来不等于授权成功，仍以SSH认证结果为准。等待可取消、有单独截止；不能重放用户命令。

设备列表未提供可验证SSH能力字段时显示“尚未验证”，不伪造绿色SSH badge。R14失败不会阻止普通SSH目录导入的中间产物，但完整计划不能声称Tailscale SSH/check已支持。

## R14 固定的口径（2026-10-01）

**服务器端怎么认证**（tailscale v1.104.0 `c8125a97`，`ssh/tailssh/tailssh.go` 的 `ServerConfig` 和 `clientAuth`；v1.102.5 这两处相同）：
none、密码、公钥三种请求都进同一个 `clientAuth`，**密码和公钥的内容一概不看**，按 tailnet 策略放行；版本行 `SSH-2.0-Tailscale`。
check（HoldAndDelegate）：先发一条 USERAUTH_BANNER（文字由控制面给），再把这次认证请求挂住，最长 30 分钟向控制面长轮询；
批准回 USERAUTH_SUCCESS，拒绝或超时发一条 banner（`tailscale: access denied` / `tailscale: failed to fetch next SSH action`）后返回空的
PartialSuccessError——x/crypto v0.57.0 收到它**不发 USERAUTH_FAILURE，直接断 TCP**，客户端只看到连接被关。
官方 check banner 的文字只在官方文档截图里：`# Tailscale SSH requires an additional check.` / `# To authenticate, visit: https://login.tailscale.com/a/<id>`，
用户报告里的 id 是 12 位十六进制（tailscale#7589）。来源整理见 13-sources.md 之外的 evidence/R14.md。

**锁定的 dartssh2 2.22.5**：`_startAuthentication` 在私钥、密码、键盘交互之后**总会追加 none**，没有开关；`onUserauthBanner` 在任何阶段收到都回调，
包括指纹还没确认的时候；认证请求在指纹确认后才发。

| 项 | R14 的做法 |
|---|---|
| 登录方式 | 主机上 `xwshunSshLogin: tailscale` 才算 Tailscale SSH，不动桌面端也读写的 `authMethod`；不看 100.x、不看目录绑定 |
| Tailscale 模式发什么 | 不给 dartssh2 私钥、密码、键盘交互回调，它就只剩 none；私钥连解密都不解 |
| 普通模式的 none | 借 dartssh2 的调试回调认出「要发 none 了」，登录成功后若是 none 就断开、不执行任何东西（依赖调试文字 `SSHClient._authWithNone`，升级 dartssh2 时对应测试会红）。不打补丁、不 vendor |
| 普通模式碰上带链接的 banner | 立刻断开，提示改成 Tailscale SSH；不显示链接，不挂 30 分钟 |
| banner 与指纹 | 指纹确认前到的 banner 一律丢弃 |
| check 链接 | 只认 `https://login.tailscale.com/a/<1–128 位字母数字>`，单条、无账号、无别的端口、无 query/fragment；带链接的 banner 里出现控制字符或改写方向的字符直接拒（不替它删掉再放行）。不合规的照样提示「不打开」并写原因和域名 |
| 期限 | Tailscale 模式不用 dartssh2 的 authTimeout；从指纹确认后按主机的「认证超时」算，收到 check 链接后换成 10 分钟。到点关连接 |
| 拒绝的说法 | Tailscale 模式下认证阶段断开 = 「Tailscale 拒绝了」，附最后一条无链接 banner；没有 banner 时说「可能被拒，也可能是网络」 |
| 自动恢复 | 碰上 check 就停，标签标记为不再自动重试（docs/07：外部 check 必须人工处理） |
| 来源节点 | 直连 = 手机的 Tailscale 节点；经代理 = 代理出口那台节点；经跳板 = 上一跳所在节点。编辑器和 check 卡片都写出来，并说明目录凭据不参与 SSH |
| 自建控制面 | Headscale 的链接（`http://…/auth/hskey-authreq-…`）不在白名单，不打开；用户可在控制面命令行批准，App 等到截止时间 |

已知且不处理的：普通模式带密码连 Tailscale SSH 的 22 端口，tailscaled 收下密码不看内容照样放行（真 tailscaled 上实测，填错密码也能进）。
App 分不出这次是密码起了作用还是 tailnet 身份；是否在普通模式下对 `SSH-2.0-Tailscale` 额外提示或拒绝，留给所有者定（STATUS）。
实现与验证见 evidence/R14.md。

## R15 能力支持矩阵（2026-10-01 实测）

同一台目录设备（ts-server，`tag:server`，22 是 Tailscale SSH、2222 是普通 OpenSSH）从目录导入成一台主机，只改路线和登录方式，
在 arm64 模拟器（API 35）上用正式代码连。控制面是 Headscale 0.29.4，节点都是官方 tailscaled v1.102.5，目录 API 是假的。
**没有官方 Tailscale、没有真机、没有真的 TailSocks App**；下表「通」都只到这一层。测试环境见 `tool/tailscale-ssh-fixture/README.md`「R15」一节，过程见 evidence/R15.md。

| 路线 | 手机实际拨到 | Tailscale 认的来源 | 普通 SSH | Tailscale SSH（accept） | Tailscale SSH（check） | 本次怎么扮演 |
|---|---|---|---|---|---|---|
| 直连 | 目标的 100.x | 手机上官方 Tailscale App 的节点 | NOT_RUN | NOT_RUN | NOT_RUN | 模拟器里没有 Tailscale 的 VPN；开发机本身在真实 tailnet 上，测试里禁止直拨 100.x |
| 本地 SOCKS | 手机上的 SOCKS 端口 | 提供 SOCKS 的那个节点（TailSocks 登录的节点） | 通 | 通，审计 `from=ts-socks` | 批准后通，来源写「代理出口所在的节点」 | userspace tailscaled 自带的 SOCKS5（无认证） |
| 远程 SOCKS | 远程代理的端口 | 代理那台机器的节点 | 通 | **被拒**：「Tailscale 拒绝了这次登录，服务器说：tailscale: tailnet policy does not permit you to SSH to this node」 | 没测 | `tag:relay` 节点上的 dante（要口令）。ssh 规则只放行用户 fixture 的设备，打了 tag 的共享代理不算这个用户 |
| 跳板机 | 跳板机 | 跳板机的节点 | 通 | 通，审计 `from=ts-jump` | 批准后通，来源写「跳板机“bastion”所在的节点」 | 用户 fixture 自己的设备，内核模式 tailscaled + OpenSSH |
| 代理入口 + 跳板 | 本地 SOCKS | 跳板机的节点（不是 SOCKS 那台） | 通 | 通，审计 `from=ts-jump` | 没测 | 本地 SOCKS → ts-jump 的 100.x:22 → ts-server |

结论：**Tailscale SSH 认的是最后把连接送进目标的那个节点**，换路线就换了身份；目录用的 token、OAuth client 从头到尾没进过 SSH 和代理的连接。
同一个主机、同样的用户名，经本地 SOCKS 能进、经共享的远程 SOCKS 被拒——这是策略按来源节点判，不是 App 的问题，App 的提示直接指向 ssh 规则和来源节点。
普通 OpenSSH 只认密码，哪条路线都一样；经 userspace tailscaled 转进来的连接，目标上看到的来源是 127.0.0.1。

**目录这一层和连接互不影响：**

| 情况 | 目录页 | 主机 | 连接 |
|---|---|---|---|
| 完整列表里没有这台设备 | 不见了 | 不删、不改 | 照常连上 |
| 设备「未连接控制面」 | 未连接 | 不改 | 照常连上 |
| API 回 401（受控刷新一次仍 401）、403、429、500、坏 JSON、302 | 最近一次失败 + 原因；302 不跟随 | 一字不差 | 不受影响 |
| API 整个停掉 | 连不上 Tailscale API | 一字不差 | 经本地 SOCKS、经跳板（Tailscale SSH）都照常连上 |
| 刷新目录 | — | 路线、用户名、登录方式、密码一字不差 | — |

**连不上时分得清是哪一层**（每一条都带「哪台机器、第几跳、哪一步」和各自不同的下一步提示）：

| 层 | 实测的情况 | App 报的（节选） |
|---|---|---|
| 路线配置 | 跳板机不在保险库 | 找不到跳板机（一次都没拨号） |
| 手机到入口 | 代理端口没人听 | 经代理连接失败：Connection refused |
| 代理 | 口令错 / 目标端口没开 / 代理那边连不到的名字 | SOCKS5 代理认证失败 / 代理内部错误（状态码 1）/ 规则不允许连接这个目标（状态码 2） |
| 跳板转发 | 跳板机连不到目标端口 | 跳板机“bastion”转发失败（到 100.x:2299）：对方拒绝打开转发通道（Connection refused） |
| 指纹 | 指纹对不上 | 主机指纹没有通过校验，已在发送任何登录信息之前断开 |
| 登录 | 跳板机密码错 / 目标密码错 | 第 1 跳 / 第 2 跳：登录被拒绝 |
| Tailscale 策略 | 经共享远程 SOCKS 用 Tailscale SSH | Tailscale 拒绝了这次登录（见上表） |

R15 时改的一处：经代理或跳板机到达的一跳，「连上后在登录前被关」原来只提示「这个端口上可能不是 SSH」，
现在同时说明「也可能是代理或跳板机之后那一段断了，App 看不到」（测试环境里路径抖动时真碰上过，旧提示会把人引去查端口）。
直连时提示不变。

**不启动第二个 VPN**：App 的清单里没有 `BIND_VPN_SERVICE`、没有 VpnService，代码里不调任何 VPN 接口；模拟器上测试前后系统里的 VPN 网络都是 0 个。
「真机保持已有 VPN、再开 TailSocks 非 VPN 模式」（NET12）要真机和真的 TailSocks，仍是 NOT_RUN。

测试环境碰到的、和 App 无关的事（写在这里免得被当成 App 的行为）：开发机开着 fake-ip 类代理，容器里解析任何名字都得到 198.18.x，
所以「代理连不到的名字」在 dante 上表现为规则拒绝（状态码 2），正常环境下应是解析失败；
tailscaled 的 SOCKS 连 tailnet 以外的名字会走开发机网络，被 fake-ip 代理接下再断开，看着像 SSH 阶段的问题，所以测试不走这条。

## V3 provider归属

首版实现内置DeviceCatalogProvider（插件体系中的bundled provider），不再为目录功能另装APK。控制面凭据局限该provider的私有存储/Host HTTP适配；Mosh和远控插件无权读取。目录节点与UU匿名ID、RustDesk peer ID只允许用户关联，任何一个provider刷新/失效不得覆盖另一个provider或SSH身份。

X05 落地时定下的细则：provider ID 是 `builtin.tailscale`，路线只声明 system-default。设备引用是（来源 ID:设备 ID），来源 ID 和缓存文件名、凭据键、主机上的绑定是同一个值、同一条规则。SSH 主机 ↔ 目录设备的关联就是主机上的目录绑定，不另存。用户手动关联的主机不写 appliedAddress，所以地址永远不跟随目录。来源被移除后按原来源 ID 在本机恢复，是用户的明确操作，不算自动合并来源（TSC10 不变）。实现与验证见 evidence/X05.md。
