#!/usr/bin/env bash
# 起 Headscale + 真 tailscaled 节点，结果写进 ../.run/headscale.json。见 ../README.md「真 tailscaled」一节。
#   ./up.sh          R14 那套：ts-server + ts-socks
#   ./up.sh routes   再加 R15 的 ts-relay（远程 SOCKS）和 ts-jump（跳板机），共 4 个节点
set -euo pipefail
cd "$(dirname "$0")"
RUN=../.run
mkdir -p "$RUN" && chmod 700 "$RUN"
routes=false
case "${1:-}" in
  "") ;;
  routes) routes=true ;;
  *) echo "用法：./up.sh [routes]" >&2; exit 64 ;;
esac
export SERVER_AUTHKEY=unused SOCKS_AUTHKEY=unused ORDINARY_PASSWORD=unused
export RELAY_AUTHKEY=unused JUMP_AUTHKEY=unused RELAY_PASSWORD=unused JUMP_PASSWORD=unused
hs() { docker compose exec -T headscale headscale "$@"; }

docker compose up -d headscale >/dev/null
for _ in $(seq 1 30); do hs users list >/dev/null 2>&1 && break; sleep 1; done
hs users list -o json | grep -q '"name": "fixture"' || hs users create fixture >/dev/null
uid=$(hs users list -o json | python3 -c "import json,sys;print([u['id'] for u in json.load(sys.stdin) if u['name']=='fixture'][0])")
# 可复用：单独重建某个节点容器时（状态在容器里，会丢）还能用同一把 key 重新登记。2 小时后作废。
key() { hs preauthkeys create -u "$uid" -e 2h --reusable "$@" -o json | python3 -c "import json,sys;print(json.load(sys.stdin)['key'])"; }
SERVER_AUTHKEY=$(key --tags tag:server)
SOCKS_AUTHKEY=$(key)
ORDINARY_PASSWORD=$(openssl rand -hex 12)
services=(ts-server ts-socks)
if $routes; then
  RELAY_AUTHKEY=$(key --tags tag:relay)   # 打了 tag 的节点不再属于用户 fixture，ssh 规则里的 fixture@ 管不到它
  JUMP_AUTHKEY=$(key)                     # 跳板机是用户自己的设备
  RELAY_PASSWORD=$(openssl rand -hex 12)
  JUMP_PASSWORD=$(openssl rand -hex 12)
  services+=(ts-relay ts-jump)
fi
# macOS 自带 bash 3.2：空数组在 set -u 下展开会报 unbound variable，所以不用数组传 --profile。
dc() { if $routes; then docker compose --profile routes "$@"; else docker compose "$@"; fi; }
umask 077
printf 'SERVER_AUTHKEY=%s\nSOCKS_AUTHKEY=%s\nORDINARY_PASSWORD=%s\nRELAY_AUTHKEY=%s\nJUMP_AUTHKEY=%s\nRELAY_PASSWORD=%s\nJUMP_PASSWORD=%s\n' \
  "$SERVER_AUTHKEY" "$SOCKS_AUTHKEY" "$ORDINARY_PASSWORD" "$RELAY_AUTHKEY" "$JUMP_AUTHKEY" "$RELAY_PASSWORD" "$JUMP_PASSWORD" > "$RUN/headscale.env"
export SERVER_AUTHKEY SOCKS_AUTHKEY ORDINARY_PASSWORD RELAY_AUTHKEY JUMP_AUTHKEY RELAY_PASSWORD JUMP_PASSWORD
dc up -d --build "${services[@]}" >/dev/null

