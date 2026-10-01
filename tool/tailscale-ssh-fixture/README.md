# 仿 Tailscale SSH 认证的本机服务器（R14 测试用）

**它不是 Tailscale。** 它只照着 tailscale v1.104.0（`c8125a97`）`ssh/tailssh/tailssh.go` 的认证回调结构写，
SSH 库用和 tailscale 同一个版本的 `golang.org/x/crypto v0.57.0`（go.sum 校验和逐字一致）。
所以「客户端发 none / 密码 / 公钥时服务器怎么回、check 时 banner 和挂起怎么发、拒绝时怎么断」是同一个库跑出来的；
策略和 check 的批准换成了本机 HTTP 开关，登录后的 shell 是假的（只会 `tty`、`whoami`、`exit`）。

## 怎么用

```bash
cd tool/tailscale-ssh-fixture
export GOPATH=$PWD/../../../.toolchain/go GOMODCACHE=$PWD/../../../.toolchain/go/pkg/mod \
       GOCACHE=$PWD/../../../.toolchain/go/cache GOTOOLCHAIN=local GOFLAGS=-modcacherw
go build -o .run/tailssh-fixture .
./.run/tailssh-fixture -state .run/state.json     # 前台运行，每个事件打一行 JSON
```

启动后第一行打印 `{"sshPort":…,"controlPort":…,"fingerprintSha256":"SHA256:…"}`，同样写进 `.run/state.json`。
主机密钥默认每次启动重新生成，**指纹每次都变**；要测「断线后自动恢复」时加 `-hostkey .run/hostkey.pem`，
同一个文件就是同一把密钥（换了指纹会被 App 的指纹阻断拦下，走不到登录那一步）。
两个端口都只绑 127.0.0.1（参数写别的地址会直接退出）。默认端口随机，模拟器上用固定的方便：`-listen 127.0.0.1:22401 -control 127.0.0.1:22402`。

`flutter test test/tailscale_ssh_login_test.dart` 会自己构建、启动、关闭它；没装 Go 时这组测试 skip，证据记 NOT_RUN。
Go 的依赖缓存放在仓库外 `../.toolchain/go`，不碰 `~/go`。第一次构建要能访问 proxy.golang.org。

模拟器里连：`adb -s emulator-5580 reverse tcp:22401 tcp:22401`，App 里主机地址填 `127.0.0.1`、端口 22401。

## 用户名选场景

| 用户名 | 服务器怎么做 |
|---|---|
| `accept` | 任何方法（none、密码、公钥）都直接放行，密码和公钥内容不看——真实 tailssh 就是这样 |
| `reject` | 发 banner `tailscale: tailnet policy does not permit you to SSH to this node`，然后断 TCP |
| `check` | 发 check banner（链接 `https://login.tailscale.com/a/<12 位十六进制>`），挂起这次认证，等控制面裁决 |
| `evil-domain` `evil-http` `evil-two` `evil-intent` `evil-userinfo` `evil-path` `evil-bidi` `evil-port` | 和 check 一样挂起，但 banner 里的链接是各种坏样子（见 main.go 的 `evilLinks`） |
| `headscale` | 链接换成 Headscale 的格式（`http://…/auth/hskey-authreq-…`） |
| 其他 | 当成策略不允许这个用户名，发 banner 后断开 |

check banner 的文字取自 Tailscale 官方文档截图和用户报告（真实文字由 Tailscale 控制面决定，客户端源码里没有）：

```
# Tailscale SSH requires an additional check.
# To authenticate, visit: https://login.tailscale.com/a/…
```

批准后再发 `# Authentication checked with Tailscale SSH.` 两行；拒绝发 `tailscale: access denied`（没有换行）；
挂起超过 `-hold-limit`（默认 30 分钟，和 tailssh 一样）发 `tailscale: failed to fetch next SSH action`。

## 控制面（模拟「用户在浏览器里点了批准」）

```bash
C=$(python3 -c "import json;print(json.load(open('.run/state.json'))['controlPort'])")
curl -s --noproxy '*' http://127.0.0.1:$C/checks                      # 挂着的 check
curl -s --noproxy '*' -X POST http://127.0.0.1:$C/checks/<id>/approve  # 或 /deny
curl -s --noproxy '*' http://127.0.0.1:$C/events                      # 每次认证用了什么方法、收到的密码长度、发过的 banner
```

事件里只记密码**长度**和公钥指纹，用来证明客户端发没发，不记密码本身。

## 撞墙时

- **客户端说「认证前连接被关闭」，服务器日志是 `ssh: no authentication methods available`**：这就是拒绝的正常样子。
  x/crypto 收到空的 PartialSuccessError 不回「认证失败」，直接断开——真实 Tailscale 也一样，不是 fixture 坏了。
