#!/usr/bin/env bash
# R18：在模拟器上用「回放输入法」和真实扫描码的硬件键跑设备测试
# （integration_test/r18_ime_replay_test.dart、r18_keys_test.dart）。
#
# 先起 Docker 测试环境（tool/fixture-environment/up.sh），再：
#   source ../.toolchain/env.sh
#   (cd plugins && ./build-fixtures.sh)        # 或只编回放输入法，见 plugins/README.md
#   tool/ime-replay.sh emulator-5580 [""] [测试文件，默认 r18_ime_replay_test.dart]
# 第二个参数原来选引擎（Ghostty / xterm2）；R20 起只有 Ghostty，留空，位置保留是为了旧命令照样能用。
# 测试文件要别的参数时放进环境变量 IME_REPLAY_DEFINES，一行一个，比如 X09 的 Mosh 回放：
#   IME_REPLAY_DEFINES="--dart-define=X09_MOSH=$(python3 tool/mosh-fixture/x08_config.py)
#   --dart-define=X09_SCENARIO=ime" tool/ime-replay.sh emulator-5580 Ghostty integration_test/mosh_session_test.dart
#
# 测试打印 "R18 READY=<名字>" 时这里替它按：名字以 hw: 开头就按硬件键（要 AVD 的 hw.keyboard = yes，见 docs/dev/README.md），
# 否则广播给回放输入法。硬件键能 root 就 sendevent 往模拟器的键盘写扫描码；带 Play 的镜像 root 不了、SELinux 不让 shell 写输入设备，
# 就用系统自带的 hid 命令临时造一个 USB 键盘去按（shell 在 uhid 组里），两条路都经过内核输入设备和系统的键位表。
# 模拟器控制台的 `adb emu event send` 回 OK 但不送进系统（10-25 在 API 30 上试过），别用。
#
# 会临时把模拟器的默认输入法换成回放输入法，结束（含失败、Ctrl-C）后换回原来的输入法并卸载它。
# 只在模拟器上用：真机上换默认输入法会动到所有者的输入法设置。
set -euo pipefail
cd "$(dirname "$0")/.."

SERIAL=${1:?用法：tool/ime-replay.sh <模拟器序列号> [""] [测试文件]}
case "${2:-}" in
  ""|Ghostty) ;;
  *) echo "R20 起只有 Ghostty，第二个参数「$2」不认，留空即可" >&2; exit 1 ;;
esac
TEST_FILE=${3:-integration_test/r18_ime_replay_test.dart}
APK=plugins/out/replayime.apk
IME=example.shun.fixture.replayime/.ReplayIme
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
# 写一个同步事件试试：写不进（Permission denied）就改用 hid。
HW=sendevent
if [[ -n "$KBD" ]] && ! "${ADB[@]}" shell "sendevent $KBD 0 0 0" >/dev/null 2>&1; then
  HW=hid
  echo "写不了 $KBD（没有 root），硬件键改用 hid 临时造的 USB 键盘" >&2
fi
ORIGINAL=$("${ADB[@]}" shell settings get secure default_input_method | tr -d '\r')
LOG=$(mktemp -t r18-ime-replay)
restore() {
  "${ADB[@]}" shell ime set "$ORIGINAL" >/dev/null 2>&1 || true
  "${ADB[@]}" uninstall example.shun.fixture.replayime >/dev/null 2>&1 || true
  "${ADB[@]}" shell rm -f /data/local/tmp/r18-hid.json >/dev/null 2>&1 || true
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
  "${ADB[@]}" shell pm grant top.xdwa.shun.debug android.permission.POST_NOTIFICATIONS 2>/dev/null && break
  sleep 0.3
done >/dev/null 2>&1 &)

# 一行一个参数：JSON 里的方括号、引号原样保留，不经 shell 再拆一遍。
EXTRA=()
while IFS= read -r line; do
  [[ -n "$line" ]] && EXTRA+=("$line")
done <<< "${IME_REPLAY_DEFINES:-}"
flutter test "$TEST_FILE" -d "$SERIAL" \
  --dart-define=R17_SSH="$(python3 tool/fixture-environment/r17_config.py 2>/dev/null)" \
  ${EXTRA[@]+"${EXTRA[@]}"} > "$LOG" 2>&1 &
TEST=$!

