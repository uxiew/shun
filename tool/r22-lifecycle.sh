#!/usr/bin/env bash
# R22 设备测试（integration_test/r22_lifecycle_test.dart）的电脑这一头：转发端口、预授权通知、
# 按测试打出的 "R22 ACTION=<名字>" 在手机或测试环境上做事，做完在 App 私有目录放 r22/<名字> 告诉测试。
#
#   source ../.toolchain/env.sh
#   (cd tool/fixture-environment && ./up.sh)
#   tool/r22-lifecycle.sh emulator-5580 notify|svcstop|network|lock|proxy|activity|engine
#   tool/r22-lifecycle.sh emulator-5580 restore      # 进程被结束后放回标签：先 seed，再装正式 debug 包用 uiautomator 点
#
# 只在模拟器上跑过：要 adb root（停服务、数 App 的 socket），会开关模拟器的 Wi-Fi、设锁屏 PIN（测完清掉）、
# 临时打开「不保留活动」（测完关掉）。真机上别跑：会改手机设置。
# 日志、截图、meminfo 放在 ../.toolchain/artifacts/r22-<提交>/，最后打印路径。
# 不开 pipefail：下面很多 `… | grep -m1` 会让前面的 adb 收到 SIGPIPE，开着的话整个脚本悄悄退出。
set -eu
cd "$(dirname "$0")/.."

SERIAL=${1:?用法：tool/r22-lifecycle.sh <设备序列号> <场景>}
SCENARIO=${2:?用法：tool/r22-lifecycle.sh <设备序列号> <场景>}
export ANDROID_SERIAL=$SERIAL
PKG=top.xdwa.xwshun
OUT=../.toolchain/artifacts/r22-$(git rev-parse --short HEAD)
mkdir -p "$OUT"
LOG=$OUT/$SCENARIO-$(date +%H%M%S).log
: > "$LOG"
host() { echo "R22HOST $*" | tee -a "$LOG"; }

container() { docker ps -a --format '{{.Names}}' | grep -m1 "xwshun-fixture-$1"; }
EDGE=$(container ssh-edge)
accepted() { docker logs "$EDGE" 2>&1 | grep -c 'Accepted' || true; }

CONFIG=$(python3 - <<'EOF'
import json, pathlib
f = json.loads(pathlib.Path('tool/fixture-environment/.run/fixture.json').read_text())
print(json.dumps({
    'user': f['user'], 'password': f['password'],
    'edge': {'port': f['sshEdge']['port'], 'fingerprint': f['sshEdge']['fingerprintSha256'],
             'keyType': f['sshEdge']['keyType']},
    'socks': {'port': f['socksAuth']['port'], 'username': f['socksAuth']['username'],
              'password': f['socksAuth']['password']},
    'target': {'name': f['target']['name'], 'port': f['target']['port'],
               'fingerprint': f['target']['fingerprintSha256']},
}))
EOF
)

# adb root 会重启 adbd、清掉端口转发，先 root 再 reverse。
adb root >/dev/null 2>&1 || true
adb wait-for-device
adb reverse tcp:22201 tcp:22201 >/dev/null
adb reverse tcp:21080 tcp:21080 >/dev/null
adb shell svc wifi enable
(for _ in $(seq 1 900); do
  adb shell pm grant $PKG android.permission.POST_NOTIFICATIONS 2>/dev/null && break
  sleep 0.3
done >/dev/null 2>&1 &)

# App 里连到 22201（十六进制 56B9）的 TCP，按 App 自己的 socket inode 筛。
ssh_sockets() {
  local pid inodes
  pid=$(adb shell pidof $PKG | tr -d '\r')
  [[ -n "$pid" ]] || { echo "没有进程"; return; }
  inodes=$(adb shell "ls -l /proc/$pid/fd" 2>/dev/null | grep -o 'socket:\[[0-9]*\]' | grep -o '[0-9]*' | sort -u)
  adb shell "cat /proc/$pid/net/tcp /proc/$pid/net/tcp6" 2>/dev/null |
    awk -v inodes="$(echo $inodes)" 'BEGIN{n=split(inodes,a," "); for(i=1;i<=n;i++) mine[a[i]]=1}
      $3 ~ /:56B9$/ && ($10 in mine) && $4 == "01" {c++} END{print c+0}'
}

