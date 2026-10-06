#!/usr/bin/env bash
# R18：在模拟器上用「回放输入法」和真实扫描码的硬件键跑设备测试
# （integration_test/r18_ime_replay_test.dart、r18_keys_test.dart）。
#
# 先起 Docker 测试环境（tool/fixture-environment/up.sh），再：
#   source ../.toolchain/env.sh
#   (cd plugins && ./build-fixtures.sh)        # 或只编回放输入法，见 plugins/README.md
#   tool/ime-replay.sh emulator-5580 [Ghostty|xterm2] [测试文件，默认 r18_ime_replay_test.dart]
# 测试文件要别的参数时放进环境变量 IME_REPLAY_DEFINES，一行一个，比如 X09 的 Mosh 回放：
#   IME_REPLAY_DEFINES="--dart-define=X09_MOSH=$(python3 tool/mosh-fixture/x08_config.py)
#   --dart-define=X09_SCENARIO=ime" tool/ime-replay.sh emulator-5580 Ghostty integration_test/mosh_session_test.dart
#
# 测试打印 "R18 READY=<名字>" 时这里替它按：名字以 hw: 开头就用 sendevent 往模拟器的硬件键盘写扫描码
# （要 AVD 的 hw.keyboard = yes 和 adb root，见 docs/xwshun/README.md），否则广播给回放输入法。
#
# 会临时把模拟器的默认输入法换成回放输入法，结束（含失败、Ctrl-C）后换回原来的输入法并卸载它。
# 只在模拟器上用：真机上换默认输入法会动到所有者的输入法设置。
set -euo pipefail
cd "$(dirname "$0")/.."

SERIAL=${1:?用法：tool/ime-replay.sh <模拟器序列号> [Ghostty|xterm2] [测试文件]}
ENGINE=${2:-}
TEST_FILE=${3:-integration_test/r18_ime_replay_test.dart}
APK=plugins/out/replayime.apk
IME=example.xwshun.fixture.replayime/.ReplayIme
ADB=(adb -s "$SERIAL")

[[ "$("${ADB[@]}" emu avd name 2>/dev/null | head -1 | tr -d '\r')" != "" ]] \
  || { echo "$SERIAL 不是模拟器，不跑（真机上会改掉所有者的输入法设置）" >&2; exit 1; }
[[ -f "$APK" ]] || { echo "没有 $APK，先构建回放输入法" >&2; exit 1; }

# adb root 会重启 adbd（连带清掉 adb reverse），要在装包、转端口之前做；找不到键盘设备只报一句，跑到 hw: 脚本时那段会收不到字节。
"${ADB[@]}" root >/dev/null 2>&1 || true
"${ADB[@]}" wait-for-device
EVENTS=$("${ADB[@]}" shell getevent -pl 2>/dev/null | tr -d '\r' || true)
KBD=$(awk '/add device/{d=$4} /KEY_Q /{print d; exit}' <<<"$EVENTS")
[[ -n "$KBD" ]] || echo "模拟器上没有硬件键盘设备（AVD 的 hw.keyboard 要设成 yes），hw: 脚本会跳过" >&2
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

# 一行一个参数：JSON 里的方括号、引号原样保留，不经 shell 再拆一遍。
EXTRA=()
while IFS= read -r line; do
  [[ -n "$line" ]] && EXTRA+=("$line")
done <<< "${IME_REPLAY_DEFINES:-}"
flutter test "$TEST_FILE" -d "$SERIAL" \
  --dart-define=R17_SSH="$(python3 tool/fixture-environment/r17_config.py 2>/dev/null)" \
  --dart-define=R18_ENGINE="$ENGINE" ${EXTRA[@]+"${EXTRA[@]}"} > "$LOG" 2>&1 &
TEST=$!

# 硬件键：按下/抬起都是 EV_KEY（1）+ 扫描码，每个动作后跟一个 EV_SYN（0 0 0）。扫描码见 linux input-event-codes.h。
hw_keys() {
  [[ -n "$KBD" ]] || return 0
  local cmd="" code
  for code in "$@"; do   # 正数按下、负数抬起
    if (( code > 0 )); then cmd+="sendevent $KBD 1 $code 1; "; else cmd+="sendevent $KBD 1 $(( -code )) 0; "; fi
    cmd+="sendevent $KBD 0 0 0; "
  done
  "${ADB[@]}" shell "$cmd"
}
CTRL=29; ALT=56; SHIFT=42; KC=46; KD=32; KX=45; TAB=15; UP=103; KA=30
press() { hw_keys "$@"; }

# 测试准备好一段就打印 "R18 READY=<名字>"，这里替它按。
SEEN=0
while kill -0 "$TEST" 2>/dev/null; do
  COUNT=$(grep -c 'R18 READY=' "$LOG" || true)
  while (( SEEN < COUNT )); do
    SEEN=$((SEEN + 1))
    SCRIPT=$(grep 'R18 READY=' "$LOG" | sed -n "${SEEN}p" | sed 's/.*R18 READY=//' | tr -d '\r')
    case "$SCRIPT" in
      hw:combo)   # Ctrl+C、Ctrl+D、Alt+x、Tab、↑、Shift+Tab、a（组合键之后不粘）。模拟器键位表里扫描码 1 是 BACK，不发 Esc
        press $CTRL $KC -$KC -$CTRL  $CTRL $KD -$KD -$CTRL  $ALT $KX -$KX -$ALT \
          $TAB -$TAB  $UP -$UP  $SHIFT $TAB -$TAB -$SHIFT  $KA -$KA ;;
      hw:cc) press $KC -$KC $KC -$KC ;;
      hw:*) echo "不认识的硬件键脚本 $SCRIPT" >&2 ;;
      *) "${ADB[@]}" shell am broadcast -a example.xwshun.fixture.replayime.RUN \
           -p example.xwshun.fixture.replayime --es script "$SCRIPT" >/dev/null ;;
    esac
  done
  sleep 0.5
done
wait "$TEST" && STATUS=0 || STATUS=$?
grep -E 'R18 |\[E\]|Expected|Actual|All tests|Some tests' "$LOG" | grep -v 'R18 READY=' || true
exit "$STATUS"
