#!/usr/bin/env bash
# X10 设备测试（integration_test/x10_mosh_lifecycle_test.dart）的电脑这一头：按测试打出的 "X10 ACTION=<名字>"
# 开关模拟器的 Wi-Fi / 蜂窝数据、按 HOME、点通知、杀 mosh-client / 插件 / 宿主，并记下进程、网络和测试环境的计数；
# 做完在 App 私有目录放 x10/<名字> 告诉测试。
#
#   source ../.toolchain/env.sh
#   (cd tool/mosh-fixture && ./up.sh)
#   adb -s emulator-5580 install -r plugins/mosh/build/outputs/apk/release/mosh-release.apk
#   tool/x10-mosh.sh emulator-5580 roam              # MOS06：换网、断网、后台换网
#   tool/x10-mosh.sh emulator-5580 life              # MOS07 / PLG16：后台、各种崩溃和停止，旁边开着 SSH
#   tool/x10-mosh.sh emulator-5580 hostkill crash|force-stop   # 杀宿主，再装正式 debug 包放回标签、点「重新连接」
#   (cd tool/fixture-environment && ./up.sh)
#   tool/x10-mosh.sh emulator-5580 socks             # 验收 3：经本机 SOCKS5（TailSocks 的形态）的 SSH + tmux，旁边 Mosh 出事不受牵连
#
# 只在模拟器上跑：会开关 Wi-Fi 和蜂窝数据、用 input 点屏幕。不要 adb root（shun-r39-a30 是带 Play 的镜像，没有 root）。
# 「崩溃」怎么造：这台镜像的 SELinux 不让 run-as 给应用进程发 SIGKILL（logcat 里 avc: denied { sigkill }，
# kill 返回 1；X09 在 API 35 镜像上能杀），普通信号放行。所以 mosh-client 发 SIGSEGV（就是原生代码段错误的样子），
# 插件和宿主用 `am crash`（让进程真报一次未捕获异常、被系统收掉）。
# 模拟器上 TCP 经 10.0.2.2 只在蜂窝上通，所以每个动作做完都回到「只有蜂窝」，只有 wifi-on 例外。
# 日志和摘要在 ../.toolchain/artifacts/x10-<提交>/，最后打印路径。
# 不开 pipefail：下面的 `… | grep -m1` 会让前面的 adb 收到 SIGPIPE，开着的话整个脚本悄悄退出。
set -eu
cd "$(dirname "$0")/.."

SERIAL=${1:?用法：tool/x10-mosh.sh <模拟器序列号> roam|life|hostkill [crash|force-stop]}
SCENARIO=${2:?用法：tool/x10-mosh.sh <模拟器序列号> roam|life|hostkill [crash|force-stop]}
KILL=${3:-force-stop}
case "$SERIAL" in
  emulator-*) ;;
  *) echo "只在模拟器上跑（会开关网络、点屏幕、杀进程）" >&2; exit 1 ;;
esac
export ANDROID_SERIAL=$SERIAL
PKG=top.xdwa.shun.debug
PLUGIN=top.xdwa.shun.mosh
OUT=../.toolchain/artifacts/x10-$(git rev-parse --short HEAD)
mkdir -p "$OUT"
TAG=$SCENARIO$([[ $SCENARIO == hostkill ]] && echo "-$KILL" || true)
LOG=$OUT/$TAG-$(date +%H%M%S).log
: > "$LOG"
host() { echo "X10HOST $(date +%T) $*" | tee -a "$LOG"; }

counts() { tool/mosh-fixture/counts.sh 2>/dev/null || echo '{}'; }
starts() { counts | python3 -c 'import json,sys; print(json.load(sys.stdin).get("moshServerStarts", "?"))'; }

# 默认网络：编号 + 传输类型（WIFI / CELLULAR），没有就是 none。
default_net() {
  local id
  id=$(adb shell dumpsys connectivity | grep -m1 'Active default network' | awk '{print $NF}' | tr -d '\r')
  if [[ -z "$id" || "$id" == none ]]; then echo none; return; fi
  echo "$id/$(adb shell dumpsys connectivity | grep -m1 "network{$id}" | grep -oE 'Transports: [A-Z|]+' | cut -d' ' -f2)"
}
wait_net() {   # 等到默认网络符合（WIFI / CELLULAR / none），最多 40 秒
  local want=$1 i net
  for i in $(seq 1 80); do
    net=$(default_net)
    if [[ $want == none && $net == none ]] || [[ $want != none && $net == *"$want"* ]]; then
      host "default network $net after $((i / 2)) s"
      return 0
    fi
    sleep 0.5
  done
  host "等默认网络变成 $want 超时（现在 $net）"
}