# LIFE01 和「不复活」看的几样：服务在不在、前台服务类型、本 App 拿着的唤醒锁和 Wi-Fi 锁、通知、进程、SSH 连接数。
# 原始输出存一份，grep 不到时回去看格式。
lifecycle_facts() {
  local uid
  uid=$(adb shell cmd package list packages -U $PKG | grep -o 'uid:[0-9]*' | cut -d: -f2 | tr -d '\r') || true
  adb shell dumpsys activity services $PKG > "$OUT/$1-services.txt" 2>&1 || true
  adb shell dumpsys power > "$OUT/$1-power.txt" 2>&1 || true
  adb shell dumpsys notification --noredact > "$OUT/$1-notification.txt" 2>&1 || true
  host "$1 service=$(grep -c 'SshKeepAliveService' "$OUT/$1-services.txt" || true)" \
    "fgs=$(grep -m1 -oE 'foregroundServiceType=[0-9a-fx]+|types=[0-9a-fx]+' "$OUT/$1-services.txt" || echo -)" \
    "isForeground=$(grep -m1 -o 'isForeground=[a-z]*' "$OUT/$1-services.txt" || echo -)"
  host "$1 wakelocks(uid $uid)=$(sed -n '/^Wake Locks:/,/^$/p' "$OUT/$1-power.txt" | grep -c "uid=$uid\|$PKG" || true)" \
    "wifilocks=$(adb shell dumpsys wifi | grep -iE 'WifiLock|lock' | grep -c "$PKG" || true)" \
    "notification=$(grep -c "pkg=$PKG" "$OUT/$1-notification.txt" || true)" \
    "pid=$(adb shell pidof $PKG | tr -d '\r')" "ssh-sockets=$(ssh_sockets)" "edge-accepted=$(accepted)"
}

