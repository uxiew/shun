# 05 Tailscale设备发现与SSH认证

## 三件不同的事情

目录API返回设备；外部TailSocks/系统已有路由负责到达；SSH独立认证。API token不能入网，节点auth key不是设备列表API token，SSH私钥也不是这两者。TermRover可参考导入交互，不复制其“API key天然只读”表述；官方提供更细的trust credential scope。[S23](13-sources.md#s23) [S25](13-sources.md#s25) [S27](13-sources.md#s27)

## 首版目录授权

**低风险入口**：用户提供具有设备读取权限的短期access token，完成列表读取/导入后可以删除；本地目录与主机仍可使用。App不能仅凭token前缀判断权限，scope无法确认时显示“范围未验证”，不能伪报只读。

**可选持续刷新**：高级设置允许用户配置自己创建、限定为 `devices:core:read` 的OAuth client ID/secret。仅保存到本机独立安全存储，用官方client_credentials endpoint换取短期token，按实际expires_in与安全余量续期。不是把开发者共享client secret打进APK，也不是宣称已经实现“用Tailscale登录第三方App”的PKCE流程。创建该凭据需要相应Tailnet管理角色。[S23](13-sources.md#s23) [S24](13-sources.md#s24)

客户端持有用户自有secret仍有设备被攻陷的风险；默认导入后不保留secret，用户显式启用持续刷新才持久化。泄露后在Tailscale撤销原client；仅从App删除副本不等于上游撤销。普通全权限API token不作为推荐设置，首版不提供长期保存该类token的快捷入口。无管理权限可手动输入或导入用户提供的最小设备清单，不索要管理员账号。

## 网络与API边界

生产仅允许官方 `https://api.tailscale.com` 的设备GET与token endpoint；不允许从导入JSON改写认证服务器，不跟随跨origin携带Authorization的重定向。API请求走系统网络并遵守现有VPN，不自动使用某个SSH主机的SOCKS profile。token不进入SSH握手或SOCKS密码字段。

设备端点语义为 `GET /api/v2/tailnet/{tailnet}/devices`；精确schema、字段选项和分页方式在R11固定官方版本后记录，不发明cursor参数或sshEnabled字段。tailnet作为单个path segment编码；`-`等别名在本地以catalogId隔离，获得明确canonical ID后才合并来源。429尊重Retry-After，401一次受控刷新后要求用户；没有无限轮询或后台保活。

## 缓存与导入

source key使用 `(catalogId, deviceId)`，不是hostname/IP。保存provider拥有的name/addresses/os/lastSeen等和用户覆写的label/username/port/identity/route为两组字段。schema缺字段则UNKNOWN；不能通过lastSeen“很近”推断在线，更不能推断SSH开放。

IP/FQDN均来自当前设备记录或用户覆写。初始可优先IPv4减少MagicDNS依赖，IPv6和FQDN可显式选择；任何地址失败都不能改为系统Direct。地址变化要重新做目标身份验证，设备id不能自动授权新host key。

刷新仅更新provider字段；目标编辑、认证方式、排序、route和known_hosts不被覆盖。删除/缺失设备只标missing，用户选择断开来源或删除；分页不完整、响应损坏和空快照不能触发批量删除。缓存和导出不含token/client secret，不保存全部不需要的管理数据。

## 连接入口

选择若干设备 → 应用一个已有路由profile，例如“TailSocks-本机” → 填用户名/默认SSH身份 → 保存 → 正常连接。用户也可使用当前官方Tailscale VPN下的Direct，App不启动/切换它；远程SOCKS必须实际能到达这些设备，导入不创造连通性。

## 普通SSH与Tailscale SSH

普通SSH是默认：支持已验证的key/password/keyboard-interactive，并保持host key检查。Tailscale SSH设置为单独明确的“Tailnet外部身份认证”，不因为100.x地址或导入标记自动启用。

在此模式中，实际源节点是承载连接的TailSocks节点或远程代理之后的节点；不是目录API账号，也不一定是官方Tailscale手机节点。必须满足网络策略和SSH策略；尤其共享远程SOCKS服务会改变身份边界。[S26](13-sources.md#s26)

R14需核对**锁定版本**dartssh2的none认证和banner回调；master源码的同名API不能直接视为所选版本可用。明确外部认证时不提供SSH密码/私钥，不能对所有prompt自动填密码。普通认证若库自动落到none，应用仍需可检测的策略保证；必要时做小型、可上游提交的依赖补丁，禁止伪造SDK参数。[S31](13-sources.md#s31)

check授权链接只从已验证SSH主机的受控banner获取；显示原host、域名和用途，用户点击后用外部浏览器，不自动访问或截图/记录含token链接。仅允许HTTPS和固定批准的认证域名，未知域名不自动放行。浏览器回来不等于授权成功，仍以SSH认证结果为准。等待可取消、有单独截止；不能重放用户命令。

设备列表未提供可验证SSH能力字段时显示“尚未验证”，不伪造绿色SSH badge。R14失败不会阻止普通SSH目录导入的中间产物，但完整计划不能声称Tailscale SSH/check已支持。

## V3 provider归属

首版实现内置DeviceCatalogProvider（插件体系中的bundled provider），不再为目录功能另装APK。控制面凭据局限该provider的私有存储/Host HTTP适配；Mosh和远控插件无权读取。目录节点与UU匿名ID、RustDesk peer ID只允许用户关联，任何一个provider刷新/失效不得覆盖另一个provider或SSH身份。
