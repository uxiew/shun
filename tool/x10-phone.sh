#!/usr/bin/env bash
# X10 真机部分（integration_test/x10_mosh_lifecycle_test.dart 的 phone 场景）的电脑这一头。
# 每次跑都要所有者当次同意、在场：要往手机上装调试宿主 top.xdwa.shun.debug 和测试签名的 Mosh 插件 top.xdwa.shun.mosh，
# 跑完（含中途 Ctrl-C）两个都卸。
#
#   source ../.toolchain/env.sh
#   (cd tool/mosh-fixture && ./up.sh)
#   tool/x10-phone.sh <手机序列号> [锁屏分钟，默认 30]
#
# 只能在接手机的那台 Mac 上跑：转发要开在它的局域网地址上。手机经自己的 Wi-Fi 连本机测试环境：
# 本机局域网地址上临时开 TCP 22301（tool/remote-device/tcp-relay.py）和 UDP 60101–60108（udp-relay.py）的转发，
# 只放行手机的 IP，脚本一退就关。不用 adb reverse：拔了线要照样通；而且 Mosh 的 UDP 发往 SSH 连上的那个地址，
# SSH 走 127.0.0.1 的话 UDP 也会发到手机自己身上。
#
# 所有者要做的（脚本打 "OWNER:" 开头的行）：
#   1. 手机解锁着开始：测试 App 要先画出第一帧，锁着屏会卡在启动那一步（R22 撞到过）；
#   2. 关 Wi-Fi，半分钟左右再打开：手机落到蜂窝、到不了局域网，等于断网再回来；
#   3. 先拔 USB 线、再按电源键锁屏，N 分钟别碰；插回线，解锁。顺序别反：插着电锁屏进的是屏保、CPU 不睡（R22）。
# 后面的 mosh-client 段错误、插件崩溃、插件被强停不用人。
# 不注入按键（手机用微信输入法）、不截屏、不改系统设置（不碰插电不灭屏、省电豁免、Wi-Fi 开关）；
# 只给调试宿主自己的通知权限（同 R22，不给的话启动会弹权限框）。
# 从手机读的 dumpsys / ps / logcat 都在手机上先过滤（/data/local/tmp/x10-facts.sh），只带出这两个包的行。
# 拔线前先 kill -9 掉 flutter：它连不上手机会按失败收尾，插回线时可能去卸 App。之后测试照常在手机上跑，
# 脚本只看手机里的 x10/log.txt，结果是它最后的 DONE / FAILED 行。
# 日志在 ../.toolchain/artifacts/x10-<提交>/phone-<时间>.log：手机里那份是 -device.log，转发的是 -relay.log，摘要 -summary.txt。
# 不开 pipefail：下面的 `… | grep -m1` 会让前面的 adb 收到 SIGPIPE，开着的话整个脚本悄悄退出。
set -eu
cd "$(dirname "$0")/.."

SERIAL=${1:?用法：tool/x10-phone.sh <手机序列号> [锁屏分钟，默认 30]}
MINUTES=${2:-30}
case "$SERIAL" in
  emulator-*) echo "这是真机脚本，模拟器用 tool/x10-mosh.sh" >&2; exit 1 ;;
esac
export ANDROID_SERIAL=$SERIAL
PKG=top.xdwa.shun.debug
PLUGIN=top.xdwa.shun.mosh
PLUGIN_APK=plugins/mosh/build/outputs/apk/release/mosh-release.apk
OUT=../.toolchain/artifacts/x10-$(git rev-parse --short HEAD)
mkdir -p "$OUT"
STAMP=phone-$(date +%H%M%S)
LOG=$OUT/$STAMP.log
DEVICE_LOG=$OUT/$STAMP-device.log
RELAY_LOG=$OUT/$STAMP-relay.log
: > "$LOG"
: > "$RELAY_LOG"
host() { echo "X10HOST $(date +%T) $*" | tee -a "$LOG"; }
owner() { echo "OWNER: $*" | tee -a "$LOG"; }