# uiautomator 找到文字（或包含它的）控件，点中心。
tap_text() {
  adb shell uiautomator dump /sdcard/r22-ui.xml >/dev/null 2>&1
  adb pull /sdcard/r22-ui.xml "$OUT/ui.xml" >/dev/null 2>&1
  python3 - "$OUT/ui.xml" "$1" <<'EOF'
import re, sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
for node in root.iter('node'):
    label = (node.get('text') or '') + ' ' + (node.get('content-desc') or '')
    if sys.argv[2] in label:
        x1, y1, x2, y2 = map(int, re.findall(r'\d+', node.get('bounds')))
        print((x1 + x2) // 2, (y1 + y2) // 2)
        break
EOF
}
tap() {
  local at
  at=$(tap_text "$1")
  [[ -n "$at" ]] || { host "tap 找不到「$1」"; return 1; }
  adb shell input tap $at
  host "tap 「$1」 at $at"
}
# 本 App 的通知是 IMPORTANCE_LOW，在通知栏「静音」区默认折叠，按钮藏着：点它右边的「展开」。
expand_notification() {
  adb shell uiautomator dump /sdcard/r22-ui.xml >/dev/null 2>&1
  adb pull /sdcard/r22-ui.xml "$OUT/ui.xml" >/dev/null 2>&1
  local at
  at=$(python3 - "$OUT/ui.xml" "$1" <<'EOF2'
import re, sys, xml.etree.ElementTree as ET
nodes = list(ET.parse(sys.argv[1]).getroot().iter('node'))
box = lambda n: list(map(int, re.findall(r'\d+', n.get('bounds'))))
title = next((n for n in nodes if sys.argv[2] in (n.get('text') or '')), None)
if title is not None:
    cy = (box(title)[1] + box(title)[3]) // 2
    for n in nodes:
        if (n.get('resource-id') or '').endswith('expand_button') and (n.get('content-desc') or '') == 'Expand':
            x1, y1, x2, y2 = box(n)
            if y1 <= cy <= y2:
                print((x1 + x2) // 2, (y1 + y2) // 2)
                break
EOF2
)
  [[ -n "$at" ]] && adb shell input tap $at && host "expanded notification at $at"
}
# 开发者选项里点「Don't keep activities」（开、关都是点一下），点完回桌面。
toggle_dont_keep() {
  adb shell settings put global development_settings_enabled 1
  # 设置 App 会接着上次滚到的位置，先强停，从顶上往下找。条目文字是弯撇号的「Don’t keep activities」。
  adb shell am force-stop com.android.settings
  adb shell am start -a android.settings.APPLICATION_DEVELOPMENT_SETTINGS >/dev/null; sleep 2
  local i
  for i in $(seq 1 40); do
    if [[ -n "$(tap_text "keep activities")" ]]; then
      # 再往上推一点，免得点在屏幕底部的手势区里。
      adb shell input swipe 540 1600 540 1200 300; sleep 0.8
      tap "keep activities" >/dev/null 2>&1
      break
    fi
    adb shell input swipe 540 1800 540 1000 300; sleep 0.8
  done
  sleep 1
  host "toggled don't keep activities: $(adb shell settings get global always_finish_activities | tr -d '\r')"
  adb shell input keyevent KEYCODE_HOME; sleep 1
}
has_text() { adb shell uiautomator dump /sdcard/r22-ui.xml >/dev/null 2>&1; adb shell cat /sdcard/r22-ui.xml | grep -c -- "$1" || true; }
shot() { adb exec-out screencap -p > "$OUT/$1.png" || true; }
foreground() { adb shell monkey -p $PKG -c android.intent.category.LAUNCHER --pct-syskeys 0 1 >/dev/null 2>&1; }

do_action() {
  local name=$1
  case "$name" in
    home) adb shell input keyevent KEYCODE_HOME; sleep 2; lifecycle_facts "after-home" ;;
    foreground)
      foreground; sleep 3; shot "$SCENARIO-foreground-$(date +%H%M%S)"
      lifecycle_facts "after-foreground" ;;
    notify-stop)
      lifecycle_facts "before-notify-stop"
      adb shell cmd statusbar expand-notifications; sleep 2; shot "$SCENARIO-shade"
      if ! tap "全部断开"; then
        expand_notification "xwshun 终端" || true; sleep 2; shot "$SCENARIO-shade-expanded"
        tap "全部断开"
      fi
      sleep 4; adb shell cmd statusbar collapse; lifecycle_facts "after-notify-stop" ;;
    stop-service)
      lifecycle_facts "before-stop-service"
      adb shell am stopservice -n $PKG/app.netcatty.mobile.SshKeepAliveService | tee -a "$LOG"
      sleep 4; lifecycle_facts "after-stop-service" ;;
    wifi-toggle)
      adb shell svc wifi disable; sleep 4; adb shell svc wifi enable; sleep 4
      lifecycle_facts "after-wifi-toggle" ;;
    cellular-only)
      adb shell svc wifi disable; sleep 5
      host "data=$(adb shell dumpsys telephony.registry | grep -m1 -o 'mDataRegState=[0-9]([A-Z_]*)')" ;;
    wifi-cycle)
      for i in $(seq 1 20); do
        local on=8 off=12
        (( i > 10 )) && on=45 && off=20
        host "cycle $i wifi on (${on}s) $(date +%T)"; adb shell svc wifi enable; sleep $on
        host "cycle $i wifi off (${off}s) $(date +%T) sockets=$(ssh_sockets)"; adb shell svc wifi disable; sleep $off
      done
      lifecycle_facts "after-wifi-cycle" ;;
    home-lock)
      adb shell locksettings set-pin 1234 >/dev/null
      adb shell input keyevent KEYCODE_HOME; sleep 1
      # 「按电源键立即锁定」只管电源键；KEYCODE_SLEEP 可能要等「息屏后多久锁定」（默认 5 秒）才真锁上。
      adb shell input keyevent KEYCODE_SLEEP; sleep 8
      host "locked: $(adb shell dumpsys window | grep -m1 -oE 'mDreamingLockscreen=[a-z]+|isKeyguardShowing=[a-z]+' || echo ?)"
      lifecycle_facts "after-lock" ;;
    kill-server-sessions)
      host "edge-accepted-before-kill=$(accepted)"
      docker exec "$EDGE" pkill -f 'sshd.*fixture' || true
      sleep 2; lifecycle_facts "after-kill" ;;
    unlock-foreground)
      host "edge-accepted-while-locked=$(accepted)"
      adb shell input keyevent KEYCODE_WAKEUP; sleep 1
      adb shell input swipe 540 1900 540 700 300; sleep 1
      adb shell input text 1234; adb shell input keyevent KEYCODE_ENTER; sleep 2
      foreground; sleep 4
      adb shell locksettings clear --old 1234 >/dev/null || true
      lifecycle_facts "after-unlock" ;;
    socks-stop) docker stop "$(container socks)" >/dev/null; host "socks stopped $(date +%T)" ;;
    socks-start) docker start "$(container socks)" >/dev/null; host "socks started $(date +%T)" ;;
    target-restart) docker restart "$(container target)" >/dev/null; host "target restarted (same host key) $(date +%T)" ;;
    target-rekey)
      # 删掉入口脚本的标记再重启，容器重新生成主机密钥（见 tool/fixture-environment/entrypoint.sh）。
      # 之后 .run/fixture.json 里 target 的指纹就旧了，用完要重新 up.sh。
      docker exec "$(container target)" rm -f /etc/ssh/.xwshun-hostkey
      docker restart "$(container target)" >/dev/null; host "target restarted with a new host key $(date +%T)" ;;
    back)
      host "before back: MainActivity records alive: $(adb shell dumpsys activity activities | grep -cE "Hist +#[0-9]+: ActivityRecord\{[^}]* $PKG/app.netcatty.mobile.MainActivity" || true)" \
        "recent tasks of the app: $(adb shell dumpsys activity recents | grep -cE "Recent #[0-9]+: Task\{[^}]*$PKG" || true)"
      adb shell input keyevent KEYCODE_BACK; sleep 2
      host "after back: $(adb shell dumpsys activity activities | grep -m1 -E 'topResumedActivity|mResumedActivity')"
      lifecycle_facts "after-back" ;;
    dont-keep-activities)
      # 只 settings put 不生效：ActivityManager 要经开发者选项里的开关（setAlwaysFinish）才读。点那个开关；
      # 开关只管之后进后台的 Activity，所以开完回到 App 再按 HOME。
      toggle_dont_keep
      foreground; sleep 3
      adb shell input keyevent KEYCODE_HOME; sleep 4
      # 「不保留活动」销毁 Activity 实例但留着记录（回来时按记录重建）：看记录的 state，DESTROYED 才算真销毁了。
      host "MainActivity record: $(adb shell dumpsys activity activities | grep -A40 -E "Hist +#[0-9]+: ActivityRecord\{[^}]* $PKG/app.netcatty.mobile.MainActivity" | grep -m1 -oE 'state=[A-Z_]+')"
      lifecycle_facts "after-dont-keep"
      toggle_dont_keep
      host "always_finish_activities=$(adb shell settings get global always_finish_activities | tr -d '\r')" ;;
    recents-swipe)
      adb shell input keyevent KEYCODE_APP_SWITCH; sleep 2; shot "$SCENARIO-recents"
      adb shell input swipe 540 1300 540 150 250; sleep 2
      adb shell input keyevent KEYCODE_HOME; sleep 2
      host "recent tasks of the app: $(adb shell dumpsys activity recents | grep -cE "Recent #[0-9]+: Task\{[^}]*$PKG" || true)" \
        "MainActivity records alive: $(adb shell dumpsys activity activities | grep -cE "Hist +#[0-9]+: ActivityRecord\{[^}]* $PKG/app.netcatty.mobile.MainActivity" || true)"
      lifecycle_facts "after-recents-swipe" ;;
    shot-*) shot "${name#shot-}" ;;   # 测试出完帧再请脚本截图（集成测试只在 pump 时出帧，等回执时屏幕是黑的）
    mem-*)
      adb shell dumpsys meminfo $PKG > "$OUT/$name.txt"
      host "$name $(grep -m1 'Native Heap' "$OUT/$name.txt" | awk '{print "native-pss-kb="$3, "native-heap-alloc-kb="$(NF-1)}') total-pss-kb=$(grep -m1 'TOTAL PSS' "$OUT/$name.txt" | awk '{print $3}')" ;;
    *) host "不认识的动作 $name"; return 1 ;;
  esac
  # adb shell 把参数拼成一行交给手机的 sh，里层命令要自己再包一层引号。
  adb shell "run-as $PKG sh -c 'mkdir -p files/r22 && touch files/r22/$name'"
}

