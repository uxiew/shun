# tmux 测试环境（R21）

给 tmux 恢复目标的测试提供真实 OpenSSH + 真实 tmux，全部跑在本机 Docker 里，端口只绑 127.0.0.1。

```bash
./up.sh     # 启动，生成 .run/fixture.json（连接参数和临时凭据），最后打印每台的 tmux 版本
flutter test test/tmux_fixture_test.dart     # 在仓库根目录跑；约 30 秒
./down.sh   # 停止并删除全部临时凭据
```

和 `tool/fixture-environment` 互不相干：项目名、端口、凭据都分开，可以同时开着。**只用这里的 up/down**，
别去跑那边的 `up.sh`——它每次都换密码，别人正在跑的测试会全挂。

## 有哪几台

| 节点 | 端口 | 用途 |
|---|---|---|
| tmux24 | 22311 | Alpine 3.6 的 tmux 2.4（实测支持的最老版本） |
| tmux27 | 22312 | Alpine 3.8 的 tmux 2.7 |
| tmux30 | 22313 | Alpine 3.11 的 tmux 3.0a |
| tmux35 | 22314 | Alpine 3.22 的 tmux 3.5a |
| notmux | 22315 | 删掉了 tmux，测「远端没有 tmux」 |
| faketmux | 22316 | `/usr/bin/tmux` 换成 `fake-tmux.sh`，按 `~/.faketmux` 第一行吐乱码、超长输出、挂住、假版本号 |

每台都有两个 Unix 用户：`fixture`（uid 1000）和 `other`（uid 1001），密码、公钥相同，用来测「换了用户，原来的目标不算数」。
版本是 arm64 上 Alpine 能拿到的；更老的 Alpine（3.4、3.5）没有 arm64 镜像，所以 2.4 以下没有真实版本可测，
「版本太老」那条路用假 tmux 报 `tmux 1.8` 来测。

假 tmux 的模式（测试经 SSH 写 `~/.faketmux`，不用重建容器）：

| 第一行 | 行为 |
|---|---|
| `hang` | 任何调用都 `sleep 600` |
| `version tmux 1.8` | `-V` 报这个版本，其余转给真 tmux |
| `binary` | `-V` 里夹着转义序列和控制字符 |
| `garbage` | 列会话时在真行后面混进坏行、伪造的 server、转义序列、30 万字符的长行 |
| `huge` | 列会话时吐约 20 MB |
| `fail` | 列会话时报 `server exited unexpectedly`、退出码 1 |
| 空或没有这个文件 | 一切转给真 tmux |

## 撞墙时

- **模拟断网**：测试用 `docker compose exec` 以 root 杀掉那条连接的 sshd 进程（按 tmux 客户端的 pid 找父进程）。
  `/proc/PID/stat` 里进程名是 `(tmux: client)`，带空格，按空格数第 4 段拿到的不是父进程号；`test/fixtures/tmux_fixture.dart` 里按最后一个 `) ` 之后取。
- **老版本 busybox 少参数**：Alpine 3.6 的 `pgrep` 没有 `-u`、`cat` 没有 `-v`。测试里记录输入字节用的是 `dd bs=1`。
- **在远端命令里写 `"$0"`**：双引号里的 `$0` 会被 shell 展开成 shell 自己的名字，tmux 收到的不是 `$0` 这个会话编号。会话编号放单引号里。
- **老版本 sshd 不认 `PerSourcePenalties`**（OpenSSH 9.8 起才有）：`entrypoint.sh` 先 `sshd -t` 试一下，不认就删掉那一行。

## 安全边界

只绑回环地址；凭据写在 `.run/`（已 gitignore，权限 700/600），`down.sh` 删除。不要把这里的任何配置用到真实主机。
