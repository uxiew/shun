#!/usr/bin/env bash
# R18：在模拟器上用「回放输入法」跑 integration_test/r18_ime_replay_test.dart。
#
# 先起 Docker 测试环境（tool/fixture-environment/up.sh），再：
#   source ../.toolchain/env.sh
#   (cd plugins && ./build-fixtures.sh)        # 或只编回放输入法，见 plugins/README.md
#   tool/ime-replay.sh emulator-5580 [Ghostty|xterm2]
#
# 会临时把模拟器的默认输入法换成回放输入法，结束（含失败、Ctrl-C）后换回原来的输入法并卸载它。
# 只在模拟器上用：真机上换默认输入法会动到所有者的输入法设置。
set -euo pipefail
cd "$(dirname "$0")/.."

SERIAL=${1:?用法：tool/ime-replay.sh <模拟器序列号> [Ghostty|xterm2]}
ENGINE=${2:-}
APK=plugins/out/replayime.apk
IME=example.xwshun.fixture.replayime/.ReplayIme
ADB=(adb -s "$SERIAL")

[[ "$("${ADB[@]}" emu avd name 2>/dev/null | head -1 | tr -d '\r')" != "" ]] \
  || { echo "$SERIAL 不是模拟器，不跑（真机上会改掉所有者的输入法设置）" >&2; exit 1; }
[[ -f "$APK" ]] || { echo "没有 $APK，先构建回放输入法" >&2; exit 1; }

ORIGINAL=$("${ADB[@]}" shell settings get secure default_input_method | tr -d '\r')
LOG=$(mktemp -t r18-ime-replay)
restore() {
  "${ADB[@]}" shell ime set "$ORIGINAL" >/dev/null 2>&1 || true
  "${ADB[@]}" uninstall example.xwshun.fixture.replayime >/dev/null 2>&1 || true
  echo "输入法已换回 $("${ADB[@]}" shell settings get secure default_input_method | tr -d '\r')；日志 $LOG"
}
trap restore EXIT

"${ADB[@]}" install -r "$APK" >/dev/null
# 刚装完系统还没扫描到这个输入法，马上 enable 会报 "Unknown input method"。
for _ in $(seq 1 40); do
  "${ADB[@]}" shell ime list -a -s | grep -q "^$IME" && break
  sleep 0.5
done
"${ADB[@]}" shell ime enable "$IME" >/dev/null
"${ADB[@]}" shell ime set "$IME" >/dev/null
"${ADB[@]}" reverse tcp:22201 tcp:22201 >/dev/null
# 每次 flutter test 都重装 App，一连上就弹「允许通知」挡住输入法；装上就授权。
(for _ in $(seq 1 900); do
  "${ADB[@]}" shell pm grant top.xdwa.xwshun android.permission.POST_NOTIFICATIONS 2>/dev/null && break
  sleep 0.3
done >/dev/null 2>&1 &)

flutter test integration_test/r18_ime_replay_test.dart -d "$SERIAL" \
  --dart-define=R17_SSH="$(python3 tool/fixture-environment/r17_config.py)" \
  --dart-define=R18_ENGINE="$ENGINE" > "$LOG" 2>&1 &
TEST=$!

# 测试准备好一段脚本就打印 "R18 READY=<名字>"，这里替它按下「回放」。
SEEN=0
while kill -0 "$TEST" 2>/dev/null; do
  COUNT=$(grep -c 'R18 READY=' "$LOG" || true)
  while (( SEEN < COUNT )); do
    SEEN=$((SEEN + 1))
    SCRIPT=$(grep 'R18 READY=' "$LOG" | sed -n "${SEEN}p" | sed 's/.*R18 READY=//' | tr -d '\r')
    "${ADB[@]}" shell am broadcast -a example.xwshun.fixture.replayime.RUN \
      -p example.xwshun.fixture.replayime --es script "$SCRIPT" >/dev/null
  done
  sleep 0.5
done
wait "$TEST" && STATUS=0 || STATUS=$?
grep -E 'R18 |\[E\]|Expected|Actual|All tests|Some tests' "$LOG" | grep -v 'R18 READY=' || true
exit "$STATUS"
