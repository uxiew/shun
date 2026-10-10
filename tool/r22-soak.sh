#!/usr/bin/env bash
# LIFE07 真机长测（integration_test/r22_lifecycle_test.dart 的 soak 场景）的电脑这一头。
# 手机前台 N 分钟、锁屏拔线 N 分钟，看 App 说的连接状态是不是真的、有没有多连。
#
#   source ../.toolchain/env.sh
#   (cd tool/fixture-environment && ./up.sh)
#   tool/remote-device/up.sh xdwmbp /opt/homebrew/share/android-commandlinetools/platform-tools/adb
#   source /tmp/xwshun-remote-device/env
#   tool/r22-soak.sh 47131FDAP0040E default 30    # 不加省电豁免（出厂默认）
#   tool/r22-soak.sh 47131FDAP0040E exempt 30     # 临时加省电豁免
#
# 要所有者在场，脚本打 "OWNER:" 开头的行时由所有者本人：拔 USB 线 → 按电源键锁屏 → 到点插回 → 解锁回到 App。
# 顺序别反：插着线按电源键进的是屏保，拔了线屏保也可能不退，手机一直醒着（试跑撞到过）。
# 脚本不注入按键（会搅乱微信输入法），不碰锁屏密码、输入法、VPN。
#
# 为什么要拔线：插着 USB 线时手机 CPU 一直醒着（试跑时锁屏 187 秒、睡了 0 秒），系统虽然进了 Doze，
# 连接活不活得下来和平时揣兜里完全两回事。拔线这段 adb 断了，测试把日志另写一份到 App 私有目录，插回后从那里读。
#
# 手机连测试环境走两条路：
#   - USB：adb reverse 22201。拔线就断，解锁后 App 应当自己恢复（插回时脚本重建 reverse）；
#   - 手机 Wi-Fi：xdwmbp 上临时开的转发口 22211（tool/remote-device/tcp-relay.py），只接手机的 IP，脚本一退就关。
#     不直接连本机 192.168.2.x：手机开着 Google VPN，发往那段的流量进了隧道，连不到。
#
# 临时改、结束时（含 Ctrl-C）改回的：
#   - stay_on_while_plugged_in：前台阶段插着电不灭屏，锁屏前改成 0，结束写回原值；
#   - exempt 时 deviceidle whitelist +本 App（设置里「电池 → 不限制」同一个名单），结束减掉，卸载也会清掉。
# 拔线期间只看服务器那头（容器里每 5 分钟一次），不碰手机。
# 日志在 ../.toolchain/artifacts/r22-<提交>/soak-<模式>-<时间>.log，手机里那份是同名 -device.log，摘要 -summary.txt。
set -eu
cd "$(dirname "$0")/.."

SERIAL=${1:?用法：tool/r22-soak.sh <设备序列号> default|exempt [分钟，默认 30]}
MODE=${2:?用法：tool/r22-soak.sh <设备序列号> default|exempt [分钟，默认 30]}
MINUTES=${3:-30}
[[ $MODE == default || $MODE == exempt ]] || { echo "模式只能是 default 或 exempt"; exit 2; }
REMOTE=${XWSHUN_REMOTE_HOST:-xdwmbp}
RELAY_PORT=22211
export ANDROID_SERIAL=$SERIAL
PKG=top.xdwa.xwshun
OUT=../.toolchain/artifacts/r22-$(git rev-parse --short HEAD)
mkdir -p "$OUT"
STAMP=soak-$MODE-$(date +%H%M%S)
LOG=$OUT/$STAMP.log
DEVICE_LOG=$OUT/$STAMP-device.log
: > "$LOG"
host() { echo "R22HOST $(date +%T) $*" | tee -a "$LOG"; }
owner() { echo "OWNER: $*" | tee -a "$LOG"; }