plugin_pid() { adb shell pidof $PLUGIN | tr -d '\r' || true; }
host_pid() { adb shell pidof $PKG | tr -d '\r' || true; }
# 插件进程的子进程就是 mosh-client（exec 的是插件里的 libmoshclient.so）。
client_pids() {
  local p
  p=$(plugin_pid)
  [[ -n "$p" ]] || return 0
  adb shell ps -A -o PID,PPID,NAME | awk -v p="$p" '$2 == p {printf "%s ", $1}'
}
# mosh-client 的 UDP socket：本地地址:端口 -> 对端（没 connect 的是 0.0.0.0:0）。换端口（mosh 的 port hop）时本地端口会变。
client_udp() {
  local c inodes
  for c in $(client_pids); do
    inodes=$(adb shell "run-as $PLUGIN ls -l /proc/$c/fd" 2>/dev/null | grep -o 'socket:\[[0-9]*\]' | grep -o '[0-9]*' | tr '\n' ' ')
    adb shell cat /proc/net/udp 2>/dev/null | python3 -c '
import sys
want = set(sys.argv[1].split())
def addr(h):
    ip, port = h.split(":")
    return ".".join(str(int(ip[i:i+2], 16)) for i in (6, 4, 2, 0)) + ":" + str(int(port, 16))
for line in sys.stdin:
    f = line.split()
    if len(f) > 9 and f[9] in want:
        print(f"{addr(f[1])}->{addr(f[2])}", end=" ")
' "$inodes"
  done
}
pids() {
  host "pids $1: host=$(host_pid) plugin=$(plugin_pid) mosh-client=[$(client_pids)] udp=[$(client_udp)] net=$(default_net) counts=$(counts)"
}

# 后台时看的：保活服务、前台服务类型、插件有没有自己的前台服务、三个进程的 oom_score_adj、通知写了什么、
# 两个包拿着的唤醒锁、媒体会话和音频焦点（PLG16：没有假媒体保活）。原始输出存一份。
facts() {
  local f=$OUT/$TAG-$1 hp pp c uid_h uid_p
  adb shell dumpsys activity services $PKG > "$f-services-host.txt" 2>&1 || true
  adb shell dumpsys activity services $PLUGIN > "$f-services-plugin.txt" 2>&1 || true
  adb shell dumpsys activity processes > "$f-processes.txt" 2>&1 || true
  adb shell dumpsys notification --noredact > "$f-notification.txt" 2>&1 || true
  adb shell dumpsys power > "$f-power.txt" 2>&1 || true
  adb shell dumpsys media_session > "$f-media.txt" 2>&1 || true
  adb shell dumpsys audio > "$f-audio.txt" 2>&1 || true
  hp=$(host_pid); pp=$(plugin_pid)
  uid_h=$(adb shell cmd package list packages -U $PKG | grep -o 'uid:[0-9]*' | cut -d: -f2 | tr -d '\r') || true
  uid_p=$(adb shell cmd package list packages -U $PLUGIN | grep -o 'uid:[0-9]*' | cut -d: -f2 | tr -d '\r') || true
  host "$1 host: keepalive=$(grep -c 'SshKeepAliveService' "$f-services-host.txt" || true)" \
    "$(grep -m1 -oE 'isForeground=[a-z]+' "$f-services-host.txt" || echo isForeground=-)" \
    "$(grep -m1 -oE 'foregroundServiceType=[0-9a-fx]+|types=0x[0-9a-f]+' "$f-services-host.txt" || echo types=-)" \
    "oom_score_adj=$([[ -n $hp ]] && adb shell cat /proc/$hp/oom_score_adj | tr -d '\r' || echo -)"
  host "$1 plugin: services=$(grep -c 'ServiceRecord{' "$f-services-plugin.txt" || true)" \
    "$(grep -m1 -oE 'isForeground=[a-z]+' "$f-services-plugin.txt" || echo isForeground=-)" \
    "oom_score_adj=$([[ -n $pp ]] && adb shell cat /proc/$pp/oom_score_adj | tr -d '\r' || echo -)" \
    "mosh-client oom_score_adj=$(for c in $(client_pids); do adb shell cat /proc/$c/oom_score_adj | tr -d '\r'; done)"
  host "$1 lru: $(grep -E "^ +#[0-9]+: .*($PKG|$PLUGIN)" "$f-processes.txt" | sed 's/  */ /g' | tr '\n' ';')"
  host "$1 notification: $(grep -A40 "pkg=$PKG" "$f-notification.txt" | grep -m2 -oE 'android\.(title|text)=[^)]*\)' | tr '\n' ' ')"
  host "$1 wakelocks host=$(sed -n '/^Wake Locks:/,/^$/p' "$f-power.txt" | grep -c "uid=$uid_h\|$PKG" || true)" \
    "plugin=$(sed -n '/^Wake Locks:/,/^$/p' "$f-power.txt" | grep -c "uid=$uid_p\|$PLUGIN" || true)" \
    "media-sessions=$(grep -cE "$PKG|$PLUGIN" "$f-media.txt" || true)" \
    "audio-focus=$(grep -A10 -i 'Audio Focus stack' "$f-audio.txt" | grep -cE "$PKG|$PLUGIN" || true)"
}

