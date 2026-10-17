#!/usr/bin/env bash
# R20 设备门禁（integration_test/r20_gate_test.dart）：转发端口、预授权通知、跑一个场景、按测试打出的 "R20 SHOT=" 截图。
#
#   source ../.toolchain/env.sh
#   (cd tool/fixture-environment && ./up.sh)
#   (cd tool/ai-cli-fixture && ./up.sh)          # 只有 ai-cli 场景要
#   tool/r20-gate.sh emulator-5580 tui|resources|ai-cli
#
# 截图放在 ../.toolchain/artifacts/r20-shots-<提交>/，日志路径最后打印。
# 模拟器和真机（tool/remote-device 接的 Pixel 9 Pro）都跑过；真机上不注入按键，打字都走 App 里的 sendText。
set -euo pipefail
cd "$(dirname "$0")/.."

SERIAL=${1:?用法：tool/r20-gate.sh <设备序列号> tui|resources|ai-cli}
SCENARIO=${2:?用法：tool/r20-gate.sh <设备序列号> tui|resources|ai-cli}
ADB=(adb -s "$SERIAL")
SHOTS=../.toolchain/artifacts/r20-shots-$(git rev-parse --short HEAD)
mkdir -p "$SHOTS"
LOG=$(mktemp -t r20-gate)

# 资源场景要用 root 读 App 的 /proc/<pid>/net/tcp（App 自己读不到 /proc/net）。adb root 会重启 adbd、清掉端口转发，
# 所以放在 reverse 之前。真机（user 版）root 不了，这句只报一句 cannot run as root，下面改在电脑这头数。
"${ADB[@]}" root >/dev/null 2>&1 || true
"${ADB[@]}" wait-for-device
ROOT=$("${ADB[@]}" shell id -u | tr -d '\r')
DEFINES=(--dart-define=R20_SCENARIO="$SCENARIO" --dart-define=R20_SHOTS=true
  --dart-define=R17_SSH="$(python3 tool/fixture-environment/r17_config.py)")
"${ADB[@]}" reverse tcp:22201 tcp:22201 >/dev/null
if [[ "$SCENARIO" == ai-cli ]]; then
  DEFINES+=(--dart-define=R20_AI_CLI="$(python3 tool/ai-cli-fixture/config.py)")
  "${ADB[@]}" reverse tcp:22401 tcp:22401 >/dev/null
fi
# 每次 flutter test 都重装 App，一连上就为保活服务申请通知权限，系统框会挡住页面；装上就授权。
(for _ in $(seq 1 900); do
  "${ADB[@]}" shell pm grant top.xdwa.shun android.permission.POST_NOTIFICATIONS 2>/dev/null && break
  sleep 0.3
done >/dev/null 2>&1 &)

flutter test integration_test/r20_gate_test.dart -d "$SERIAL" "${DEFINES[@]}" > "$LOG" 2>&1 &
TEST=$!
# App 里连到 SSH 测试环境（adb reverse 的 22201，十六进制 56B9）的 TCP：按 App 自己的 socket inode 筛，
# 打 "R20HOST <名字> ssh-sockets=<个数> states=<状态码>"。状态 01 已连上、06 TIME_WAIT、08 CLOSE_WAIT。
#
# 没有 root（真机）时：手机上每条连 22201 的 TCP，经 adb reverse（远程手机还要再过一段 ssh -R）到电脑这头，
# 都变成一条连 127.0.0.1:22201 的连接；数电脑上客户端一侧是 22201 的已连上连接，打 "ssh-sockets=<个数> (电脑侧)"。
# 不读手机的 /proc/net/tcp：没 root 读不到，读到了也是整台手机所有 App 的连接，不该存下来。
# 前提是这期间没有别的东西连本机 22201（测试环境谁起谁用，见 docs/dev/README.md 第 7 节）。
ssh_sockets() {
  local pid inodes
  if [[ "$ROOT" != 0 ]]; then
    echo "R20HOST $1 ssh-sockets=$(lsof -nP -iTCP -sTCP:ESTABLISHED 2>/dev/null | grep -c -- '->127\.0\.0\.1:22201 ') (电脑侧)"
    return
  fi
  pid=$("${ADB[@]}" shell pidof top.xdwa.shun | tr -d '\r')
  [[ -n "$pid" ]] || { echo "R20HOST $1 ssh-sockets=? (没找到进程)"; return; }
  inodes=$("${ADB[@]}" shell "ls -l /proc/$pid/fd" 2>/dev/null | grep -o 'socket:\[[0-9]*\]' | grep -o '[0-9]*' | sort -u)
  "${ADB[@]}" shell "cat /proc/$pid/net/tcp /proc/$pid/net/tcp6" 2>/dev/null > "$SHOTS/tcp-$1.txt" || true
  awk -v inodes="$(echo $inodes)" 'BEGIN{n=split(inodes,a," "); for(i=1;i<=n;i++) mine[a[i]]=1}
    NR>0 && $3 ~ /:56B9$/ && ($10 in mine) {c++; st[$4]++}
    END{s=""; for(k in st) s=s k "x" st[k] " "; printf "R20HOST %s ssh-sockets=%d states=%s\n", NAME, c+0, s}' NAME="$1" "$SHOTS/tcp-$1.txt"
}
SEEN=0
MSEEN=0
while kill -0 "$TEST" 2>/dev/null; do
  COUNT=$(grep -c 'R20 SHOT=' "$LOG" || true)
  while (( SEEN < COUNT )); do
    SEEN=$((SEEN + 1))
    NAME=$(grep 'R20 SHOT=' "$LOG" | sed -n "${SEEN}p" | sed 's/.*R20 SHOT=//' | tr -d '\r')
    "${ADB[@]}" exec-out screencap -p > "$SHOTS/$NAME.png" || true
  done
  # 测试打出自己的 VM service 地址（调试器接上后是电脑这边 DDS 的端口）：把同一个端口 reverse 回电脑，测试里才连得上。
  if [[ -z "${VMPORT:-}" ]] && grep -q 'R20 VMSERVICE=' "$LOG"; then
    VMPORT=$(grep -o 'R20 VMSERVICE=ws://127.0.0.1:[0-9]*' "$LOG" | head -1 | grep -o '[0-9]*$')
    [[ -n "$VMPORT" ]] && "${ADB[@]}" reverse tcp:$VMPORT tcp:$VMPORT >/dev/null && echo "R20HOST vmservice-port=$VMPORT"
  fi
  # 测试打 "R20 MEM=<名字>" 时抓一次 dumpsys meminfo（Native Heap、Dalvik、Graphics 分开），存在截图目录里。
  MCOUNT=$(grep -c 'R20 MEM=' "$LOG" || true)
  while (( MSEEN < MCOUNT )); do
    MSEEN=$((MSEEN + 1))
    NAME=$(grep 'R20 MEM=' "$LOG" | sed -n "${MSEEN}p" | sed 's/.*R20 MEM=//' | tr -d '\r')
    "${ADB[@]}" shell dumpsys meminfo top.xdwa.shun > "$SHOTS/mem-$NAME.txt" || true
    ssh_sockets "$NAME"
  done
  sleep 0.5
done
wait "$TEST" && STATUS=0 || STATUS=$?
grep -E 'R20 |R20HOST|\[E\]|Expected|Actual|Which|All tests|Some tests|skipped' "$LOG" | grep -v 'R20 SHOT=\|R20 MEM=\|R20 VMSERVICE=' || true
echo "日志 ${LOG}，截图 ${SHOTS}"
exit "$STATUS"