adb get-state >/dev/null 2>&1 || { echo "看不到 $SERIAL：手机没插、没开 USB 调试，或者 adb 不在 PATH 里"; exit 1; }
[[ -f tool/mosh-fixture/.run/fixture.json ]] || { echo "测试环境没起：(cd tool/mosh-fixture && ./up.sh)"; exit 1; }
[[ -f $PLUGIN_APK ]] || { echo "没有插件包 $PLUGIN_APK，怎么编见 plugins/README.md"; exit 1; }
# 手机上已经有的不是这一轮装的，可能是所有者自己的：不覆盖、不卸，让人来定。（这个脚本自己装的，退出时都卸了。）
for p in $PKG $PLUGIN; do
  if adb shell pm path $p >/dev/null 2>&1; then
    echo "手机上已经装着 $p：问过所有者、确认是测试留下的再 adb uninstall $p"; exit 1
  fi
done

wifi_ip() { adb shell ip -4 addr show wlan0 2>/dev/null | grep -oE 'inet [0-9.]+' | cut -d' ' -f2 || true; }
PHONE_IP=$(wifi_ip)
[[ -n $PHONE_IP ]] || { echo "手机没连 Wi-Fi"; exit 1; }
MAC_IP=$(for i in en0 en1 en2; do ipconfig getifaddr $i; done 2>/dev/null | grep -m1 "^${PHONE_IP%.*}\.") ||
  { echo "这台 Mac 和手机（$PHONE_IP）不在同一个网段，Wi-Fi 这条路走不通"; exit 1; }
CONFIG=$(python3 tool/mosh-fixture/x08_config.py "$MAC_IP")

connected() { [[ $(adb get-state 2>/dev/null | tr -d '\r') == device ]]; }
device_lines() { adb shell "run-as $PKG cat files/x10/log.txt" 2>/dev/null | tr -d '\r' || true; }
counts() { tool/mosh-fixture/counts.sh 2>/dev/null || echo '{}'; }
wake() { adb shell "dumpsys power | grep -m1 -oE 'mWakefulness=[A-Za-z]+'" 2>/dev/null | cut -d= -f2 | tr -d '\r'; }
keyguard() { adb shell "dumpsys window | grep -m1 -oE 'isKeyguardShowing=[a-z]+'" 2>/dev/null | cut -d= -f2 | tr -d '\r'; }
top_is_app() { adb shell "dumpsys activity activities | grep -m1 topResumedActivity" 2>/dev/null | grep -c $PKG || true; }
default_net() {
  local id
  id=$(adb shell "dumpsys connectivity | grep -m1 'Active default network'" | awk '{print $NF}' | tr -d '\r')
  if [[ -z "$id" || "$id" == none ]]; then echo none; return; fi
  echo "$id/$(adb shell "dumpsys connectivity | grep -m1 'network{$id}'" | grep -oE 'Transports: [A-Z|]+' | cut -d' ' -f2)"
}
facts_sh() { adb shell sh /data/local/tmp/x10-facts.sh "$@" 2>/dev/null | tr -d '\r'; }
facts() { facts_sh facts "$MAC_IP" | sed "s/^/X10HOST $(date +%T) $1 /" | tee -a "$LOG"; }
pids() { host "pids $1: $(facts_sh pids) wlan0=$(wifi_ip) net=$(default_net) counts=$(counts)"; }
# 只带出这两个包、插件 uid（u0aNNN）和 mosh-client 的行。不写 top.xdwa.shun 就算：所有者的正式包也叫这个名字。
logs() {
  local f=$OUT/$STAMP-logcat-$1.txt
  facts_sh logcat "$SINCE" > "$f" || true
  host "logcat $1: $(wc -l < "$f" | tr -d ' ') lines ($f); oldest kept: $(facts_sh oldest)"
}

# 告诉测试这件事做完了。正赶上 USB 闪断（解锁时会重新握手）时等它回来再写，别让测试干等到超时。
ack() {
  local i
  for i in $(seq 1 60); do
    adb shell "run-as $PKG sh -c 'mkdir -p files/x10 && touch files/x10/$1'" 2>/dev/null && return 0
    sleep 2
  done
  host "两分钟都没能告诉测试「$1」做完了"
}

