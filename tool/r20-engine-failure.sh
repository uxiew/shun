#!/usr/bin/env bash
# R20 TER12/GST05：安装包里的 Ghostty 原生库真没了，App 怎么说（integration_test/r20_engine_failure_test.dart）。
#
# 编出这个测试的 debug APK → 删掉 lib/arm64-v8a/libghostty.so → 重新对齐、用本机 debug 证书签名 →
# flutter drive 装这个包跑。不是拿代码模拟「加载失败」：删的是真库，App 里第一次建终端时才去加载它。
#
#   source ../.toolchain/env.sh
#   (cd tool/fixture-environment && ./up.sh)
#   tool/r20-engine-failure.sh emulator-5580
#
# 跑完 App 留在设备上（flutter drive 不卸），脚本最后卸掉。截图放 ../.toolchain/artifacts/r20-shots-<提交>/。
set -euo pipefail
cd "$(dirname "$0")/.."

SERIAL=${1:?用法：tool/r20-engine-failure.sh <设备序列号>}
ADB=(adb -s "$SERIAL")
BT=$ANDROID_HOME/build-tools/36.0.0
TARGET=integration_test/r20_engine_failure_test.dart
WORK=$(mktemp -d -t r20-fail)
SHOTS=../.toolchain/artifacts/r20-shots-$(git rev-parse --short HEAD)
mkdir -p "$SHOTS"
SSH=$(python3 tool/fixture-environment/r17_config.py)

flutter build apk --debug --target-platform android-arm64 -t "$TARGET" --dart-define=R17_SSH="$SSH" >/dev/null
cp build/app/outputs/flutter-apk/app-debug.apk "$WORK/full.apk"
# 让 unzip 自己按名字查：「unzip -l | grep -q」在 pipefail 下会因为 grep 提前退出、unzip 吃 SIGPIPE 而整条算失败。
unzip -l "$WORK/full.apk" 'lib/arm64-v8a/libghostty.so' >/dev/null \
  || { echo "编出来的包里本来就没有 libghostty.so，删了也说明不了什么" >&2; exit 1; }
cp "$WORK/full.apk" "$WORK/stripped.apk"
zip -q -d "$WORK/stripped.apk" 'lib/arm64-v8a/libghostty.so'
if unzip -l "$WORK/stripped.apk" '*libghostty.so' >/dev/null 2>&1; then echo "没删掉" >&2; exit 1; fi
"$BT/zipalign" -f -P 16 4 "$WORK/stripped.apk" "$WORK/aligned.apk"
"$BT/apksigner" sign --ks ~/.android/debug.keystore --ks-pass pass:android --ks-key-alias androiddebugkey \
  --out "$WORK/signed.apk" "$WORK/aligned.apk"
echo "包里的 .so：$(unzip -l "$WORK/signed.apk" | grep -o 'lib/arm64-v8a/[^ ]*' | tr '\n' ' ')"

"${ADB[@]}" reverse tcp:22201 tcp:22201 >/dev/null
# 装同一个包名但签名不同的包会失败：先卸掉（会清掉设备上这个 App 的数据，项目模拟器上只有测试数据）。
"${ADB[@]}" uninstall top.xdwa.shun >/dev/null 2>&1 || true
(for _ in $(seq 1 900); do
  "${ADB[@]}" shell pm grant top.xdwa.shun android.permission.POST_NOTIFICATIONS 2>/dev/null && break
  sleep 0.3
done >/dev/null 2>&1 &)

LOG=$WORK/drive.log
flutter drive -d "$SERIAL" --driver test_driver/integration_test.dart --target "$TARGET" \
  --use-application-binary "$WORK/signed.apk" --dart-define=R17_SSH="$SSH" > "$LOG" 2>&1 &
TEST=$!
SEEN=0
while kill -0 "$TEST" 2>/dev/null; do
  COUNT=$(grep -c 'R20 SHOT=' "$LOG" || true)
  while (( SEEN < COUNT )); do
    SEEN=$((SEEN + 1))
    NAME=$(grep 'R20 SHOT=' "$LOG" | sed -n "${SEEN}p" | sed 's/.*R20 SHOT=//' | tr -d '\r')
    "${ADB[@]}" exec-out screencap -p > "$SHOTS/$NAME.png" || true
  done
  sleep 0.5
done
wait "$TEST" && STATUS=0 || STATUS=$?
# 进程还在不在、有没有崩：原生库没了，App 不该崩，只该说清楚。
"${ADB[@]}" logcat -d -s AndroidRuntime:E | grep -E 'FATAL|top.xdwa.shun' || echo "logcat 里没有 FATAL"
"${ADB[@]}" uninstall top.xdwa.shun >/dev/null 2>&1 || true
grep -E 'R20 |All tests passed|Some tests failed|EXCEPTION|Error' "$LOG" | grep -v 'R20 SHOT=' || true
echo "日志 ${LOG}，截图 ${SHOTS}"
exit "$STATUS"