adb get-state >/dev/null || { echo "看不到 $SERIAL：先 tool/remote-device/up.sh，再 source /tmp/xwshun-remote-device/env"; exit 1; }
# 插回线后重建 reverse 要绕开包装脚本：它会再开一次 ssh -R，而那条还在，报端口被占。
REAL_ADB=$(cat /tmp/xwshun-remote-device/real-adb 2>/dev/null || command -v adb)
EDGE=$(docker ps --format '{{.Names}}' | grep -m1 xwshun-fixture-ssh-edge) || { echo "测试环境没起：(cd tool/fixture-environment && ./up.sh)"; exit 1; }
accepted() { docker logs "$EDGE" 2>&1 | grep -c 'Accepted' || true; }

PHONE_IP=$(adb shell ip -4 addr show wlan0 | grep -oE 'inet [0-9.]+' | cut -d' ' -f2)
[[ -n $PHONE_IP ]] || { echo "手机没连 Wi-Fi"; exit 1; }
RELAY_IP=$(ssh "$REMOTE" 'for i in en0 en1 en2; do ipconfig getifaddr $i; done' 2>/dev/null | grep -m1 "^${PHONE_IP%.*}\.") ||
  { echo "$REMOTE 和手机（$PHONE_IP）不在同一个网段，Wi-Fi 这条路走不通"; exit 1; }

CONFIG=$(MINUTES=$MINUTES RELAY_IP=$RELAY_IP RELAY_PORT=$RELAY_PORT python3 - <<'EOF'
import json, os, pathlib
f = json.loads(pathlib.Path('tool/fixture-environment/.run/fixture.json').read_text())
print(json.dumps({
    'user': f['user'], 'password': f['password'],
    'edge': {'port': f['sshEdge']['port'], 'fingerprint': f['sshEdge']['fingerprintSha256'],
             'keyType': f['sshEdge']['keyType']},
    'minutes': int(os.environ['MINUTES']),
    'wifi': {'host': os.environ['RELAY_IP'], 'port': int(os.environ['RELAY_PORT'])},
}))
EOF
)

connected() { [[ $(adb get-state 2>/dev/null | tr -d '\r') == device ]]; }
device_lines() { adb shell "run-as $PKG cat files/r22/log.txt" 2>/dev/null | tr -d '\r' || true; }

STAY0=$(adb shell settings get global stay_on_while_plugged_in | tr -d '\r')
TEST=
cleanup() {
  set +e
  [[ -n $TEST ]] && kill "$TEST" 2>/dev/null
  if connected; then
    device_lines > "$DEVICE_LOG"
    adb shell settings put global stay_on_while_plugged_in "$STAY0"
    if adb shell pm path $PKG >/dev/null 2>&1; then
      [[ $MODE == exempt ]] && adb shell dumpsys deviceidle whitelist -$PKG >/dev/null
      adb uninstall $PKG >/dev/null
    fi
    adb shell rm -f /data/local/tmp/life07-facts.sh
    adb reverse --remove tcp:22201 >/dev/null 2>&1
  else
    host "手机没接上，没能复原：插上后执行 adb shell settings put global stay_on_while_plugged_in $STAY0; adb uninstall $PKG"
  fi
  exec 7>&- 2>/dev/null   # 关掉转发的标准输入，xdwmbp 上的转发随之退出
  sleep 1
  ssh "$REMOTE" rm -f /tmp/xwshun-tcp-relay.py 2>/dev/null
  host "restored: stay_on_while_plugged_in=$(adb shell settings get global stay_on_while_plugged_in 2>/dev/null | tr -d '\r')" \
    "app-installed=$(adb shell pm path $PKG 2>/dev/null | grep -c package || true)" \
    "relay-left=$(ssh "$REMOTE" "pgrep -f xwshun-tcp-relay | wc -l" 2>/dev/null | tr -d ' ')"
  { echo "== 电脑这头"; grep -E '^R22HOST|^OWNER|relay' "$LOG"
    echo "== 手机里的测试日志"; grep -v -E 'R22 (ACTION|ACK)=' "$DEVICE_LOG"
  } > "$OUT/$STAMP-summary.txt"
  echo "日志：$LOG"
  echo "摘要：$OUT/$STAMP-summary.txt"
}
trap cleanup EXIT

