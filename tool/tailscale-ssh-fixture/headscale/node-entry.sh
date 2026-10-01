#!/bin/sh
# R15 的路线节点。内核模式 tailscaled：dante 和 sshd 往 100.x 发的连接要真的走 tailnet，
# userspace 模式下只有 tailscaled 自己的 SOCKS/HTTP 入口能进 tailnet，普通进程的 connect() 进不去。
#   ROLE=relay  远程 SOCKS：dante 要用户名密码，只转发到 100.64.0.0/10，出口只用 tailscale0
#   ROLE=jump   跳板机：OpenSSH，密码登录，允许 TCP 转发
set -eu

# 隔离：开发机自己可能就在真实 tailnet 上（100.64/10 和 fd7a:115c:a1e0::/48 走 Mac 的 utun）。
# 发往这两段、却不走 tailscale0 的包一律丢掉：不是这个假 tailnet 里的节点，就不许经 OrbStack 落进真实 tailnet。
# 用 DROP 不用 REJECT，也不整块封 edge：magicsock 会往别的容器的 edge 地址发 disco，
# 收到拒绝就反复 rebind，节点间的路径一直建不起来（日志里一串 "Rebinding"）。
iptables -A OUTPUT -d 100.64.0.0/10 ! -o tailscale0 -j DROP
ip6tables -A OUTPUT -d fd7a:115c:a1e0::/48 ! -o tailscale0 -j DROP

case "${ROLE:-}" in
  relay)
    adduser -D -H -s /sbin/nologin relayuser
    echo "relayuser:${RELAY_PASSWORD}" | chpasswd
    # 规则块必须多行写（单行会报 syntax error near token "l"，见 tool/fixture-environment）。
    cat > /etc/sockd.conf <<'EOF'
logoutput: stderr
internal: 0.0.0.0 port = 1080
external: tailscale0
socksmethod: username
user.privileged: root
user.unprivileged: nobody
client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
}
socks pass {
  from: 0.0.0.0/0 to: 100.64.0.0/10
  command: connect
  log: connect disconnect error
}
socks block {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: connect error
}
EOF
    # dante 启动时就要解析 external 网卡的地址：等 tailscale0 拿到 100.x 再起。
    (
      while ! ip -4 addr show tailscale0 2>/dev/null | grep -q 'inet 100\.'; do sleep 1; done
      exec sockd -f /etc/sockd.conf -p /tmp/sockd.pid
    ) &
    ;;
  jump)
    adduser -D -s /bin/sh jumper
    echo "jumper:${JUMP_PASSWORD}" | chpasswd
    ssh-keygen -A >/dev/null
    # PerSourcePenalties no：所有连接都从同一个来源进来，测「密码填错」时别把后面的连接一起罚掉。
    cat > /etc/ssh/sshd_config <<'EOF'
Port 22
AllowUsers jumper
PermitRootLogin no
PasswordAuthentication yes
KbdInteractiveAuthentication no
PubkeyAuthentication no
AllowTcpForwarding local
X11Forwarding no
LogLevel VERBOSE
PerSourcePenalties no
EOF
    /usr/sbin/sshd -E /var/log/sshd.log
    ;;
  *)
    echo "node-entry: 不认识的 ROLE=${ROLE:-}" >&2
    exit 64
    ;;
esac

# 保温，见 keepalive.sh。
/usr/local/bin/keepalive.sh &
exec /usr/local/bin/containerboot