WIFI_OFF_AT=0
do_action() {
  local name=$1 i p unplugged_at t
  case "$name" in
    pids-*) pids "${name#pids-}" ;;
    facts-*) facts "${name#facts-}" ;;
    owner-wifi-off)
      owner "请关掉 Wi-Fi，半分钟左右再打开。"
      for i in $(seq 1 1800); do [[ -z $(wifi_ip) ]] && break; sleep 1; done
      WIFI_OFF_AT=$(date +%s)
      host "wifi off: wlan0=$(wifi_ip) net=$(default_net)" ;;
    owner-wifi-on)
      for i in $(seq 1 1800); do [[ -n $(wifi_ip) && $(default_net) == *WIFI* ]] && break; sleep 1; done
      host "wifi back after $(( $(date +%s) - WIFI_OFF_AT ))s: wlan0=$(wifi_ip) net=$(default_net)"
      [[ $(wifi_ip) == "$PHONE_IP" ]] ||
        host "手机 IP 变了（$PHONE_IP -> $(wifi_ip)）：转发只放行旧 IP，后面连不上是这个原因，不是 App 的" ;;
    owner-soak)
      facts before-soak
      logs before-soak
      # 拔线后 flutter 连不上手机，会按「测试失败」收尾、可能去卸 App：用 -9 不让它跑收尾钩子。
      kill -9 "$TEST" 2>/dev/null || true
      host "flutter killed; from now on only the phone's x10/log.txt"
      owner "请先拔掉 USB 线，再按电源键锁屏。$MINUTES 分钟别碰手机，到点插回线、解锁。"
      for i in $(seq 1 900); do connected || break; sleep 2; done
      unplugged_at=$(date +%s)
      if connected; then host "30 分钟没拔线，这一轮按插着线算"; else host "unplugged"; fi
      # 拔线期间只看服务器那头；手机还发不发包看 -relay.log 的每分钟计数。
      t=0
      while ! connected; do
        sleep 10
        if (( $(date +%s) - unplugged_at >= (t + 1) * 300 )); then
          t=$((t + 1)); host "unplugged+$((t * 5))m server: $(counts)"
        fi
        (( $(date +%s) - unplugged_at > (MINUTES + 60) * 60 )) && { host "拔线超过 $((MINUTES + 60)) 分钟还没插回"; break; }
      done
      host "replugged after $(( $(date +%s) - unplugged_at ))s"
      sleep 3
      facts replugged
      for i in $(seq 1 900); do [[ $(wake) == Awake && $(keyguard) == false ]] && break; sleep 2; done
      host "unlocked"
      sleep 3
      # 解锁后停在别处时把测试 App 叫到前台。不用 monkey：它会顺手注入一个事件。
      if [[ $(top_is_app) != 1 ]]; then
        adb shell am start -n $PKG/top.xdwa.shun.MainActivity >/dev/null 2>&1 || true
        sleep 2
        host "brought the app to front: on-top=$(top_is_app)"
      fi
      facts after-unlock
      logs soak ;;
    kill-client)
      # SIGSEGV 就是原生代码段错误的样子，和模拟器那轮一致（那台的 SELinux 不让 run-as 发 SIGKILL）。
      for p in $(facts_sh clients); do
        adb shell run-as $PLUGIN kill -SEGV "$p" && host "SIGSEGV -> mosh-client $p" || host "发 SIGSEGV 给 $p 失败"
      done
      sleep 1; host "after: $(facts_sh pids)" ;;
    kill-plugin)
      host "am crash plugin: $(facts_sh pids)"
      adb shell am crash $PLUGIN || host "am crash 失败"
      sleep 2; host "after: $(facts_sh pids) mosh-client-anywhere=$(facts_sh orphans)" ;;
    force-stop-plugin)
      host "force-stop plugin: $(facts_sh pids)"
      adb shell am force-stop $PLUGIN
      sleep 1; host "after: $(facts_sh pids) mosh-client-anywhere=$(facts_sh orphans)" ;;
    *) host "不认识的动作 $name" ;;
  esac
  # 动作里哪条命令失败也照样回执：不然测试一直等、挂到超时。
  ack "$name"
}