# 上一轮中途退出时 App 可能还装着，私有目录里旧的 log.txt 带着 DONE，会让这一轮一开始就收工。
adb uninstall $PKG >/dev/null 2>&1 || true
adb reverse tcp:22201 tcp:22201 >/dev/null
scp -q tool/remote-device/tcp-relay.py "$REMOTE:/tmp/xwshun-tcp-relay.py"
exec 7> >(ssh "$REMOTE" python3 -u /tmp/xwshun-tcp-relay.py "$RELAY_IP" $RELAY_PORT "$PHONE_IP" 22201 \
  $((MINUTES * 120 + 5400)) >> "$LOG" 2>&1)
sleep 3
host "wifi path: phone $PHONE_IP -> $REMOTE $RELAY_IP:$RELAY_PORT -> this mac 22201;" \
  "check: $(adb shell "echo | nc -w 3 $RELAY_IP $RELAY_PORT" 2>/dev/null | head -c 20 | tr -d '\r\n')"

# 手机上的取证脚本：一次 adb shell 拿全。只把本 App 的通知标题带出手机，别的通知不碰。
adb shell 'cat > /data/local/tmp/life07-facts.sh' <<'EOF'
P=top.xdwa.xwshun
d=$(dumpsys deviceidle)
b=$(dumpsys battery)
printf '%s ' \
  "idle=$(echo "$d" | grep -m1 -oE 'mState=[A-Z_]+' | cut -d= -f2)/$(echo "$d" | grep -m1 -oE 'mLightState=[A-Z_]+' | cut -d= -f2)" \
  "wake=$(dumpsys power | grep -m1 -oE 'mWakefulness=[A-Za-z]+' | cut -d= -f2)" \
  "keyguard=$(dumpsys window | grep -m1 -oE 'isKeyguardShowing=[a-z]+' | cut -d= -f2)" \
  "app-on-top=$(dumpsys activity activities | grep -m1 topResumedActivity | grep -c $P)" \
  "battery=$(echo "$b" | grep -m1 ' level:' | tr -dc 0-9)%" \
  "ac=$(echo "$b" | grep -m1 'AC powered' | awk '{print $3}')" \
  "temp=$(echo "$b" | grep -m1 'temperature' | tr -dc 0-9)" \
  "pid=$(pidof $P)" \
  "fgs=$(dumpsys activity services $P | grep -c 'ServiceRecord.*SshKeepAliveService')" \
  "bucket=$(am get-standby-bucket $P 2>/dev/null)" \
  "exempt=$(dumpsys deviceidle whitelist | grep -c ",$P,")" \
  "saver=$(settings get global low_power)" \
  "stayon=$(settings get global stay_on_while_plugged_in)" \
  "$(cmd wifi status | grep -m1 -oE 'RSSI: -?[0-9]+' | tr -d ' ')" \
  "app-cpu=$(top -b -n 1 -p "$(pidof $P)" 2>/dev/null | tail -1 | awk '{print $9}')%" \
  "native-heap-kb=$(dumpsys meminfo $P 2>/dev/null | grep -m1 'Native Heap' | awk '{print $(NF-1)}')"
