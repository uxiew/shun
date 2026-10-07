#!/usr/bin/env bash
# R20 设备门禁（integration_test/r20_gate_test.dart）：转发端口、预授权通知、跑一个场景、按测试打出的 "R20 SHOT=" 截图。
#
#   source ../.toolchain/env.sh
#   (cd tool/fixture-environment && ./up.sh)
#   (cd tool/ai-cli-fixture && ./up.sh)          # 只有 ai-cli 场景要
#   tool/r20-gate.sh emulator-5580 tui|resources|ai-cli
#
# 截图放在 ../.toolchain/artifacts/r20-shots-<提交>/，日志路径最后打印。只在模拟器上用过。
set -euo pipefail
cd "$(dirname "$0")/.."

SERIAL=${1:?用法：tool/r20-gate.sh <设备序列号> tui|resources|ai-cli}
SCENARIO=${2:?用法：tool/r20-gate.sh <设备序列号> tui|resources|ai-cli}
ADB=(adb -s "$SERIAL")
SHOTS=../.toolchain/artifacts/r20-shots-$(git rev-parse --short HEAD)
mkdir -p "$SHOTS"
LOG=$(mktemp -t r20-gate)

DEFINES=(--dart-define=R20_SCENARIO="$SCENARIO" --dart-define=R20_SHOTS=true
  --dart-define=R17_SSH="$(python3 tool/fixture-environment/r17_config.py)")
"${ADB[@]}" reverse tcp:22201 tcp:22201 >/dev/null
if [[ "$SCENARIO" == ai-cli ]]; then
  DEFINES+=(--dart-define=R20_AI_CLI="$(python3 tool/ai-cli-fixture/config.py)")
  "${ADB[@]}" reverse tcp:22401 tcp:22401 >/dev/null
fi
# 每次 flutter test 都重装 App，一连上就为保活服务申请通知权限，系统框会挡住页面；装上就授权。
(for _ in $(seq 1 900); do
  "${ADB[@]}" shell pm grant top.xdwa.xwshun android.permission.POST_NOTIFICATIONS 2>/dev/null && break
  sleep 0.3
done >/dev/null 2>&1 &)

flutter test integration_test/r20_gate_test.dart -d "$SERIAL" "${DEFINES[@]}" > "$LOG" 2>&1 &
TEST=$!
SEEN=0
MSEEN=0
while kill -0 "$TEST" 2>/dev/null; do
  COUNT=$(grep -c 'R20 SHOT=' "$LOG" || true)
  while (( SEEN < COUNT )); do
    SEEN=$((SEEN + 1))
    NAME=$(grep 'R20 SHOT=' "$LOG" | sed -n "${SEEN}p" | sed 's/.*R20 SHOT=//' | tr -d '\r')
    "${ADB[@]}" exec-out screencap -p > "$SHOTS/$NAME.png" || true
  done
  # 测试打 "R20 MEM=<名字>" 时抓一次 dumpsys meminfo（Native Heap、Dalvik、Graphics 分开），存在截图目录里。
  MCOUNT=$(grep -c 'R20 MEM=' "$LOG" || true)
  while (( MSEEN < MCOUNT )); do
    MSEEN=$((MSEEN + 1))
    NAME=$(grep 'R20 MEM=' "$LOG" | sed -n "${MSEEN}p" | sed 's/.*R20 MEM=//' | tr -d '\r')
    "${ADB[@]}" shell dumpsys meminfo top.xdwa.xwshun > "$SHOTS/mem-$NAME.txt" || true
  done
  sleep 0.5
done
wait "$TEST" && STATUS=0 || STATUS=$?
grep -E 'R20 |\[E\]|Expected|Actual|Which|All tests|Some tests|skipped' "$LOG" | grep -v 'R20 SHOT=\|R20 MEM=' || true
echo "日志 ${LOG}，截图 ${SHOTS}"
exit "$STATUS"
