#!/bin/sh
# 节点保温。没有可用的 DERP（占位节点解析不到），节点间只能直连，而直连路径空闲一阵就失效：
# 下一次经 SOCKS 拨号报「状态码 1」、经跳板 ssh 直接被关。每 10 秒对 KEEPALIVE_PEERS 里的每台发两种 ping：
#   disco ping（默认）：维持直连路径；路径没摸出来时 TSMP 只会超时，所以它在前。
#   TSMP ping：走 WireGuard，算真实流量，用意是不让 tailscaled 把空闲的 peer 从 WireGuard 配置里摘掉。
# 只发 disco、且只单向 ping 时，实测环境起来十来分钟后「经 ts-socks 到 ts-jump」的第一次连接失败过（再连就好）。
while sleep 10; do
  for peer in ${KEEPALIVE_PEERS:-}; do
    tailscale ping -c 1 --timeout 3s "$peer" >/dev/null 2>&1
    tailscale ping --tsmp -c 1 --timeout 3s "$peer" >/dev/null 2>&1
  done
done