echo
echo "notification: $(dumpsys notification --noredact | grep -A80 "pkg=$P" | grep -m1 -oE 'android.title=String \([^)]*\)')"
EOF
facts() { host "$1 phone: $(adb shell sh /data/local/tmp/life07-facts.sh 2>/dev/null | tr -d '\r' | tr '\n' ' ')"; }
server() {
  local pids alive="" p
  pids=$(grep -m1 'R22 server-pids=' "$DEVICE_LOG" 2>/dev/null | sed 's/.*server-pids=//')
  for p in ${pids//,/ }; do
    docker exec "$EDGE" kill -0 "${p#*:}" 2>/dev/null && alive+="${p%%:*}:alive " || alive+="${p%%:*}:gone "
  done
  host "$1 server: first connections ${alive:-unknown} edge-accepted=$(accepted)"
}
wake() { adb shell "dumpsys power | grep -m1 -oE 'mWakefulness=[A-Za-z]+'" 2>/dev/null | cut -d= -f2 | tr -d '\r'; }
keyguard() { adb shell "dumpsys window | grep -m1 -oE 'isKeyguardShowing=[a-z]+'" 2>/dev/null | cut -d= -f2 | tr -d '\r'; }
top_is_app() { adb shell "dumpsys activity activities | grep -m1 topResumedActivity" 2>/dev/null | grep -c $PKG || true; }
# 解锁时手机的 USB 会重新握手，adb 断 2–3 秒，反向转发随之没了（试跑撞到过）。断了就重建。
ensure_reverse() {
  "$REAL_ADB" reverse --list 2>/dev/null | grep -q 'tcp:22201' && return 0
  "$REAL_ADB" reverse tcp:22201 tcp:22201 >/dev/null 2>&1 && host "adb reverse 22201 rebuilt"
  return 0
}
# 告诉测试这件事做完了。正赶上 USB 闪断时等它回来再写，别让测试干等到超时。
ack() {
  local i
  for i in $(seq 1 60); do
    adb shell "run-as $PKG sh -c 'mkdir -p files/r22 && touch files/r22/$1'" 2>/dev/null && return 0
    sleep 2
  done
  host "两分钟都没能告诉测试「$1」做完了"
  return 1
}
sleep_until() { local now; now=$(date +%s); (( $1 > now )) && sleep $(( $1 - now )); return 0; }

# 后台跑的都不带 7 号描述符（转发的标准输入），免得脚本退了它们还替转发撑着口子。
(for _ in $(seq 1 1200); do
  adb shell pm grant $PKG android.permission.POST_NOTIFICATIONS 2>/dev/null && break
  sleep 0.5
done >/dev/null 2>&1 7>&- &)

do_action() {
  local name=$1 i
  case "$name" in
    soak-start)
      if [[ $MODE == exempt ]]; then adb shell dumpsys deviceidle whitelist +$PKG | tee -a "$LOG"; fi
      adb shell svc power stayon true
      host "device: $(adb shell 'echo $(getprop ro.product.model) Android $(getprop ro.build.version.release) API $(getprop ro.build.version.sdk) build $(getprop ro.build.id) patch $(getprop ro.build.version.security_patch)' | tr -d '\r')"
      host "mode=$MODE minutes=$MINUTES appops RUN_ANY_IN_BACKGROUND: $(adb shell cmd appops get $PKG RUN_ANY_IN_BACKGROUND | tr -d '\r')"
      host "doze constants: $(adb shell "dumpsys deviceidle | grep -E ' (light_after_inactive_to|inactive_to|idle_after_inactive_to|idle_to|max_idle_to)='" | tr -d '\r' | tr -s ' ' | tr '\n' ' ')"
      facts soak-start ;;
    facts-*) facts "$name"; server "$name" ;;
    lock)
      # 整个锁屏阶段都在这里，做完（插回线、解锁、App 回到最前）才回 lock，测试那头一直等着。
      # 先拔线再锁屏：插着电时按电源键进的是屏保（手机开了「充电时显示屏保」），试跑时拔了线屏保也没退，
      # 162 秒里手机一秒没睡。锁屏时刻由测试自己看 App 进后台来记。
      facts before-lock; server before-lock
      adb shell settings put global stay_on_while_plugged_in 0
      # 拔线前先硬杀 flutter：它连不上手机会按「测试失败」收尾，插回线时可能去卸 App。用 -9 不让它跑收尾钩子。
      # 之后测试照常在手机上跑，脚本只看手机里的日志。
      kill -9 "$TEST" 2>/dev/null || true
      owner "请先拔掉手机上的 USB 线，再按一下电源键锁屏（App 留在前台，别切走）。之后 $MINUTES 分钟别碰手机。"
      for i in $(seq 1 450); do connected || break; sleep 2; done
      local unplugged_at t
      unplugged_at=$(date +%s)
      if connected; then host "15 分钟没拔线，这一轮按插着线算"; else host "unplugged"; fi
      if (( MINUTES > 5 )); then
        for t in $(seq 5 5 $((MINUTES - 1))); do
          sleep_until $((unplugged_at + t * 60)); server "unplugged+${t}m"
        done
      fi
      sleep_until $((unplugged_at + MINUTES * 60))
      server lock-end
      owner "到点了：请把 USB 线插回手机，先别解锁。"
      for i in $(seq 1 900); do connected && break; sleep 2; done
      host "replugged after $(( $(date +%s) - unplugged_at ))s on battery"
      ensure_reverse
      facts replugged
      owner "请解锁手机，回到 App（锁屏前它就在前台，解锁后应该直接是它）。"
      for i in $(seq 1 900); do
        [[ $(wake) == Awake && $(keyguard) == false ]] && break
        sleep 2
      done
      host "unlocked"
      sleep 5
      for i in $(seq 1 30); do connected && break; sleep 1; done
      ensure_reverse
      for i in $(seq 1 30); do
        [[ $(top_is_app) == 1 ]] && break
        (( i == 5 )) && owner "App 不在最前：请点开 xwshun。"
        sleep 2
      done
      facts after-unlock ;;
    shot-*)
      if [[ $(top_is_app) == 1 ]]; then adb exec-out screencap -p > "$OUT/${name#shot-}-$MODE.png"; else host "not on top, no screenshot"; fi ;;
    soak-end)
      server soak-end; facts soak-end
      if [[ $MODE == exempt ]]; then adb shell dumpsys deviceidle whitelist -$PKG | tee -a "$LOG"; fi ;;
    *) host "不认识的动作 $name"; return 1 ;;
  esac
  ack "$name"
}

