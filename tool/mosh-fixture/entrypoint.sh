#!/bin/sh
# 凭据全部来自 up.sh 临时生成、只读挂载进来的 /run-secrets，容器销毁即作废。
set -eu
# Alpine 是 busybox 的 adduser，Debian（moshalt）用 useradd。Debian 的 sshd 还要 /run/sshd。
if command -v useradd >/dev/null 2>&1; then
  useradd -m -s /bin/sh mosh
  mkdir -p /run/sshd
else
  adduser -D -s /bin/sh mosh
fi
echo "mosh:$(cat /run-secrets/ssh_password)" | chpasswd
install -d -m 700 -o mosh -g mosh /home/mosh/.ssh
install -m 600 -o mosh -g mosh /run-secrets/id_ed25519.pub /home/mosh/.ssh/authorized_keys
rm -f /etc/ssh/ssh_host_*
ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256 > /run-hostkeys/mosh.sha256
cp /etc/ssh/ssh_host_ed25519_key.pub /run-hostkeys/mosh.pub
# PerSourcePenalties no：同一来源反复连接/取消时不被 OpenSSH 9.8+ 的惩罚机制拒之门外（见 ../fixture-environment）。
cat > /etc/ssh/sshd_config <<'CONF'
Port 22
HostKey /etc/ssh/ssh_host_ed25519_key
AllowUsers mosh
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
X11Forwarding no
LogLevel VERBOSE
PerSourcePenalties no
CONF
exec /usr/sbin/sshd -D -e
