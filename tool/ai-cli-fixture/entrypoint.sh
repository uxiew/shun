#!/usr/bin/env bash
# 每次启动都重新生成主机密钥，密码从挂进来的 /secrets/ssh_password 读。主机公钥和指纹写到 /hostkeys 给 up.sh 读。
set -euo pipefail
rm -f /etc/ssh/ssh_host_*
ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key
echo "fixture:$(cat /secrets/ssh_password)" | chpasswd
cp /etc/ssh/ssh_host_ed25519_key.pub /hostkeys/ai-cli.pub
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256 | awk '{print $1, $2}' > /hostkeys/ai-cli.sha256
cp /versions.txt /hostkeys/versions.txt
exec /usr/sbin/sshd -D -e