# LIFE06 / 跨 App 资源：两个进程各自的 Native Heap 已分配、TOTAL PSS（KiB）、fd、线程；设备上 mosh-client 几个、远端计数。
mem() {
  local who pkg pid f out=""
  for who in host plugin; do
    pkg=$([[ $who == host ]] && echo $PKG || echo $PLUGIN)
    pid=$(adb shell pidof $pkg | tr -d '\r' || true)
    [[ -n "$pid" ]] || { out+=" $who=gone"; continue; }
    f=$OUT/$TAG-mem-$1-$who.txt
    adb shell dumpsys meminfo $pid > "$f" 2>&1 || true
    out+=" $who(pid $pid) native-alloc-kb=$(grep -m1 'Native Heap' "$f" | awk '{print $(NF-1)}')"
    out+=" pss-kb=$(grep -m1 'TOTAL PSS' "$f" | awk '{print $3}')"
    out+=" fds=$(adb shell "run-as $pkg ls /proc/$pid/fd" 2>/dev/null | wc -l | tr -d ' ')"
    out+=" threads=$(adb shell "run-as $pkg cat /proc/$pid/status" 2>/dev/null | awk '/^Threads/ {print $2}')"
  done
  host "mem $1:$out mosh-client=[$(client_pids)] counts=$(counts)"
}

mosh_log() {   # 插件自己的日志（起了哪个运行时、退出码、宿主没了），只看这次跑的
  # adb logcat 自己会给参数加引号，这里不要再包一层（包了会报 not in time format）。
  adb logcat -d -v time -T "$SINCE" -s ShunMosh 2>/dev/null | grep -v '^-----' | sed 's/^/  /' || true
}