TEST=
INSTALLED=
SINCE=
FORWARDS0=$(adb forward --list | grep "^$SERIAL " || true)
cleanup() {
  set +e
  [[ -n $TEST ]] && kill "$TEST" 2>/dev/null
  if connected; then
    local lines
    lines=$(device_lines)
    [[ -n $lines ]] && printf '%s\n' "$lines" > "$DEVICE_LOG"
    [[ -n $INSTALLED ]] && logs end
    adb uninstall $PKG >/dev/null 2>&1
    [[ -n $INSTALLED ]] && adb uninstall $PLUGIN >/dev/null 2>&1
    adb shell rm -f /data/local/tmp/x10-facts.sh
    # flutter 被 kill -9 以后留下的 VM service 转发；只去掉这一轮新加的。
    adb forward --list | grep "^$SERIAL " | while read -r _ fwd _; do
      grep -q " $fwd " <<< "$FORWARDS0" || adb forward --remove "$fwd"
    done
  else
    host "手机没接上，没能复原：插上后 adb uninstall $PKG; adb uninstall $PLUGIN; adb shell rm -f /data/local/tmp/x10-facts.sh"
  fi
  exec 7>&- 8>&- 2>/dev/null   # 关掉转发的标准输入，它们随之退出
  sleep 1
  host "restored: host-installed=$(adb shell pm path $PKG 2>/dev/null | grep -c package)" \
    "plugin-installed=$(adb shell pm path $PLUGIN 2>/dev/null | grep -c package)" \
    "relays-left=$(pgrep -f 'remote-device/(tcp|udp)-relay.py' | wc -l | tr -d ' ') counts=$(counts)"
  { echo "== 电脑这头"; grep -E '^X10HOST|^OWNER' "$LOG"
    echo "== 手机里的测试日志"; grep -v -E 'X10 (ACTION|ACK)=' "$DEVICE_LOG" 2>/dev/null
    echo "== 转发"; cat "$RELAY_LOG"
  } > "$OUT/$STAMP-summary.txt"
  echo "日志：$LOG"
  echo "摘要：$OUT/$STAMP-summary.txt"
}
trap cleanup EXIT