# 硬件键：按下/抬起都是 EV_KEY（1）+ 扫描码，每个动作后跟一个 EV_SYN（0 0 0）。扫描码见 linux input-event-codes.h。
hw_keys() {
  [[ -n "$KBD" ]] || return 0
  if [[ $HW == hid ]]; then hid_keys "$@"; return; fi
  local cmd="" code
  for code in "$@"; do   # 正数按下、负数抬起
    if (( code > 0 )); then cmd+="sendevent $KBD 1 $code 1; "; else cmd+="sendevent $KBD 1 $(( -code )) 0; "; fi
    cmd+="sendevent $KBD 0 0 0; "
  done
  "${ADB[@]}" shell "$cmd"
}
# 同一串扫描码换成 USB 键盘报告（8 字节：修饰键位、保留、最多 6 个按着的键），每个动作一份，交给 hid。
# 键盘注册后等 0.8 秒再按：系统还没加好这个设备时按的键会丢；按完等 0.5 秒再退，退了键盘就拔掉了。
hid_keys() {
  local json=/data/local/tmp/r18-hid.json
  python3 - "$@" > "$LOG.hid.json" <<'PY'
import json, sys
# a–z 的 Linux 扫描码按字母顺序（和下面 LETTERS 一样），HID 里 a–z 是 4–29。
letters = [30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, 49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44]
usage = {code: 4 + i for i, code in enumerate(letters)}
usage.update({15: 0x2B, 26: 0x2F, 103: 0x52})   # Tab、[、↑
modifier = {29: 0x01, 42: 0x02, 56: 0x04}        # 左 Ctrl、左 Shift、左 Alt
# 标准的引导协议键盘描述符。
descriptor = [5, 1, 9, 6, 161, 1, 5, 7, 25, 224, 41, 231, 21, 0, 37, 1, 117, 1, 149, 8, 129, 2, 149, 1,
              117, 8, 129, 1, 149, 5, 117, 1, 5, 8, 25, 1, 41, 5, 145, 2, 149, 1, 117, 3, 145, 1,
              149, 6, 117, 8, 21, 0, 37, 101, 5, 7, 25, 0, 41, 101, 129, 0, 192]
events = [{'id': 1, 'command': 'register', 'name': 'shun-r18-keyboard', 'vid': 0x18d1,
           'pid': 0xabcd, 'bus': 'usb', 'descriptor': descriptor},
          {'id': 1, 'command': 'delay', 'duration': 800}]
mods, keys = 0, []
for arg in sys.argv[1:]:
    code, down = abs(int(arg)), int(arg) > 0
    if code in modifier:
        mods = mods | modifier[code] if down else mods & ~modifier[code]
    elif code in usage:
        if down and usage[code] not in keys:
            keys.append(usage[code])
        elif not down and usage[code] in keys:
            keys.remove(usage[code])
    else:
        sys.exit(f'hid_keys 不认识扫描码 {code}，在上面的表里补上')
    events.append({'id': 1, 'command': 'report', 'report': [mods, 0] + (keys + [0] * 6)[:6]})
    events.append({'id': 1, 'command': 'delay', 'duration': 30})
events.append({'id': 1, 'command': 'delay', 'duration': 500})
print('\n'.join(json.dumps(e) for e in events))
PY
  "${ADB[@]}" push "$LOG.hid.json" "$json" >/dev/null 2>&1 || { echo "推不上 $json" >&2; return 1; }
  "${ADB[@]}" shell hid "$json"
}
CTRL=29; ALT=56; SHIFT=42; KC=46; KD=32; KX=45; TAB=15; UP=103; KA=30; KK=37; LEFTBRACE=26
press() { hw_keys "$@"; }
# a–z 的扫描码（linux input-event-codes.h），按字母顺序；v 是 App 的粘贴快捷键，hw:ctrl-letters 跳过它。
LETTERS=(30 48 46 32 18 33 34 35 23 36 37 38 50 49 24 25 16 19 31 20 22 47 17 45 21 44)

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
      hw:ctrl-ka)   # 10-07：Ctrl+K、Ctrl+A 发给服务器
        press $CTRL $KK -$KK -$CTRL  $CTRL $KA -$KA -$CTRL ;;
      hw:ctrl-shift-ka)   # 10-07：Ctrl+Shift+K 清本地滚动区、Ctrl+Shift+A 全选
        press $CTRL $SHIFT $KK -$KK -$SHIFT -$CTRL  $CTRL $SHIFT $KA -$KA -$SHIFT -$CTRL ;;
      hw:ctrl-bracket)   # R20：Ctrl+[ 发 ESC
        press $CTRL $LEFTBRACE -$LEFTBRACE -$CTRL ;;
      hw:copy-then-interrupt)   # R20：有选区时 Ctrl+Shift+C 复制（不发字节），Ctrl+C 照样发 ^C
        press $CTRL $SHIFT $KC -$KC -$SHIFT -$CTRL  $CTRL $KC -$KC -$CTRL ;;
      hw:ctrl-letters)   # Ctrl+a 到 Ctrl+z（跳过 v），看有没有被本地吃掉
        seq_codes=()
        for i in "${!LETTERS[@]}"; do
          (( i == 21 )) && continue
          seq_codes+=("$CTRL" "${LETTERS[$i]}" "-${LETTERS[$i]}" "-$CTRL")
        done
        press "${seq_codes[@]}" ;;
      hw:*) echo "不认识的硬件键脚本 $SCRIPT" >&2 ;;
      *) "${ADB[@]}" shell am broadcast -a example.shun.fixture.replayime.RUN \
           -p example.shun.fixture.replayime --es script "$SCRIPT" >/dev/null ;;
    esac
  done
  sleep 0.5
done
wait "$TEST" && STATUS=0 || STATUS=$?
grep -E 'R18 |\[E\]|Expected|Actual|All tests|Some tests' "$LOG" | grep -v 'R18 READY=' || true
exit "$STATUS"
