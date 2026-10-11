#!/bin/sh
# 凭据全部来自 up.sh 临时生成、只读挂载进来的 /run-secrets，容器销毁即作废。
set -eu

case "$ROLE" in
  sshd)
    # 容器重启（docker restart，R22 测「sshd 重启」）时用户已经在了，再 adduser 会报错退出。
    id -u fixture >/dev/null 2>&1 || adduser -D -s /bin/sh fixture
    echo "fixture:$(cat /run-secrets/ssh_password)" | chpasswd
    install -d -m 700 -o fixture -g fixture /home/fixture/.ssh
    install -m 600 -o fixture -g fixture /run-secrets/id_ed25519.pub /home/fixture/.ssh/authorized_keys
    # 每个新容器重新生成主机密钥：up 一次指纹就变一次，正好用来测"指纹改变必须阻断"。
    # 同一个容器重启（docker restart）沿用原来的密钥，像真服务器的 sshd 重启（R22 LIFE04）；
    # 要测"重启后换了密钥"，进容器删掉 .shun-hostkey 标记再重启。
    if [ ! -f /etc/ssh/.shun-hostkey ]; then
      rm -f /etc/ssh/ssh_host_*
      ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key
      touch /etc/ssh/.shun-hostkey
    fi
    ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256 > "/run-hostkeys/$(hostname).sha256"
    cp /etc/ssh/ssh_host_ed25519_key.pub "/run-hostkeys/$(hostname).pub"
    # PerSourcePenalties no：OpenSSH 9.8 起，连上后不认证就断（测试里「指纹确认时取消」就是这样）
    # 每次罚 1 秒、被 pkill 杀掉的会话按崩溃罚 90 秒，累计超过 15 秒就拒绝本机全部新连接，
    # 日志是 "drop connection ... penalty: connections without attempting authentication"。
    # 所有测试都从同一个来源地址进来，不关的话反复取消的测试会把后面的测试一起连不上。
    cat > /etc/ssh/sshd_config <<'EOF'
Port 22
HostKey /etc/ssh/ssh_host_ed25519_key
AllowUsers fixture
PermitRootLogin no
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PubkeyAuthentication yes
AllowTcpForwarding yes
X11Forwarding no
LogLevel VERBOSE
PerSourcePenalties no
EOF
    # SFTP 用 sshd 内置的 internal-sftp，不用另装包。ssh-hop3 设 SFTP=off 故意不开，
    # 用来测「服务器没开 SFTP」时 App 能在期限内报清楚原因（dartssh2 自己会一直等）。
    if [ "${SFTP:-on}" = on ]; then
      echo 'Subsystem sftp internal-sftp' >> /etc/ssh/sshd_config
    fi
    exec /usr/sbin/sshd -D -e
    ;;
  socks)
    # 两个 dante 实例：1080 要求用户名密码，1081 无认证。dante 的 username 方法校验系统账户。
    # 规则块必须多行写：单行时 "command: connect log: ..." 会被当成命令列表，报 syntax error near token "l"。
    # 只放行 CONNECT；BIND/UDP ASSOCIATE 落到 block，对应计划"SOCKS 首版 CONNECT-only"。
    id -u socksuser >/dev/null 2>&1 || adduser -D -H -s /sbin/nologin socksuser
    echo "socksuser:$(cat /run-secrets/socks_password)" | chpasswd
    write_conf() {
      cat <<EOF
logoutput: stderr
internal: 0.0.0.0 port = $1
external: eth0
external: eth1
external.rotation: route
socksmethod: $2
user.privileged: root
user.unprivileged: nobody
client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
}
socks pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  command: connect
  log: connect disconnect error
}
socks block {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: error
}
EOF
    }
    write_conf 1080 username > /etc/sockd-auth.conf
    write_conf 1081 none > /etc/sockd-noauth.conf
    sockd -f /etc/sockd-noauth.conf -p /tmp/sockd-noauth.pid &
    exec sockd -f /etc/sockd-auth.conf -p /tmp/sockd-auth.pid
    ;;
  *)
    echo "unknown ROLE=$ROLE" >&2
    exit 64
    ;;
esac