# 手机上的取证脚本：过滤都在手机上做，别的 App 的进程、通知、日志不出手机。
adb shell 'cat > /data/local/tmp/x10-facts.sh' <<'EOF'
H=top.xdwa.shun.debug
P=top.xdwa.shun.mosh
hp=$(pidof $H)
pp=$(pidof $P)
uh=$(cmd package list packages -U $H | grep -o 'uid:[0-9]*' | cut -d: -f2)
up=$(cmd package list packages -U $P | grep -o 'uid:[0-9]*' | cut -d: -f2)
# mosh-client 就是插件进程的子进程（exec 的是插件里的 libmoshclient.so）。
cl=$([ -n "$pp" ] && ps -A -o PID,PPID | awk -v p="$pp" '$2 == p {printf "%s ", $1}')
case "$1" in
  clients) echo $cl ;;
  orphans) ps -A -o NAME | grep -c libmoshclient ;;
  pids)
    # mosh-client 的 UDP 本地端口：换端口（mosh 长时间收不到回应时自己换）就会变。
    udp=
    for c in $cl; do
      ino=$(run-as $P ls -l /proc/$c/fd 2>/dev/null | grep -o 'socket:\[[0-9]*\]' | grep -o '[0-9]*' | tr '\n' '|')
      for h in $(awk -v want="|$ino" 'index(want, "|" $10 "|") {print $2}' /proc/net/udp /proc/net/udp6); do
        udp="$udp $(printf %d 0x${h##*:})"
      done
    done
    echo "host=$hp plugin=$pp mosh-client=[${cl% }] udp-local-port=[${udp# }]" ;;
  facts)
    d=$(dumpsys deviceidle)
    b=$(dumpsys battery)
    echo "device: idle=$(echo "$d" | grep -m1 -oE 'mState=[A-Z_]+' | cut -d= -f2)/$(echo "$d" | grep -m1 -oE 'mLightState=[A-Z_]+' | cut -d= -f2)" \
      "wake=$(dumpsys power | grep -m1 -oE 'mWakefulness=[A-Za-z]+' | cut -d= -f2)" \
      "keyguard=$(dumpsys window | grep -m1 -oE 'isKeyguardShowing=[a-z]+' | cut -d= -f2)" \
      "app-on-top=$(dumpsys activity activities | grep -m1 topResumedActivity | grep -c $H)" \
      "battery=$(echo "$b" | grep -m1 ' level:' | tr -dc 0-9)% usb=$(echo "$b" | grep -m1 'USB powered' | awk '{print $3}')" \
      "saver=$(settings get global low_power) wlan0=$(ip -4 addr show wlan0 | grep -oE 'inet [0-9.]+' | cut -d' ' -f2)"
    echo "pids: host=$hp plugin=$pp mosh-client=[${cl% }]"
    # 冻结：应用进程各在自己的 cgroup（uid_N/pid_M），fork 出来的子进程留在父进程那个里，父进程被冻它也跟着冻。
    for x in $hp $pp $cl; do
      cg=$(grep '^0::' /proc/$x/cgroup | cut -d: -f3)
      echo "proc $x $(cut -d' ' -f2,3 /proc/$x/stat) oom=$(cat /proc/$x/oom_score_adj) cgroup=$cg frozen=$(grep frozen /sys/fs/cgroup$cg/cgroup.events 2>/dev/null | cut -d' ' -f2)"
    done
    for k in $H $P; do
      echo "am $k: $(dumpsys activity processes $k | grep -oE '(curProcState|setProcState|curCapability|setCapability|curCpuTimeReasons|curAdj|setAdj|isFrozen)=[^ ]+' | sort -u | tr '\n' ' ')"
    done
    echo "services: keepalive=$(dumpsys activity services $H | grep -c 'ServiceRecord.*SshKeepAliveService')" \
      "host-fg=$(dumpsys activity services $H | grep -m1 -oE 'isForeground=[a-z]+')" \
      "plugin-services=$(dumpsys activity services $P | grep -c 'ServiceRecord{')" \
      "plugin-fg=$(dumpsys activity services $P | grep -m1 -oE 'isForeground=[a-z]+')"
    echo "netpolicy: $(dumpsys netpolicy | grep -E "UID=($uh|$up)( |$)" | tr -s ' ' | tr '\n' ';')"
    echo "route plugin-uid: $(ip route get $2 uid $up 2>&1 | head -1)"
    echo "bucket: host=$(am get-standby-bucket $H) plugin=$(am get-standby-bucket $P)" \
      "exempt=$(dumpsys deviceidle whitelist | grep -cE ",($H|$P),")" \
      "phantom-limit=$(dumpsys activity settings | grep -m1 -oE 'max_phantom_processes=[0-9]+')"
    echo "wakelocks: host=$(dumpsys power | sed -n '/^Wake Locks:/,/^$/p' | grep -cE "uid=$uh|$H")" \
      "plugin=$(dumpsys power | sed -n '/^Wake Locks:/,/^$/p' | grep -cE "uid=$up|$P")"
    echo "notification: $(dumpsys notification --noredact | grep -A80 "pkg=$H" | grep -m2 -oE 'android\.(title|text)=String \([^)]*\)' | tr '\n' ' ')" ;;
  logcat)
    # adb shell 把参数用空格拼起来交给手机的 sh，「10-23 15:00:00.000」到这里已经是 $2、$3 两个参数了。
    a=u0a$((up - 10000))
    logcat -d -v time -T "$2 $3" -b main,system,crash,events 2>/dev/null |
      grep -E "top\.xdwa\.shun\.(debug|mosh)|ShunMosh|libmoshclient|[^0-9]$a[^0-9]" ;;
  oldest) echo "main $(logcat -d -v time -b main | head -1 | cut -c1-18), events $(logcat -d -v time -b events | head -1 | cut -c1-18)" ;;
esac
EOF

# 手机锁着（或在屏保）时测试 App 被盖住、出不了第一帧，测试会卡在启动那一步（R22 撞到过）。
if [[ $(wake) != Awake || $(keyguard) != false ]]; then
  owner "手机锁着：请先解锁，停在桌面就行。"
  for i in $(seq 1 450); do [[ $(wake) == Awake && $(keyguard) == false ]] && break; sleep 2; done
fi

