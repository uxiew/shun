# Mosh 测试环境（X08、X09）

两台容器：`mosh` 是 OpenSSH + Alpine 打包的官方 mosh 1.4.0（服务器和客户端都有）+ tmux；`nomosh` 只有 OpenSSH，
当「服务器上没装 mosh」。账号、密码、客户端密钥两台一样。端口只绑 127.0.0.1。
和 `../fixture-environment` 是两个独立的 compose 项目（`shun-mosh`），起停互不影响。

```bash
./up.sh      # 构建并启动；生成 .run/fixture.json（用户 mosh、临时密码、客户端私钥、两台的主机公钥）
./counts.sh  # 一行 JSON：mosh-server 启动过几次、还在跑几个、有没有人调过 sudo/安装命令、两台各登录成功几次
./down.sh    # 停止并删除全部临时凭据
```

| 端口 | 用途 |
|---|---|
| `127.0.0.1:22301/tcp` | `mosh` 的 SSH（用户 `mosh`），手工 bootstrap 用 |
| `127.0.0.1:60101–60108/udp` | mosh-server 的 UDP；bootstrap 时 `-p 60101:60108` 让它只在这几个端口里挑 |
| `127.0.0.1:22302/tcp` | `nomosh` 的 SSH，同一个账号 |

**记账（X09）**：容器里的 `mosh-server`、`sudo`、`apk`、`apt-get` 等被换成 `shims/` 里的脚本——mosh-server 先记一行
（`/var/log/shun/mosh-server-starts.log`）再交给真的，安装类命令只记一行（`install-attempts.log`）就失败返回。
`counts.sh` 前后各跑一次看差值，就知道一次操作让远端启动了几次 mosh-server、有没有试图安装或 sudo。
`up.sh` 会核对这些脚本确实排在 PATH 前面，不对就拒绝出环境（计数会不可信）。

手工起一个 mosh-server：

```bash
ssh -F /dev/null -o IdentityAgent=none -o IdentitiesOnly=yes -i .run/client/id_ed25519 -p 22301 mosh@127.0.0.1 \
  'mosh-server new -c 256 -l LANG=en_US.UTF-8 -p 60101:60108'
# 输出里的 MOSH CONNECT <端口> <22 字符 key> 就是客户端要的东西。key 是秘密，别贴进日志或证据。
```

## Dart 候选探针（`dart_probe/`）

用 `dart_mosh 0.0.4` 连这里的 mosh-server，和容器里官方 mosh-client 在 tmux 里画出的屏幕逐字比较；
中间可以夹一个本机 UDP 中继做丢包、重复、乱序、篡改、重放、反射。官方客户端也经同一个中继跑同样的反射、丢包和 SIGHUP，
当 native 候选的协议对照（它和插件里的运行时是同一版本源码；插件自己的 Android 构建在设备上另测）。

```bash
./up.sh
cd dart_probe && flutter pub get && flutter test     # 23 条，约 2 分钟；没起 up.sh 时全部跳过
```

结果和结论见 `plan/v3/evidence/X08.md`、`docs/architecture/mosh-runtime-decision.md`。
「缺陷复现」那条断言的是 dart_mosh 0.0.4 的**错误行为**（反射包导致输入丢失）；哪天它挂了，说明上游修了，要重新评估。

## 模拟器怎么连到这里

UDP：见 `plan/v3/evidence/X08.md`「设备上的 UDP 通路」。X09 的 App 要 SSH 和 UDP 发往同一个地址（10.0.2.2），
TCP 经 10.0.2.2 要先关模拟器的 Wi-Fi，见 `docs/shun/README.md` 第 3 节。设备测试参数：`python3 x08_config.py`（X08、X09 共用）。

## 撞墙时

- **`mosh-server` 报 `needs a UTF-8 native locale`**：Alpine 的 musl 对 `LC_ALL=C` 也给 UTF-8，这台容器上测不出这条；
  glibc 系统才会这样。宿主 bootstrap 的解析要能认出它（见 X08 的 MOS08）。
- **某个端口上 dart_mosh 一直连不上（中继计数显示服务器一个包都没回），换个端口就好**：OrbStack 的 UDP 端口转发卡住了。
  X08 时撞上过一次（当时中继按个数攒包、流量稀时把包压了几十秒）。`./down.sh && ./up.sh` 重建就好。
- **`flutter test` 跑到一半报 `Shell subprocess crashed with SIGTERM`**：测试进程被外面杀了（同时有别的代理在跑 flutter test 时撞上过），
  不是测试失败。单独重跑那一组。
- **容器里残留很多 mosh-server**：客户端不发关闭就走（比如 dart_mosh 的 `close()`），mosh-server 会一直等。
  `ssh … 'pkill -x mosh-server'` 清掉；`down.sh` 也会一起清。引导成功、但一直没有客户端连上的，60 秒后自己退出（mosh-server 的规矩）。
- **`pgrep -x mosh-server` 数出 0、`pkill -x` 也杀不掉，`ps` 里明明有**：busybox 的 pgrep/pkill `-x` 比的是 argv[0]。
  进程要是按全路径 `/usr/bin/mosh-server` 启动的，argv[0] 就是全路径，对不上。记账脚本因此按名字 exec（X09 撞上过）。
- **每个 mosh-server 在 `ps` 里有两个进程**：没被客户端连过的 mosh-server 先 fork 一个等着起 shell 的子进程。
  `counts.sh` 只数父进程是 1 的那个。