# uiautomator 找到文字（或包含它的）控件，点中心；同 tool/r22-lifecycle.sh。
tap_text() {
  adb shell uiautomator dump /sdcard/x10-ui.xml >/dev/null 2>&1
  adb pull /sdcard/x10-ui.xml "$OUT/ui.xml" >/dev/null 2>&1
  python3 - "$OUT/ui.xml" "$1" <<'EOF'
import re, sys, xml.etree.ElementTree as ET
nodes = list(ET.parse(sys.argv[1]).getroot().iter('node'))
want = sys.argv[2]
labels = lambda n: [(n.get('text') or '').strip(), (n.get('content-desc') or '').strip()]
for match in (lambda n: want in labels(n) and n.get('clickable') == 'true',
              lambda n: want in labels(n),
              lambda n: any(want in l for l in labels(n))):
    node = next((n for n in nodes if match(n)), None)
    if node is not None:
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
has_text() { adb shell uiautomator dump /sdcard/x10-ui.xml >/dev/null 2>&1; adb shell cat /sdcard/x10-ui.xml | grep -c -- "$1" || true; }
# 本 App 的通知是 IMPORTANCE_LOW，折叠在「静音」区：点它右边的「展开」。
expand_notification() {
  adb shell uiautomator dump /sdcard/x10-ui.xml >/dev/null 2>&1
  adb pull /sdcard/x10-ui.xml "$OUT/ui.xml" >/dev/null 2>&1
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
foreground() { adb shell monkey -p $PKG -c android.intent.category.LAUNCHER --pct-syskeys 0 1 >/dev/null 2>&1; }
# shun-r39-a30 上 `svc wifi enable` 只开无线电，不会自己连回 AndroidWifi（等 40 秒也是「not connected」），
# 要再点名连一次；连上后 Wi-Fi（wlan0 10.0.2.16，分数 20）压过蜂窝（radio0 10.0.2.15，分数 10）成为默认网络。
wifi_on() {
  adb shell svc wifi enable; sleep 2
  adb shell cmd wifi connect-network AndroidWifi open >/dev/null
  wait_net WIFI
}

do_action() {
  local name=$1 c p
  case "$name" in
    cellular-only) adb shell svc data enable; adb shell svc wifi disable; wait_net CELLULAR ;;
    wifi-on) wifi_on ;;
    wifi-off) adb shell svc wifi disable; wait_net CELLULAR ;;
    wifi-toggle)
      wifi_on; sleep 8
      adb shell svc wifi disable; wait_net CELLULAR ;;
    offline) adb shell svc wifi disable; adb shell svc data disable; wait_net none ;;
    online) adb shell svc data enable; wait_net CELLULAR ;;
    home)
      # 刚从后台回到前台时按的 HOME 有时不生效（life 里撞上过：按完宿主还是 fg）。「系统停服务」在前台是换代重开、
      # 在后台才收尾，所以要核对真到了后台，不对就再按。
      for p in 1 2 3; do
        adb shell input keyevent KEYCODE_HOME; sleep 2
        adb shell dumpsys activity activities | grep -m1 -E 'mResumedActivity|topResumedActivity' | grep -q "$PKG" || break
        host "HOME 后宿主还在前台，再按一次"
      done ;;
    foreground) foreground; sleep 3 ;;
    facts-*)
      facts "${name#facts-}"
      [[ $name == facts-doze ]] && host "doze: deep=$(adb shell dumpsys deviceidle get deep | tr -d '\r')" \
        "screen=$(adb shell dumpsys power | grep -m1 -oE 'mWakefulness=[A-Za-z]+')" \
        "plugin-uid-rules=$(adb shell dumpsys netpolicy | grep -m3 "UID=$(adb shell cmd package list packages -U $PLUGIN | grep -o 'uid:[0-9]*' | cut -d: -f2 | tr -d '\r') " | tr -s ' ' | tr '\n' ';')"
      true ;;
    mem-*) mem "${name#mem-}" ;;
    doze-on)
      # 息屏、装作拔了电源、强制进深度 Doze（不等系统自己计时）。
      adb shell input keyevent KEYCODE_SLEEP; sleep 1
      adb shell dumpsys battery unplug
      host "$(adb shell dumpsys deviceidle force-idle | tr -d '\r') deep=$(adb shell dumpsys deviceidle get deep | tr -d '\r')" ;;
    doze-off)
      adb shell dumpsys deviceidle unforce >/dev/null; adb shell dumpsys battery reset
      adb shell input keyevent KEYCODE_WAKEUP; sleep 1; adb shell wm dismiss-keyguard; sleep 1
      host "doze off: deep=$(adb shell dumpsys deviceidle get deep | tr -d '\r')" ;;
    pids-*) pids "${name#pids-}" ;;
    kill-client)
      c=$(client_pids)
      for p in $c; do
        adb shell run-as $PLUGIN kill -SEGV "$p" && host "SIGSEGV -> mosh-client $p" || host "发 SIGSEGV 给 $p 失败"
      done
      sleep 1; host "after: plugin=$(plugin_pid) mosh-client=[$(client_pids)]" ;;
    kill-plugin)
      p=$(plugin_pid)
      host "am crash plugin $p (mosh-client [$(client_pids)])"
      adb shell am crash $PLUGIN || host "am crash 失败"
      sleep 2
      host "after: plugin=$(plugin_pid) orphans=$(adb shell ps -A -o PID,PPID,NAME | grep -c libmoshclient || true)" ;;
    force-stop-plugin)
      host "force-stop plugin $(plugin_pid) (mosh-client [$(client_pids)])"
      adb shell am force-stop $PLUGIN; sleep 1
      host "after: plugin=$(plugin_pid) orphans=$(adb shell ps -A -o PID,PPID,NAME | grep -c libmoshclient || true)" ;;
    notify-stop)
      facts "before-notify-stop"
      adb shell cmd statusbar expand-notifications; sleep 2
      if ! tap "全部断开"; then
        expand_notification "shun" || true; sleep 2
        tap "全部断开"
      fi
      sleep 4; adb shell cmd statusbar collapse
      facts "after-notify-stop" ;;
    stop-service)
      # 没有 root：用 App 自己的 uid（run-as）去停它自己未导出的服务，效果和系统/别人停掉一样（不是 App 让停的）。
      facts "before-stop-service"
      # 要带 --user 0：不带就按「当前用户」(-2) 调，App 自己的 uid 没有 INTERACT_ACROSS_USERS，报 SecurityException。
      adb shell run-as $PKG am stopservice --user 0 -n $PKG/top.xdwa.shun.SshKeepAliveService 2>&1 | tee -a "$LOG"
      sleep 4; facts "after-stop-service" ;;
    *) host "不认识的动作 $name"; return 1 ;;
  esac
  adb shell "run-as $PKG sh -c 'mkdir -p files/x10 && touch files/x10/$name'"
}

