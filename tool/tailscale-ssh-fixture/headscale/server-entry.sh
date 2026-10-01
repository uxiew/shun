#!/bin/sh
# 先起普通 OpenSSH（只听 2222），再交给官方的 containerboot 起 tailscaled。
set -e
ssh-keygen -A >/dev/null
echo "ordinary:${ORDINARY_PASSWORD}" | chpasswd
cat > /etc/ssh/sshd_config.d/fixture.conf <<CONF
Port 2222
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitRootLogin no
PerSourcePenalties no
CONF
/usr/sbin/sshd
/usr/local/bin/keepalive.sh &
exec /usr/local/bin/containerboot