run_test() {
  local scenario=$1 tool=${2:-test}
  local args=(integration_test/r22_lifecycle_test.dart -d "$SERIAL"
    --dart-define=R22_SCENARIO="$scenario" --dart-define=R22_CONFIG="$CONFIG")
  if [[ $tool == drive ]]; then
    flutter drive --driver test_driver/integration_test.dart --target "${args[@]}" --keep-app-running >> "$LOG" 2>&1 &
  else
    flutter test "${args[@]}" >> "$LOG" 2>&1 &
  fi
  TEST=$!
}

serve_actions() {
  local seen=0
  while kill -0 "$TEST" 2>/dev/null; do
    local count
    count=$(grep -c 'R22 ACTION=' "$LOG" || true)
    while (( seen < count )); do
      seen=$((seen + 1))
      do_action "$(grep 'R22 ACTION=' "$LOG" | sed -n "${seen}p" | sed 's/.*R22 ACTION=//' | tr -d '\r')"
    done
    [[ -n "${STOP_WHEN:-}" ]] && grep -q "$STOP_WHEN" "$LOG" && return 0
    sleep 0.5
  done
}

restore() {
  host "build the real debug app (the test run overwrites app-debug.apk)"
  flutter build apk --debug --target-platform android-arm64 >> "$LOG" 2>&1
  cp build/app/outputs/flutter-apk/app-debug.apk "$OUT/app-debug.apk"
  adb uninstall $PKG >/dev/null 2>&1 || true
  STOP_WHEN='R22 SEEDED'
  run_test seed drive
  serve_actions
  sleep 2
  host "seeded: $(grep -m1 'R22 SEEDED=' "$LOG" | sed 's/.*SEEDED=//')"
  host "tmux clients before: $(docker exec -u fixture "$EDGE" tmux list-clients -t r22 2>&1 | wc -l | tr -d ' ')"
  lifecycle_facts "seeded"
  local before
  before=$(accepted)
  for kill in stop-app force-stop; do
    if [[ $kill == stop-app ]]; then
      adb shell cmd activity stop-app $PKG   # 「任务管理器」里的停止：杀进程、不回调
    else
      adb shell am force-stop $PKG
    fi
    kill "$TEST" 2>/dev/null || true
    sleep 3
    host "$kill: pid=$(adb shell pidof $PKG | tr -d '\r') service=$(adb shell dumpsys activity services $PKG | grep -c SshKeepAliveService || true)"
    adb shell svc wifi disable; sleep 4; adb shell svc wifi enable; sleep 16
    host "$kill +20s with network change: pid=$(adb shell pidof $PKG | tr -d '\r') edge-accepted-delta=$(( $(accepted) - before ))" \
      "tmux clients=$(docker exec -u fixture "$EDGE" tmux list-clients -t r22 2>/dev/null | wc -l | tr -d ' ')"
    if [[ $kill == stop-app ]]; then
      adb install -r "$OUT/app-debug.apk" >/dev/null
      host "installed the real debug app over the test build (data kept: $(adb shell run-as $PKG ls shared_prefs 2>/dev/null | tr '\n' ' '))"
    fi
    foreground; sleep 6; shot "restore-$kill-opened"
    host "$kill reopened: banner=$(has_text '上次 App 被结束了') reconnect=$(has_text '重新连接') edge-accepted-delta=$(( $(accepted) - before ))"
    tap "重新连接"; sleep 6; shot "restore-$kill-reconnected-plain"
    host "$kill plain reconnect: edge-accepted-delta=$(( $(accepted) - before )) ssh-sockets=$(ssh_sockets)"
    tap "tmux: r22"; sleep 2
    tap "重新连接"; sleep 6; shot "restore-$kill-reconnected-tmux"
    host "$kill tmux reconnect: clients=$(docker exec -u fixture "$EDGE" tmux list-clients -t r22 2>/dev/null | wc -l | tr -d ' ')" \
      "session ids=$(docker exec -u fixture "$EDGE" tmux list-sessions -F '#{session_id}:#{session_name}' 2>/dev/null | tr '\n' ' ')"
    before=$(accepted)
  done
  adb shell am force-stop $PKG
  docker exec -u fixture "$EDGE" tmux kill-session -t r22 2>/dev/null || true
  adb uninstall $PKG >/dev/null 2>&1 || true
}

if [[ $SCENARIO == restore ]]; then
  restore
else
  run_test "$SCENARIO"
  serve_actions
  wait "$TEST" && host "test exit=0" || host "test exit=$?"
fi
# 收尾：设置复原。
[[ "$(adb shell settings get global always_finish_activities | tr -d '\r')" == 1 ]] && toggle_dont_keep
adb shell svc wifi enable
adb shell locksettings clear --old 1234 >/dev/null 2>&1 || true
grep -E '^R22HOST|R22 ' "$LOG" | grep -v 'R22 ACTION' | sed 's/^I\/flutter ([0-9 ]*): //' > "$OUT/$SCENARIO-summary.txt" || true
echo "日志：$LOG"
echo "摘要：$OUT/$SCENARIO-summary.txt"
