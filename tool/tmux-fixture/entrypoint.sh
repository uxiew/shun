#!/bin/sh
# 凭据全部来自 up.sh 临时生成、只读挂载进来的 /run-secrets，容器销毁即作废。
#
# 两个 Unix 用户：fixture（uid 1000）和 other（uid 1001），密码、公钥相同；
# 用来测「换了 Unix 用户，原来的 tmux 目标不算数」（TMX05）。
#
# TMUX_MODE：
#   real（默认）  用镜像自带的 tmux
#   none          删掉 tmux，测「远端没有 tmux」（TMX01）
#   fake          /usr/bin/tmux 换成 fake-tmux.sh：按用户家目录里的 .faketmux 决定
#                 是照常转给真 tmux，还是吐乱码、超长输出、挂住不动（TMX01、SEC11）
set -eu

for user in fixture:1000 other:1001; do
  name=${user%%:*}
  adduser -D -u "${user##*:}" -s /bin/sh "$name"
  echo "$name:$(cat /run-secrets/ssh_password)" | chpasswd
  install -d -m 700 -o "$name" -g "$name" "/home/$name/.ssh"
  install -m 600 -o "$name" -g "$name" /run-secrets/id_ed25519.pub "/home/$name/.ssh/authorized_keys"
done

case "${TMUX_MODE:-real}" in
  none) rm -f /usr/bin/tmux ;;
  fake) mv /usr/bin/tmux /usr/bin/tmux.real && cp /fake-tmux.sh /usr/bin/tmux ;;
esac

rm -f /etc/ssh/ssh_host_*
ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256 > "/run-hostkeys/$(hostname).sha256"
cp /etc/ssh/ssh_host_ed25519_key.pub "/run-hostkeys/$(hostname).pub"
tmux_version=$( (tmux -V 2>/dev/null || tmux.real -V 2>/dev/null || echo none) | head -n 1)
echo "$tmux_version" > "/run-hostkeys/$(hostname).tmux"

cat > /etc/ssh/sshd_config <<'EOF'
Port 22
HostKey /etc/ssh/ssh_host_ed25519_key
AllowUsers fixture other
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
AllowTcpForwarding no
X11Forwarding no
LogLevel VERBOSE
EOF
# 测试会反复 pkill 会话来模拟断网。OpenSSH 9.8 起的来源罚时会因此把本机拉黑（见 fixture-environment/entrypoint.sh）；
# 老版本 sshd 不认这个选项、会拒绝启动，所以先试一下再加。
echo 'PerSourcePenalties no' >> /etc/ssh/sshd_config
/usr/sbin/sshd -t -f /etc/ssh/sshd_config 2>/dev/null || sed -i '/PerSourcePenalties/d' /etc/ssh/sshd_config
exec /usr/sbin/sshd -D -e
