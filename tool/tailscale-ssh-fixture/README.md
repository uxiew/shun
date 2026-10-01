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
主机密钥每次启动重新生成，**指纹每次都变**。两个端口都只绑 127.0.0.1（参数写别的地址会直接退出）。

`flutter test test/tailscale_ssh_login_test.dart` 会自己构建、启动、关闭它；没装 Go 时这组测试 skip，证据记 NOT_RUN。
Go 的依赖缓存放在仓库外 `../.toolchain/go`，不碰 `~/go`。第一次构建要能访问 proxy.golang.org。

模拟器里连：主机地址填 `10.0.2.2`、端口填 `sshPort`（模拟器的 10.0.2.2 就是这台 Mac 的 127.0.0.1）。

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
