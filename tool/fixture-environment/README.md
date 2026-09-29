# 测试用 SSH / SOCKS 拓扑

给网络相关测试提供真实 OpenSSH 和 SOCKS5，全部跑在本机 Docker 里，端口只绑 127.0.0.1。

```bash
./up.sh          # 启动，并生成 .run/fixture.json（连接参数和临时凭据）
./selfcheck.sh   # 用系统 ssh/curl 验证拓扑本身成立，8 项应全部 PASS
./down.sh        # 停止并删除全部临时凭据
```

需要 Docker（本机用的是 OrbStack）。第一次 `up.sh` 会构建 alpine 镜像，要能访问 Docker Hub 和 Alpine 源。

## 拓扑

| 节点 | 本机能否直连 | 用途 |
|---|---|---|
| ssh-edge | `127.0.0.1:22201` | 第一跳 / 普通直连目标 |
| socks | `127.0.0.1:21080`（要用户名密码）、`127.0.0.1:21081`（无认证） | 外部 SOCKS5，只放行 CONNECT |
| target | 不能，名字 `target.fixture.internal` 只有容器网络里能解析 | 只能经代理或跳板到达的最终目标 |
| ssh-hop2 | 不能，名字 `hop2.fixture.internal` | 多跳的第二跳 |
| ssh-hop3 | 不能，名字 `hop3.fixture.internal` | 多跳的第三跳（测"三个跳板 + 目标"） |

SSH 用户 `fixture`，密码和客户端私钥每次 `up.sh` 重新生成；四台 sshd 的主机密钥也每次重新生成，所以**每次 up 之后指纹都会变**——测"指纹改变必须阻断"时直接利用这一点。

## 撞墙时

- **selfcheck 里 SOCKS 相关项全挂**：看 `docker compose logs socks`。dante 规则块必须多行写，单行会报 `syntax error near token "l"`。
- **本机能解析 `target.fixture.internal`**：说明本机开着 fake-ip 类代理（如 Clash TUN，所有名字都解析到 `198.18.x.x`）。这不影响 fixture，但意味着测试**不能靠"DNS 解析失败"证明没有本地解析**，必须用 App 的可注入拨号器记录实际连接端点。
- **curl 验证 SOCKS 时别用 `--noproxy '*'`**：它会把 SOCKS 也一起禁掉，curl 变直连，"错口令被拒"会因为错误的原因通过。
- **手工 ssh 时认证失败，日志里的密钥指纹不是 fixture 的**：本机 `~/.ssh/config` 或 ssh-agent 的真实密钥掺进来了。加 `-F /dev/null -o IdentityAgent=none -o IdentitiesOnly=yes`。
- **嵌套 ProxyCommand 报"主机身份已改变"**：内层的 `%h:%p` 要写成 `%%h:%%p`，否则外层提前替换，内层跳错机器。
- **跑到一半所有 SSH 都连不上，报「登录完成前连接被对方关闭」，`docker compose logs ssh-edge` 里有 `drop connection ... penalty`**：
  OpenSSH 的来源罚时（PerSourcePenalties）把本机拉黑了。`entrypoint.sh` 里已经关掉；自己改 sshd_config 时别删那一行，改完要 `down.sh` + `up.sh` 重建。

## 安全边界

只绑回环地址；凭据写在 `.run/`（已 gitignore，权限 700/600），`down.sh` 删除。不要把这里的任何配置用到真实主机。
