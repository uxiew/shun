#!/bin/bash
# 手机接在另一台电脑上时，让本机的 adb / flutter 直接用那台电脑上的手机。用法见同目录 README.md。
set -euo pipefail

host=${1:?用法：./up.sh <ssh 主机> [那台电脑上 adb 的完整路径]}
remote_adb=${2:-adb}
: "${ANDROID_HOME:?先 source ../.toolchain/env.sh}"
here=$(cd "$(dirname "$0")" && pwd)
# 放 /tmp 下的短路径：SSH 控制套接字路径太长会报 too long for Unix domain socket
state=/tmp/xwshun-remote-device
ctl=$state/ssh.ctl
sdk=$state/sdk
port=${XWSHUN_REMOTE_ADB_PORT:-15037}

mkdir -p "$state"
if ssh -S "$ctl" -O check "$host" 2>/dev/null; then
  echo "隧道已经在了，只重建假 SDK"
else
  # 那边的 adb 服务没起的话，本机 adb 会报 cannot connect to daemon
  ssh -o BatchMode=yes "$host" "$remote_adb start-server" >/dev/null
  ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -f -N -M -S "$ctl" \
    -L "$port:127.0.0.1:5037" "$host"
fi

# 假 SDK：全部软链接回真 SDK，只把 platform-tools/adb 换成包装脚本。
# flutter 按 ANDROID_HOME 找 adb，不看 PATH，所以光改 PATH 不够。
rm -rf "$sdk"
mkdir -p "$sdk/platform-tools"
for e in "$ANDROID_HOME"/*; do
  [ "$(basename "$e")" = platform-tools ] || ln -s "$e" "$sdk/"
done
for e in "$ANDROID_HOME"/platform-tools/*; do
  [ "$(basename "$e")" = adb ] || ln -s "$e" "$sdk/platform-tools/"
done
sed -e "s#@REAL@#$ANDROID_HOME/platform-tools/adb#" -e "s#@CTL@#$ctl#" \
  -e "s#@HOST@#$host#" -e "s#@STATE@#$state#" \
  "$here/adb-wrapper.sh" >"$sdk/platform-tools/adb"
chmod +x "$sdk/platform-tools/adb"
# down.sh 删转发时要用真 adb 和隧道端口
echo "$ANDROID_HOME/platform-tools/adb" >"$state/real-adb"
echo "$port" >"$state/adb-port"

cat >"$state/env" <<EOF
export ADB_SERVER_SOCKET=tcp:127.0.0.1:$port
export ANDROID_HOME=$sdk ANDROID_SDK_ROOT=$sdk
export PATH=$sdk/platform-tools:\$PATH
EOF

echo "好了。在要用的终端里执行：source $state/env"
ADB_SERVER_SOCKET=tcp:127.0.0.1:$port "$sdk/platform-tools/adb" devices -l