# 等节点都在 Headscale 里上线
want=${#services[@]}
for _ in $(seq 1 60); do
  n=$(hs nodes list -o json | python3 -c "import json,sys;print(sum(1 for n in json.load(sys.stdin) or [] if n.get('online')))")
  [ "$n" = "$want" ] && break; sleep 1
done
[ "$n" = "$want" ] || { echo "只有 $n/$want 个节点上线" >&2; dc logs --tail 20 >&2; exit 1; }
ip_of() { hs nodes list -o json | python3 -c "import json,sys;print([a for n in json.load(sys.stdin) if n['given_name']=='$1' for a in n['ip_addresses'] if ':' not in a][0])"; }
server_ip=$(ip_of ts-server)
fingerprints() { dc exec -T "$1" sh -c 'for k in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$k" -E sha256; done' | awk '{print $2}' | paste -sd, -; }
SERVER_FPS=$(fingerprints ts-server)
JUMP_FPS=""
if $routes; then
  jump_ip=$(ip_of ts-jump)
  JUMP_FPS=$(fingerprints ts-jump)
  for port in 21056 22202; do
    for _ in $(seq 1 30); do nc -z 127.0.0.1 "$port" && break; sleep 1; done
    nc -z 127.0.0.1 "$port" || { echo "127.0.0.1:$port 没起来" >&2; exit 1; }
  done
fi

# 没有可用的 DERP（占位节点解析不到，netcheck 每几秒报一次 send error 并 rebind）：节点间的直连路径
# 全靠 disco 自己摸出来，刚起来时要几十秒，而且常常只有一个方向先通。两头互相 ping 一遍，
# 再用真的 TCP 把每条测试要走的路各走一遍；90 秒还走不通就报错退出，不假装就绪。
pair() { dc exec -T "$1" tailscale ping -c 3 --timeout 3s "$2" >/dev/null 2>&1 || true; }
peers=(ts-socks)
$routes && peers+=(ts-relay ts-jump)
for peer in "${peers[@]}"; do pair ts-server "$(ip_of "$peer")"; pair "$peer" "$server_ip"; done
$routes && { pair ts-socks "$jump_ip"; pair ts-jump "$(ip_of ts-socks)"; }
# 内核模式节点：容器里直接 nc。
warm() {  # warm <节点> <目标 ip> <端口>
  for _ in $(seq 1 30); do dc exec -T "$1" nc -z -w 3 "$2" "$3" >/dev/null 2>&1 && return 0; done
  echo "$1 连不到 $2:$3" >&2; return 1
}
# ts-socks 是 userspace，容器里的 nc 进不了 tailnet：从本机经它的 SOCKS 端口走，本机只连 127.0.0.1:21055。
# stdin 要开着：给 </dev/null 的话 macOS 的 nc 读到 EOF 就收工，等不到对面的版本行。
warm_socks() {  # warm_socks <目标 ip> <端口>
  for _ in $(seq 1 15); do
    (sleep 3) | nc -X 5 -x 127.0.0.1:21055 -w 5 "$1" "$2" 2>/dev/null | head -c 4 | grep -q SSH- && return 0
  done
  echo "经 ts-socks 连不到 $1:$2" >&2; return 1
}
warm_socks "$server_ip" 2222 || exit 1
warm_socks "$server_ip" 22 || exit 1
if $routes; then
  warm_socks "$jump_ip" 22 || exit 1
  for node in ts-relay ts-jump; do
    warm "$node" "$server_ip" 2222 || exit 1
    warm "$node" "$server_ip" 22 || exit 1
  done
fi
NODES=$(hs nodes list -o json) SERVER_FPS=$SERVER_FPS JUMP_FPS=$JUMP_FPS ROUTES=$routes python3 - "$RUN/headscale.json" <<'PY'
import json, os, sys
nodes = json.loads(os.environ["NODES"])
out = {"socksProxy": "127.0.0.1:21055", "ordinaryUser": "ordinary", "ordinaryPassword": os.environ["ORDINARY_PASSWORD"]}
for n in nodes:
    ip4 = [a for a in n["ip_addresses"] if ":" not in a][0]
    out[n["given_name"]] = {"ipv4": ip4, "online": n.get("online", False), "tags": n.get("tags") or n.get("forced_tags") or []}
# 主机密钥指纹（SHA256，逗号分隔，每种密钥一个）。Tailscale SSH（22）和普通 OpenSSH（2222）用的是同一组。
out["ts-server"]["fingerprints"] = os.environ["SERVER_FPS"].split(",")
if os.environ["ROUTES"] == "true":
    out["relayProxy"] = {"endpoint": "127.0.0.1:21056", "username": "relayuser", "password": os.environ["RELAY_PASSWORD"]}
    out["jump"] = {"endpoint": "127.0.0.1:22202", "username": "jumper", "password": os.environ["JUMP_PASSWORD"]}
    out["ts-jump"]["fingerprints"] = os.environ["JUMP_FPS"].split(",")
open(sys.argv[1], "w").write(json.dumps(out, indent=2))
secret = ("ordinaryPassword", "password")
def show(v):
    if isinstance(v, dict):
        return {k: ("<见文件>" if k in secret else show(x)) for k, x in v.items()}
    return v
print(json.dumps(show(out), indent=2, ensure_ascii=False))
PY
