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

## V3 provider归属

首版实现内置DeviceCatalogProvider（插件体系中的bundled provider），不再为目录功能另装APK。控制面凭据局限该provider的私有存储/Host HTTP适配；Mosh和远控插件无权读取。目录节点与UU匿名ID、RustDesk peer ID只允许用户关联，任何一个provider刷新/失效不得覆盖另一个provider或SSH身份。

X05 落地时定下的细则：provider ID 是 `builtin.tailscale`，路线只声明 system-default。设备引用是（来源 ID:设备 ID），来源 ID 和缓存文件名、凭据键、主机上的绑定是同一个值、同一条规则。SSH 主机 ↔ 目录设备的关联就是主机上的目录绑定，不另存。用户手动关联的主机不写 appliedAddress，所以地址永远不跟随目录。来源被移除后按原来源 ID 在本机恢复，是用户的明确操作，不算自动合并来源（TSC10 不变）。实现与验证见 evidence/X05.md。