CONFIG=$(python3 tool/mosh-fixture/x08_config.py)
SOCKS='{}'
if [[ $SCENARIO == socks ]]; then
  # TailSocks 在手机上是本机的 SOCKS5 端口；这里把测试环境的 SOCKS5 经 adb 通道搬到模拟器的 127.0.0.1，
  # 不经模拟器网络，所以 Mosh 那边换网时这条路本来就不该断，断了就是被 Mosh 牵连了。
  SOCKS=$(python3 - <<'EOF'
import json, pathlib
f = json.loads(pathlib.Path('tool/fixture-environment/.run/fixture.json').read_text())
print(json.dumps({
    'user': f['user'], 'password': f['password'],
    'socks': {'port': f['socksAuth']['port'], 'username': f['socksAuth']['username'],
              'password': f['socksAuth']['password']},
    'target': {'name': f['target']['name'], 'port': f['target']['port'],
               'fingerprint': f['target']['fingerprintSha256']},
}))
EOF
)
  adb reverse tcp:21080 tcp:21080 >/dev/null
fi
# 旁边那个普通 SSH 标签走 adb 通道（不经模拟器网络），换网时它还断就只能是被 Mosh 牵连的。
adb reverse tcp:22301 tcp:22301 >/dev/null
run_test() {
  local args=(-d "$SERIAL" --dart-define=X09_MOSH="$CONFIG" --dart-define=X10_SOCKS="$SOCKS"
    --dart-define=X10_SCENARIO="$SCENARIO")
  if [[ $SCENARIO == hostkill ]]; then
    # 宿主被杀以后 flutter test 会把测试 App 连数据卸掉（第一次跑就这样，放回标签无从测起），
    # flutter drive --keep-app-running 不卸，同 R22 的 restore。
    flutter drive --driver test_driver/integration_test.dart \
      --target integration_test/x10_mosh_lifecycle_test.dart --keep-app-running "${args[@]}" >> "$LOG" 2>&1 &
  else
    flutter test integration_test/x10_mosh_lifecycle_test.dart "${args[@]}" >> "$LOG" 2>&1 &
  fi
  TEST=$!
}
serve_actions() {
  local seen=0 count name
  while kill -0 "$TEST" 2>/dev/null; do
    count=$(grep -c 'X10 ACTION=' "$LOG" || true)
    while (( seen < count )); do
      seen=$((seen + 1))
      name=$(grep 'X10 ACTION=' "$LOG" | sed -n "${seen}p" | sed 's/.*X10 ACTION=//' | tr -d '\r')
      [[ $name == host-killed ]] && return 0
      # 动作里哪条命令失败也要照样回执：不然 set -e 让脚本退出，测试一直等、挂到超时。
      do_action "$name" || host "动作 $name 出错（rc=$?）"
    done
    sleep 0.5
  done
}

