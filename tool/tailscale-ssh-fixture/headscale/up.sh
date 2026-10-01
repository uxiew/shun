#!/usr/bin/env bash
# 起 Headscale + 两个真 tailscaled 节点，结果写进 ../.run/headscale.json。见 ../README.md「真 tailscaled」一节。
set -euo pipefail
cd "$(dirname "$0")"
RUN=../.run
mkdir -p "$RUN" && chmod 700 "$RUN"
export SERVER_AUTHKEY=unused SOCKS_AUTHKEY=unused ORDINARY_PASSWORD=unused
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
umask 077
printf 'SERVER_AUTHKEY=%s\nSOCKS_AUTHKEY=%s\nORDINARY_PASSWORD=%s\n' "$SERVER_AUTHKEY" "$SOCKS_AUTHKEY" "$ORDINARY_PASSWORD" > "$RUN/headscale.env"
export SERVER_AUTHKEY SOCKS_AUTHKEY ORDINARY_PASSWORD
docker compose up -d --build ts-server ts-socks >/dev/null

# 等两个节点都在 Headscale 里上线
for _ in $(seq 1 60); do
  n=$(hs nodes list -o json | python3 -c "import json,sys;print(sum(1 for n in json.load(sys.stdin) or [] if n.get('online')))")
  [ "$n" = 2 ] && break; sleep 1
done
# 没有可用的 DERP：两节点的直连路径要先打通，否则头一个经 SOCKS 的连接会报 SOCKS error 1。
server_ip=$(hs nodes list -o json | python3 -c "import json,sys;print([a for n in json.load(sys.stdin) if n['given_name']=='ts-server' for a in n['ip_addresses'] if ':' not in a][0])")
docker compose exec -T ts-socks tailscale ping -c 5 "$server_ip" >/dev/null 2>&1 || true
NODES=$(hs nodes list -o json) python3 - "$RUN/headscale.json" "$ORDINARY_PASSWORD" <<'PY'
import json, os, sys
nodes = json.loads(os.environ["NODES"])
out = {"socksProxy": "127.0.0.1:21055", "ordinaryUser": "ordinary", "ordinaryPassword": sys.argv[2]}
for n in nodes:
    ip4 = [a for a in n["ip_addresses"] if ":" not in a][0]
    out[n["given_name"]] = {"ipv4": ip4, "online": n.get("online", False), "tags": n.get("tags") or n.get("forced_tags") or []}
open(sys.argv[1], "w").write(json.dumps(out, indent=2))
print(json.dumps({k: v for k, v in out.items() if k != "ordinaryPassword"}, indent=2))
PY
