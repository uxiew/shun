#!/usr/bin/env bash
# 发布包冒烟（REL03）：把 tool/build-release.sh 打出的包装到一台设备上，打开 App，
# 点「设置 → 外观与终端 → 终端引擎 → 检查」，看界面上是不是「正常，这次运行建过的终端：1」。
# 这一步真去加载包里的 libghostty.so、建一个终端再关掉：证明这个包的原生库在这台设备（API、页大小）上能用。
# release 包里没有测试框架，所以用 uiautomator 读界面、adb 点按（Flutter 把文字交给无障碍层，uiautomator 看得见）。
#
#   tool/release-smoke.sh <设备序列号> [APK，默认 build/app/outputs/flutter-apk/app-release.apk]
#
# 会先卸掉设备上的 App（清掉它的数据），测完再卸掉。只在模拟器上用过：真机上 adb 点按会碰到所有者的东西。
set -euo pipefail
cd "$(dirname "$0")/.."

SERIAL=${1:?用法：tool/release-smoke.sh <设备序列号> [APK]}
APK=${2:-build/app/outputs/flutter-apk/app-release.apk}
ADB=(adb -s "$SERIAL")
WORK=$(mktemp -d -t release-smoke)
PKG=top.xdwa.xwshun

[[ "$("${ADB[@]}" emu avd name 2>/dev/null | head -1 | tr -d '\r')" != "" ]] \
  || { echo "$SERIAL 不是模拟器，不跑（真机上 adb 点按会碰到所有者的东西）" >&2; exit 1; }

API=$("${ADB[@]}" shell getprop ro.build.version.sdk | tr -d '\r')
# Android 7.0 的 toybox 没有 getconf：读不到就照实写。
PAGE=$("${ADB[@]}" shell getconf PAGE_SIZE 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+$' || echo '读不到')
ABI=$("${ADB[@]}" shell getprop ro.product.cpu.abi | tr -d '\r')
echo "设备：API ${API}，页大小 ${PAGE}，ABI ${ABI}"
echo "APK：$(shasum -a 256 "$APK" | cut -c1-16)…"
"${ADB[@]}" uninstall "$PKG" >/dev/null 2>&1 || true
"${ADB[@]}" install "$APK" >/dev/null
"${ADB[@]}" logcat -c 2>/dev/null || true
# 用 monkey 发一次启动意图：Activity 的 Kotlin 包名沿用原项目（app.netcatty.mobile），和 applicationId 不一样；
# Android 7.0 没有 cmd package resolve-activity，monkey 各版本都有。--pct-syskeys 0：没有物理系统键的模拟器（API 36）上
# 不加会报 SYS_KEYS has no physical keys、退出码 251（App 其实已经打开）。
"${ADB[@]}" shell monkey --pct-syskeys 0 -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1

# 界面上找带某段字的节点，打印它的中心坐标；找不到返回 1。
find_text() {
  "${ADB[@]}" shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1 || return 1
  "${ADB[@]}" pull /sdcard/ui.xml "$WORK/ui.xml" >/dev/null 2>&1 || return 1
  python3 - "$WORK/ui.xml" "$1" <<'EOF'
import re, sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
for node in root.iter('node'):
    label = (node.get('text') or '') + '\n' + (node.get('content-desc') or '')
    if sys.argv[2] in label:
        x1, y1, x2, y2 = map(int, re.findall(r'\d+', node.get('bounds')))
        print((x1 + x2) // 2, (y1 + y2) // 2)
        sys.exit(0)
sys.exit(1)
EOF
}
wait_text() {
  for _ in $(seq 1 30); do find_text "$1" && return 0; sleep 1; done
  echo "等不到「$1」" >&2; return 1
}
tap_text() { local xy; xy=$(wait_text "$1") && "${ADB[@]}" shell input tap $xy; }

tap_text '设置'
sleep 1
# 往下翻到「终端引擎」那一块。
for _ in $(seq 1 10); do
  find_text '终端引擎' >/dev/null && break
  "${ADB[@]}" shell input swipe 500 1600 500 700 300
  sleep 0.6
done
"${ADB[@]}" shell input swipe 500 1300 500 1000 300   # 再往上带一点，让「检查」整个露出来
sleep 0.6
tap_text '检查'
sleep 2
"${ADB[@]}" exec-out screencap -p > "$WORK/engine.png"
if find_text '正常，这次运行建过的终端：1' >/dev/null; then
  RESULT=OK
else
  RESULT=FAIL
  find_text '无法启动' >/dev/null && echo "界面上是「无法启动」" >&2
fi
VERSION=$(grep -o 'Ghostty [0-9][^"&]*' "$WORK/ui.xml" | head -1 || true)
echo "终端引擎：${RESULT}（${VERSION:-没读到版本}）"
"${ADB[@]}" logcat -d -s AndroidRuntime:E | grep -E 'FATAL' && RESULT=FAIL || echo "logcat 里没有 FATAL"
echo "截图 $WORK/engine.png"
"${ADB[@]}" uninstall "$PKG" >/dev/null 2>&1 || true
[[ "$RESULT" == OK ]]