# hostkill：测试开好 SSH + Mosh 标签后，按 crash（kill -9 宿主）或 force-stop 杀掉宿主，看插件收尾、远端、有没有东西自己起来；
# 再装正式 debug 包（数据保留）打开，放回来的 Mosh 标签不该自己连，点「重新连接」才新起一个 mosh-server。
hostkill() {
  local apk=$OUT/app-debug.apk before
  if [[ ! -f $apk ]]; then
    host "build the real debug app (the test run overwrites app-debug.apk)"
    flutter build apk --debug --target-platform android-arm64 >> "$LOG" 2>&1
    cp build/app/outputs/flutter-apk/app-debug.apk "$apk"
  fi
  run_test
  serve_actions
  host "seeded: $(grep -m1 'X10 SEEDED=' "$LOG" | sed 's/.*SEEDED=//')"
  facts "seeded"
  pids "seeded"
  before=$(starts)
  if [[ $KILL == crash ]]; then
    host "am crash host $(host_pid)"
    adb shell am crash $PKG || host "am crash 失败"
  else
    host "force-stop host $(host_pid)"
    adb shell am force-stop $PKG
  fi
  kill "$TEST" 2>/dev/null || true
  local t
  for t in 1 2 3 5 10; do
    sleep 1
    host "+${t}s host=$(host_pid) plugin=$(plugin_pid) mosh-client=[$(client_pids)] counts=$(counts)"
  done
  wifi_on; sleep 8; adb shell svc wifi disable; wait_net CELLULAR
  sleep 20
  pids "after-kill+network+30s"
  facts "after-kill"
  host "plugin log:"; mosh_log | tee -a "$LOG"

  adb install -r "$apk" >/dev/null
  host "installed the real debug app over the test build (data kept: $(adb shell run-as $PKG ls shared_prefs 2>/dev/null | tr '\n' ' '))"
  foreground; sleep 8
  tap "终端" || true; sleep 2
  host "reopened: banner=$(has_text '上次 App 被结束了') reconnect=$(has_text '重新连接') startsDelta=$(( $(starts) - before )) mosh-client=[$(client_pids)]"
  adb shell uiautomator dump /sdcard/x10-ui.xml >/dev/null 2>&1; adb pull /sdcard/x10-ui.xml "$OUT/$TAG-reopened.xml" >/dev/null 2>&1
  tap "x10 mosh" || true; sleep 2
  tap "重新连接" || true; sleep 10
  adb shell uiautomator dump /sdcard/x10-ui.xml >/dev/null 2>&1; adb pull /sdcard/x10-ui.xml "$OUT/$TAG-reconnected.xml" >/dev/null 2>&1
  pids "reconnected"
  host "reconnected: startsDelta=$(( $(starts) - before ))"
  adb shell am force-stop $PKG; sleep 5
  pids "final-force-stop"
  adb uninstall $PKG >/dev/null 2>&1 || true
}

# 收尾放在 EXIT 里：中途哪条命令失败、set -e 退出了，网络也要复原（模拟器默认 Wi-Fi 和数据都开着）、
# 加的端口转发要去掉、摘要要写出来（hostkill 第一次跑就在点按钮那步退出、什么都没收）。
cleanup() {
  local rc=$?
  host "end rc=$rc counts=$(counts)"
  adb shell svc data enable || true
  adb shell svc wifi enable || true
  adb reverse --remove tcp:21080 >/dev/null 2>&1 || true
  adb reverse --remove tcp:22301 >/dev/null 2>&1 || true
  grep -E '^X10HOST|X10 |^  [0-9]' "$LOG" | grep -v 'X10 ACTION\|X10 ACK' | sed 's/^I\/flutter ([0-9 ]*): //' > "$OUT/$TAG-summary.txt" || true
  echo "日志：$LOG"
  echo "摘要：$OUT/$TAG-summary.txt"
}
trap cleanup EXIT

# 整条命令包起来交给手机的 sh：不包的话格式里的空格把它拆成两个参数，只拿到「10-22」。
SINCE=$(adb shell "date '+%m-%d %H:%M:%S.000'" | tr -d '\r')
host "start $TAG $(git rev-parse --short HEAD) counts=$(counts)"
if [[ $SCENARIO == hostkill ]]; then
  hostkill
else
  run_test
  serve_actions
  wait "$TEST" && host "test exit=0" || host "test exit=$?"
  host "plugin log:"; mosh_log | tee -a "$LOG"
fi