# 后台跑的都不带 7、8 号描述符（转发的标准输入），免得脚本退了它们还替转发撑着口子。
exec 7> >(python3 -u tool/remote-device/tcp-relay.py "$MAC_IP" 22301 "$PHONE_IP" 22301 $(( (MINUTES + 120) * 60 )) >> "$RELAY_LOG" 2>&1)
exec 8> >(python3 -u tool/remote-device/udp-relay.py "$MAC_IP" 60101 60108 "$PHONE_IP" $(( (MINUTES + 120) * 60 )) >> "$RELAY_LOG" 2>&1 7>&-)
sleep 2
host "device: $(adb shell 'echo $(getprop ro.product.model) Android $(getprop ro.build.version.release) API $(getprop ro.build.version.sdk) build $(getprop ro.build.id) patch $(getprop ro.build.version.security_patch)' | tr -d '\r')"
host "wifi path: phone $PHONE_IP -> this mac $MAC_IP:22301/tcp, :60101-60108/udp -> 127.0.0.1;" \
  "check: $(adb shell "echo | nc -w 3 $MAC_IP 22301" 2>/dev/null | head -c 20 | tr -d '\r\n')"
if [[ $(grep -c listening "$RELAY_LOG") != 2 ]]; then
  host "转发没起来：$(tr '\n' ' ' < "$RELAY_LOG")"; exit 1
fi

# 整条命令包起来交给手机的 sh：不包的话格式里的空格把它拆成两个参数。
SINCE=$(adb shell "date '+%m-%d %H:%M:%S.000'" | tr -d '\r')
# 先记下再装：装到一半失败（比如手机上的安装确认被点了取消）时收尾也去卸。
INSTALLED=1
adb install "$PLUGIN_APK" >> "$LOG" 2>&1
host "plugin installed: sha256=$(shasum -a 256 "$PLUGIN_APK" | cut -c1-16)… $(adb shell dumpsys package $PLUGIN | grep -m2 -oE 'versionName=[^ ]+|DEBUGGABLE' | tr '\n' ' ')"
host "start $(git rev-parse --short HEAD) minutes=$MINUTES counts=$(counts)"
(for _ in $(seq 1 1200); do
  adb shell pm grant $PKG android.permission.POST_NOTIFICATIONS 2>/dev/null && break
  sleep 0.5
done >/dev/null 2>&1 7>&- 8>&- &)
flutter test integration_test/x10_mosh_lifecycle_test.dart -d "$SERIAL" \
  --dart-define=X09_MOSH="$CONFIG" --dart-define=X10_SCENARIO=phone >> "$LOG" 2>&1 7>&- 8>&- &
TEST=$!

# 按手机里那份日志里的 ACTION 行做事：拔过线之后 flutter 那头就收不到了。
# flutter 没跑起来（构建失败）时手机里没有日志，flutter 一退就收工；跑起来以后以 DONE / FAILED 行为准。
seen=0
ever=
deadline=$(( $(date +%s) + (MINUTES + 150) * 60 ))
while :; do
  lines=$(device_lines)
  [[ -n $lines ]] && { printf '%s\n' "$lines" > "$DEVICE_LOG"; ever=1; }
  actions=$(printf '%s\n' "$lines" | grep 'X10 ACTION=' | sed 's/.*X10 ACTION=//' || true)
  count=$(printf '%s\n' "$actions" | grep -c . || true)
  while (( seen < count )); do
    seen=$((seen + 1))
    # 放在 || 里调：动作里哪条命令失败都不让 set -e 把脚本带走，最后的回执照样发（模拟器那轮撞到过）。
    do_action "$(printf '%s\n' "$actions" | sed -n "${seen}p")" || host "动作出错（rc=$?）"
  done
  printf '%s\n' "$lines" | grep -qE 'X10 (DONE|FAILED)=' && break
  [[ -z $ever ]] && ! kill -0 "$TEST" 2>/dev/null && { host "flutter test 没跑起来，看 $LOG"; break; }
  (( $(date +%s) > deadline )) && { host "超时"; break; }
  sleep 1
done
host "result: $(grep -hE 'X10 (DONE|FAILED)=' "$DEVICE_LOG" 2>/dev/null | tail -1)"
host "checks: $(grep -c 'X10 CHECK=ok' "$DEVICE_LOG" 2>/dev/null) ok, $(grep -c 'X10 CHECK=FAIL' "$DEVICE_LOG" 2>/dev/null) failed"
