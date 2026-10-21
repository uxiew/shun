#!/usr/bin/env bash
# R18 真机复测（TER02）：手机接在另一台电脑上，所有者本人照手机终端里的说明打拼音、说话
# （integration_test/r18_voice_device_test.dart）。要所有者当次同意、本人在手机旁边。
#
# 先起 Docker 测试环境（tool/fixture-environment/up.sh），再：
#   source ../.toolchain/env.sh
#   tool/r18-real-device.sh xdwmbp /opt/homebrew/share/android-commandlinetools/platform-tools/adb <手机序列号>
#
# 项目就在接手机的那台电脑上跑时（现在 xdwmbp 就是）命令不变：第一个参数就是本机名，脚本不走 SSH，直接用第二个参数那个 adb。
# 手机上已经装着 top.xdwa.shun 就不跑（为什么见下面那段检查）。
#
# 会做的事：经 SSH 用那台电脑上的手机（tool/remote-device），手机的 22201 端口接回本机测试环境，
# 装 App 并预授权通知（不然一连上就弹「允许通知」挡住键盘），跑完 flutter test 会自己卸掉 App。
# 不碰手机的输入法设置：用手机当前的默认输入法，开始和结束各记一次，对得上才说明没动过。
set -euo pipefail
cd "$(dirname "$0")/.."

HOST=${1:?用法：tool/r18-real-device.sh <ssh 主机> <那台电脑上 adb 的完整路径> <手机序列号>}
REMOTE_ADB=${2:?缺那台电脑上 adb 的完整路径}
SERIAL=${3:?缺手机序列号}
LOG=$(mktemp -t r18-real-device)

# 在 xdwmbp 自己身上走 SSH 等于连自己，会报 Host key verification failed / Permission denied（10-21 撞到过）。
if [[ $HOST == "$(scutil --get LocalHostName 2>/dev/null)" || $HOST == localhost ]]; then
  PATH="$(dirname "$REMOTE_ADB"):$PATH"
  trap 'echo "日志 $LOG"' EXIT
else
  tool/remote-device/up.sh "$HOST" "$REMOTE_ADB" >/dev/null
  # shellcheck disable=SC1091
  source /tmp/shun-remote-device/env
  trap 'tool/remote-device/down.sh "$HOST" >/dev/null; echo "日志 $LOG"' EXIT
fi

[[ "$(adb -s "$SERIAL" get-state 2>/dev/null)" == device ]] ||
  { echo "$HOST 上看不到 $SERIAL：手机没插、没开 USB 调试，或者没点「允许调试」" >&2; exit 1; }
# 手机上已经装着本 App（比如留着用的 CI 包）就停：flutter test 装调试包时签名对不上，会自己
# 「Uninstalling old version...」把它连数据卸掉再装，测完还会再卸一次。跟 tool/release-smoke.sh 一个规矩。
if adb -s "$SERIAL" shell pm list packages top.xdwa.shun | tr -d '\r' | grep -qx package:top.xdwa.shun; then
  echo "手机上已经装着 top.xdwa.shun：跑下去会把它连数据卸掉。是上一轮留下的测试包就先 adb uninstall top.xdwa.shun，是留着用的就让所有者自己处理" >&2
  exit 1
fi
IME_BEFORE=$(adb -s "$SERIAL" shell settings get secure default_input_method | tr -d '\r')
echo "手机默认输入法：$IME_BEFORE"

adb -s "$SERIAL" reverse tcp:22201 tcp:22201 >/dev/null
(for _ in $(seq 1 1800); do
  adb -s "$SERIAL" shell pm grant top.xdwa.shun android.permission.POST_NOTIFICATIONS 2>/dev/null && break
  sleep 0.5
done >/dev/null 2>&1 &)

echo "开始构建、安装；手机上出现「点一下这里叫出键盘」后照屏幕说明做。"
STATUS=0
flutter test integration_test/r18_voice_device_test.dart -d "$SERIAL" \
  --dart-define=R17_SSH="$(python3 tool/fixture-environment/r17_config.py)" >"$LOG" 2>&1 || STATUS=$?

# TER02 要求 App 不申请麦克风：看这次装上去的包声明了哪些权限。
AAPT=$(ls -d "$ANDROID_HOME"/build-tools/*/aapt2 | tail -1)
echo "App 声明的权限：$("$AAPT" dump permissions build/app/outputs/flutter-apk/app-debug.apk |
  sed -n "s/.*name='\(.*\)'.*/\1/p" | tr '\n' ' ')"
IME_AFTER=$(adb -s "$SERIAL" shell settings get secure default_input_method | tr -d '\r')
[[ "$IME_AFTER" == "$IME_BEFORE" ]] && echo "输入法没被改动：$IME_AFTER" ||
  echo "输入法变了：$IME_BEFORE → $IME_AFTER" >&2
grep -E 'R18 |\[E\]|Expected|Actual|All tests|Some tests' "$LOG" | grep -v 'R18 READY=' || true
exit "$STATUS"
