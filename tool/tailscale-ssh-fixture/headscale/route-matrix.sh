#!/usr/bin/env bash
# R15：在模拟器/测试机上跑 integration_test/catalog_route_matrix_test.dart。
#
#   ./up.sh routes && ./selfcheck-routes.sh                 # 先确认环境本身成立
#   ANDROID_SERIAL=emulator-5580 ./route-matrix.sh          # 设备 ID 以 adb devices 为准
#
# 做的事：把 ../.run/headscale.json 转成 R15_CONFIG（base64 JSON，含本次的临时口令）、adb reverse 三个端口、
# 后台自动批准 Headscale 里出现的 check（测试要走两次 check）、跑测试、收 ts-server 的审计日志、查有没有 VPN、
# 最后撤销 adb reverse。输出存在 ../.run/route-matrix-*.log。
#
# 测试包和正式 App 同一个包名：会清空设备上这个 App 的保险库，跑完 flutter 还会把它卸掉。只在测试设备上跑。
set -uo pipefail
cd "$(dirname "$0")"
HERE=$PWD
RUN=$(cd ../.run && pwd)
REPO=$(cd ../../.. && pwd)
J=$RUN/headscale.json
: "${ANDROID_SERIAL:?先 export ANDROID_SERIAL=<设备 ID>（本项目模拟器约定 emulator-5580）}"
export ANDROID_SERIAL
[ -s "$J" ] && grep -q relayProxy "$J" || { echo "没有 R15 的环境：先 ./up.sh routes" >&2; exit 1; }
avd=$(adb emu avd name 2>/dev/null | head -1 | tr -d '\r')
echo "设备 ${ANDROID_SERIAL}（AVD：${avd:-不是模拟器}）"
case "$avd" in
  xwshun-*|"") ;;
  *) echo "这台模拟器不是本项目的（${avd}），不在上面跑" >&2; exit 1 ;;
esac

CONFIG=$(python3 - "$J" <<'PY'
import base64, json, sys
d = json.load(open(sys.argv[1]))
cfg = {
    "server": {"ip": d["ts-server"]["ipv4"], "fingerprints": d["ts-server"]["fingerprints"]},
    "socksNode": d["ts-socks"]["ipv4"],
    "relayNode": d["ts-relay"]["ipv4"],
    "jump": {"ip": d["ts-jump"]["ipv4"], "fingerprints": d["ts-jump"]["fingerprints"],
             "port": int(d["jump"]["endpoint"].rsplit(":", 1)[1]),
             "username": d["jump"]["username"], "password": d["jump"]["password"]},
    "localSocksPort": int(d["socksProxy"].rsplit(":", 1)[1]),
    "relay": {"port": int(d["relayProxy"]["endpoint"].rsplit(":", 1)[1]),
              "username": d["relayProxy"]["username"], "password": d["relayProxy"]["password"]},
    "ordinary": {"username": d["ordinaryUser"], "password": d["ordinaryPassword"]},
}
print(base64.b64encode(json.dumps(cfg).encode()).decode())
PY
)
PORTS=(21055 21056 22202)
for p in "${PORTS[@]}"; do adb reverse "tcp:$p" "tcp:$p" >/dev/null; done

# 自动批准：测试只会发起 check 用户的两次登录，Headscale 每次打一行 hskey-authreq-…，见到新的就批准。
export SERVER_AUTHKEY=x SOCKS_AUTHKEY=x ORDINARY_PASSWORD=x RELAY_AUTHKEY=x JUMP_AUTHKEY=x RELAY_PASSWORD=x JUMP_PASSWORD=x
APPROVED=$RUN/route-matrix-approved.log
: > "$APPROVED"
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
(
  while sleep 1; do
    for id in $(docker compose logs --since "$since" headscale 2>/dev/null | grep -o 'hskey-authreq-[A-Za-z0-9_-]*' | sort -u); do
      grep -qx "$id" "$APPROVED" && continue
      echo "$id" >> "$APPROVED"
      docker compose exec -T headscale headscale auth approve --auth-id "$id" >/dev/null 2>&1 \
        && echo "approver: 已批准 $id" || echo "approver: 批准 $id 失败"
    done
  done
) &
approver=$!
cleanup() {
  { kill "$approver" && wait "$approver"; } 2>/dev/null
  for p in "${PORTS[@]}"; do adb reverse --remove "tcp:$p" >/dev/null 2>&1; done
}
trap cleanup EXIT

LOG=$RUN/route-matrix-test.log
# 系统里有几个 VPN 网络：只数网络本身（NetworkAgentInfo 的 ni{VPN…}）。别数 VPN 字样：每个网络都带 NOT_VPN，
# SystemUI 还挂着一个监听 VPN 的请求（Transports: VPN），都不是 VPN 网络。
vpns() { adb shell dumpsys connectivity | grep 'NetworkAgentInfo{' | grep -c 'ni{VPN' || true; }
vpn_before=$(vpns)
(cd "$REPO" && flutter test integration_test/catalog_route_matrix_test.dart -d "$ANDROID_SERIAL" \
  --dart-define=R15_CONFIG="$CONFIG") 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
vpn_after=$(vpns)

echo
echo "== ts-server 的审计日志（Tailscale SSH 认的是谁）"
docker compose logs --since "$since" ts-server 2>/dev/null | grep 'audit: SSH login' | sed 's/^[^|]*| //' | tee "$RUN/route-matrix-audit.log"
echo "== check 批准了 $(wc -l < "$APPROVED" | tr -d ' ') 次"
echo "== 系统里的 VPN 网络（ni{VPN}）：测试前 $vpn_before 个 / 测试后 $vpn_after 个"
APK=$REPO/build/app/outputs/flutter-apk/app-debug.apk
AAPT=$(ls "$ANDROID_HOME"/build-tools/*/aapt2 2>/dev/null | tail -1)
if [ -s "$APK" ] && [ -n "$AAPT" ]; then
  echo "== 测试包的权限和服务里有没有 VPN（BIND_VPN_SERVICE / VpnService）"
  "$AAPT" dump permissions "$APK" | grep -i vpn || echo "权限：没有 VPN 相关"
  "$AAPT" dump xmltree --file AndroidManifest.xml "$APK" | grep -i -E 'vpn' || echo "清单：没有 VPN 相关"
fi
exit "$status"
