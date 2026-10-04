# Mosh 测试环境（X08）

一台容器：OpenSSH + Alpine 打包的官方 mosh 1.4.0（服务器和客户端都有）+ tmux。端口只绑 127.0.0.1。
和 `../fixture-environment` 是两个独立的 compose 项目（`xwshun-mosh`），起停互不影响。

```bash
./up.sh      # 构建并启动；生成 .run/fixture.json（用户 mosh、临时密码、客户端私钥、主机公钥）
./down.sh    # 停止并删除全部临时凭据
```

| 端口 | 用途 |
|---|---|
| `127.0.0.1:22301/tcp` | SSH（用户 `mosh`），手工 bootstrap 用 |
| `127.0.0.1:60101–60108/udp` | mosh-server 的 UDP；bootstrap 时 `-p 60101:60108` 让它只在这几个端口里挑 |

手工起一个 mosh-server：

```bash
ssh -F /dev/null -o IdentityAgent=none -o IdentitiesOnly=yes -i .run/client/id_ed25519 -p 22301 mosh@127.0.0.1 \
  'mosh-server new -c 256 -l LANG=en_US.UTF-8 -p 60101:60108'
# 输出里的 MOSH CONNECT <端口> <22 字符 key> 就是客户端要的东西。key 是秘密，别贴进日志或证据。
```

## Dart 候选探针（`dart_probe/`）

用 `dart_mosh 0.0.4` 连这里的 mosh-server，和容器里官方 mosh-client 在 tmux 里画出的屏幕逐字比较；
中间可以夹一个本机 UDP 中继做丢包、重复、乱序、篡改、重放、反射。

```bash
./up.sh
cd dart_probe && flutter pub get && flutter test     # 19 条，约 1.5 分钟；没起 up.sh 时全部跳过
```

结果和结论见 `plan/v3/evidence/X08.md`、`docs/architecture/mosh-runtime-decision.md`。
「缺陷复现」那条断言的是 dart_mosh 0.0.4 的**错误行为**（反射包导致输入丢失）；哪天它挂了，说明上游修了，要重新评估。

## 模拟器怎么连到这里的 UDP

见 `plan/v3/evidence/X08.md`「设备上的 UDP 通路」。

## 撞墙时

- **`mosh-server` 报 `needs a UTF-8 native locale`**：Alpine 的 musl 对 `LC_ALL=C` 也给 UTF-8，这台容器上测不出这条；
  glibc 系统才会这样。宿主 bootstrap 的解析要能认出它（见 X08 的 MOS08）。
- **容器里残留很多 mosh-server**：客户端不发关闭就走（比如 dart_mosh 的 `close()`），mosh-server 会一直等。
  `ssh … 'pkill -x mosh-server'` 清掉；`down.sh` 也会一起清。
