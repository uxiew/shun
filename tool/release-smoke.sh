#!/usr/bin/env bash
# 发布包冒烟（REL03）：把 tool/build-release.sh 打出的包装到一台设备上，打开 App，
# 点「设置 → 外观与终端 → 终端引擎 → 检查」，看界面上是不是「正常，这次运行建过的终端：1」。
# 这一步真去加载包里的 libghostty.so、建一个终端再关掉：证明这个包的原生库在这台设备（API、页大小）上能用。
# release 包里没有测试框架，所以用 uiautomator 读界面、adb 点按（Flutter 把文字交给无障碍层，uiautomator 看得见）。
#
#   tool/release-smoke.sh <设备序列号> [APK，默认 build/app/outputs/flutter-apk/app-release.apk]
#
# 会先卸掉设备上的 App（清掉它的数据），测完再卸掉。
#
# 真机（所有者的日用手机）上多三条规矩，都是为了不碰到 App 以外的东西：
# - 手机上已经装着 top.xdwa.xwshun 就不跑：卸掉会清掉所有者的数据，要所有者自己先处理。
# - 每次点按、滑动前确认前台是本 App、没锁屏；不是就停（锁屏后点下去会落在锁屏或别的 App 上）。
# - 不用 monkey 启动（它除了启动还会注入随机事件），不 logcat -c（清掉的是所有者整台手机的日志）。
set -euo pipefail
cd "$(dirname "$0")/.."

SERIAL=${1:?用法：tool/release-smoke.sh <设备序列号> [APK]}
APK=${2:-build/app/outputs/flutter-apk/app-release.apk}
ADB=(adb -s "$SERIAL")
WORK=$(mktemp -d -t release-smoke)
PKG=top.xdwa.xwshun
# Activity 的 Kotlin 包名沿用原项目（app.netcatty.mobile），和 applicationId 不一样。
ACTIVITY=$PKG/app.netcatty.mobile.MainActivity
# 界面导出放 /data/local/tmp，测完删掉：放 /sdcard 会在所有者的存储里留文件。
UI_DUMP=/data/local/tmp/xwshun-smoke-ui.xml

if [[ "$("${ADB[@]}" emu avd name 2>/dev/null | head -1 | tr -d '\r')" != "" ]]; then
  REAL=0
else
  REAL=1
  "${ADB[@]}" shell pm list packages "$PKG" | tr -d '\r' | grep -qx "package:$PKG" \
    && { echo "真机上已经装着 $PKG，卸掉会清掉它的数据：先让所有者自己处理" >&2; exit 1; }
fi

# 前台是不是本 App、手机是不是亮着没锁；真机上每次点按前都查。
assert_foreground() {
  (( REAL )) || return 0
  local win power
  win=$("${ADB[@]}" shell dumpsys window | tr -d '\r')
  power=$("${ADB[@]}" shell dumpsys power | tr -d '\r')
  grep -q 'mWakefulness=Awake' <<<"$power" || { echo "屏幕没亮，停下" >&2; exit 1; }
  grep -q 'isKeyguardShowing=true' <<<"$win" && { echo "手机锁着，停下（要所有者解锁）" >&2; exit 1; }
  grep -E 'mCurrentFocus=' <<<"$win" | grep -q "$PKG" \
    || { echo "前台不是本 App（$(grep -m1 -o 'mCurrentFocus=.*' <<<"$win")），停下" >&2; exit 1; }
}

API=$("${ADB[@]}" shell getprop ro.build.version.sdk | tr -d '\r')
# Android 7.0 的 toybox 没有 getconf：读不到就照实写。
PAGE=$("${ADB[@]}" shell getconf PAGE_SIZE 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+$' || echo '读不到')
ABI=$("${ADB[@]}" shell getprop ro.product.cpu.abi | tr -d '\r')
MODEL=$("${ADB[@]}" shell getprop ro.product.model | tr -d '\r')
echo "设备：${MODEL}（$( (( REAL )) && echo 真机 || echo 模拟器)），API ${API}，页大小 ${PAGE}，ABI ${ABI}"
echo "APK：$(shasum -a 256 "$APK" | cut -c1-16)…"
(( REAL )) || "${ADB[@]}" uninstall "$PKG" >/dev/null 2>&1 || true
"${ADB[@]}" install "$APK" >/dev/null
# 不管中途哪一步停下（包括 assert_foreground 叫停），都删掉界面导出、卸掉 App。
cleanup() {
  "${ADB[@]}" shell rm -f "$UI_DUMP" >/dev/null 2>&1 || true
  "${ADB[@]}" uninstall "$PKG" >/dev/null 2>&1 || true
}
trap cleanup EXIT
if (( REAL )); then
  # 只看装完之后的日志：记下手机上的时间，最后 logcat -T 从这一刻读起。
  SINCE=$("${ADB[@]}" shell date +%s | tr -d '\r').000
  "${ADB[@]}" shell am start -W -n "$ACTIVITY" >/dev/null
else
  "${ADB[@]}" logcat -c 2>/dev/null || true
  # 模拟器上用 monkey 发一次启动意图（API 24/35/36 三台都这么验过）；--pct-syskeys 0：没有物理系统键的模拟器（API 36）上
  # 不加会报 SYS_KEYS has no physical keys、退出码 251（App 其实已经打开）。
  "${ADB[@]}" shell monkey --pct-syskeys 0 -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
fi

# 界面上找带某段字的节点，打印它的中心坐标；找不到返回 1。
find_text() {
  "${ADB[@]}" shell uiautomator dump "$UI_DUMP" >/dev/null 2>&1 || return 1
  "${ADB[@]}" pull "$UI_DUMP" "$WORK/ui.xml" >/dev/null 2>&1 || return 1
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
tap_text() { local xy; xy=$(wait_text "$1") && assert_foreground && "${ADB[@]}" shell input tap $xy; }
swipe() { assert_foreground; "${ADB[@]}" shell input swipe "$@"; }

tap_text '设置'
sleep 1
# 往下翻到「终端引擎」那一块。
for _ in $(seq 1 10); do
  find_text '终端引擎' >/dev/null && break
  swipe 500 1600 500 700 300
  sleep 0.6
done
swipe 500 1300 500 1000 300   # 再往上带一点，让「检查」整个露出来
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
# 只算本 App 的崩溃：真机上别的 App 同一时段崩了也会打 FATAL EXCEPTION，下一行 Process: 才分得出是谁。
LOGCAT=(logcat -d -s AndroidRuntime:E)
(( REAL )) && LOGCAT+=(-T "$SINCE")
"${ADB[@]}" "${LOGCAT[@]}" | grep -A1 'FATAL' | grep "Process: $PKG" && RESULT=FAIL || echo "logcat 里没有本 App 的 FATAL"
echo "截图 $WORK/engine.png"
[[ "$RESULT" == OK ]]