# 手机锁着（或在屏保）时测试 App 被盖住、出不了第一帧，测试会卡在启动那一步（试跑撞到过）。
if [[ $(wake) != Awake || $(keyguard) != false ]]; then
  owner "手机锁着：请先解锁，停在桌面就行。"
  for i in $(seq 1 450); do
    [[ $(wake) == Awake && $(keyguard) == false ]] && break
    sleep 2
  done
fi
flutter test integration_test/r22_lifecycle_test.dart -d "$SERIAL" \
  --dart-define=R22_SCENARIO=soak --dart-define=R22_CONFIG="$CONFIG" >> "$LOG" 2>&1 7>&- &
TEST=$!
# 按手机里那份日志里的 ACTION 行做事：拔过线之后 flutter 那头就收不到了。
# flutter 没跑起来（构建失败）时手机里没有日志，flutter 一退就收工；跑起来以后以 DONE/FAILED 行为准。
seen=0
ever=
deadline=$(( $(date +%s) + MINUTES * 120 + 5400 ))
while :; do
  lines=$(device_lines)
  [[ -n $lines ]] && { printf '%s\n' "$lines" > "$DEVICE_LOG"; ever=1; }
  actions=$(printf '%s\n' "$lines" | grep 'R22 ACTION=' | sed 's/.*R22 ACTION=//' || true)
  count=$(printf '%s\n' "$actions" | grep -c . || true)
  while (( seen < count )); do
    seen=$((seen + 1))
    name=$(printf '%s\n' "$actions" | sed -n "${seen}p")
    do_action "$name" || host "动作「$name」出错，接着往下走"
  done
  connected && ensure_reverse
  printf '%s\n' "$lines" | grep -qE 'R22 (DONE|FAILED)=' && break
  [[ -z $ever ]] && ! kill -0 "$TEST" 2>/dev/null && { host "flutter test 没跑起来，看 $LOG"; break; }
  (( $(date +%s) > deadline )) && { host "超时"; break; }
  sleep 1
done
host "result: $(grep -hE 'R22 (DONE|FAILED)=' "$DEVICE_LOG" | tail -1)"
sleep 3   # 让 flutter（如果还连着）收尾