- **取消之后 `/checks` 里还挂着那个 check**：服务器在认证回调里阻塞，客户端断开它感觉不到，要等裁决或 hold-limit 到点。
  真实 tailssh 也是这样（它挂着向控制面长轮询）。
- **curl 控制面没反应**：本机开着代理时要带 `--noproxy '*'`。

## 真 tailscaled（Headscale 控制面）

仿制服务器只能证明「App 对 tailssh 的认证行为怎么反应」。要看**真的 tailscaled** 怎么回，用 `headscale/` 这套：
Headscale 0.29.4（开源的 Tailscale 控制面，支持 SSH 的 accept 和 check）+ 两个官方 `tailscale/tailscale:v1.102.5` 容器。
**这也不是 Tailscale 官方服务**：check 链接是 Headscale 自己的（`http://headscale:8080/auth/hskey-authreq-…`），App 按规矩不给打开，要在命令行批准。

```bash
cd headscale
./up.sh      # 起来后打印两个节点的 100.x 地址；口令和 authkey 在 ../.run/headscale.env（600，down 时删）
adb -s emulator-5580 reverse tcp:21055 tcp:21055
./down.sh    # 删容器（节点状态、Headscale 数据库都在容器里），镜像留着
```

| 节点 | 地址 | 用途 |
|---|---|---|
| ts-socks | 用户 fixture 的设备，userspace tailscaled | 扮演 TailSocks：本机 `127.0.0.1:21055` 是它的 SOCKS5 入口 |
| ts-server | `tag:server`，开了 `--ssh` | 22 = Tailscale SSH；2222 = 普通 OpenSSH（用户 `ordinary`，口令在 `.run/headscale.json`） |

策略（`policy.hujson`）：fixture 的设备以 `acceptuser` 登录直接放行，以 `checkuser` 登录每次都要 check（`checkPeriod: always`）。
App 里主机写 `100.64.0.2`（以 up.sh 打印的为准），连接路径选「经代理」SOCKS5 `127.0.0.1:21055`。

批准 / 拒绝 check：

```bash
export SERVER_AUTHKEY=x SOCKS_AUTHKEY=x ORDINARY_PASSWORD=x   # compose 文件要这几个变量，命令行操作时随便填
ID=$(docker compose logs --since 60s headscale | grep -o "hskey-authreq-[A-Za-z0-9_-]*" | tail -1)
docker compose exec -T headscale headscale auth approve --auth-id $ID    # 或 reject
docker compose logs ts-server | grep "audit: SSH login"                   # tailscaled 认的是谁：from=…  node=ts-socks…
```

隔离：Headscale 和 ts-server 在没有外网的容器网络里；ts-socks 多接一个普通网络只为把 SOCKS 端口映射到本机回环。
tailscaled 带 `--no-logs-no-support`（不往 log.tailscale.com 报日志），DERP 表只有一个解析不到的占位节点，
`log/controlplane/login/pkgs.tailscale.com` 在容器里都指向 127.0.0.1。不连任何真实账号。

### 撞墙时

- **App 经代理连 100.x 报「SOCKS5 代理内部错误（状态码 1）」，过一会儿重试又好了**：没有可用的 DERP 中继，两个节点空闲一会儿后直连路径会失效，
  下一次拨号先失败。compose 里给 ts-socks 加了每 10 秒一次的 `tailscale ping` 保温，还碰到就再连一次。这是这套拓扑的毛病，不是 App 的。
- **单独重建某个节点容器后它起不来，日志 `authkey already used`**：节点状态在容器里，重建就丢了。up.sh 发的 authkey 是可复用的（2 小时内），
  更早的一次性 key 不行，重新跑 `./down.sh && ./up.sh`。重建后节点会换一个 100.x 地址，旧节点在 Headscale 里留着，用 `headscale nodes delete -i <id> --force` 删掉。
- **Headscale 起不来，`initial DERPMap is empty`**：0.29 要求 DERP 表至少一个条目，见 `derp.yaml`。
- **ts-server 起不来，`requested tags [tag:server] are invalid or not permitted`**：别再加 `--advertise-tags`，tag 已经由 authkey 带上了。
- **22 和 2222 的指纹一样**：Tailscale SSH 沿用了系统 `/etc/ssh` 的主机密钥，不是串了。
- **普通 OpenSSH 里 `$SSH_CONNECTION` 显示 127.0.0.1**：userspace 模式的 tailscaled 把进来的连接转给本机端口，来源就成了回环。
  看真实来源节点用 Tailscale SSH 的 `$SSH_CLIENT` 或 ts-server 的 `audit: SSH login` 日志。

