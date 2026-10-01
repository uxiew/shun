#!/usr/bin/env bash
# R15 拓扑自检：不经 App，用本机的 OpenSSH 客户端把「同一台 ts-server 经四条路线」各走一遍。
# 先 ./up.sh routes。全部 PASS 才说明测试环境本身成立；App 的测试失败时先跑它，分清是环境坏了还是 App 的问题。
#
# 本机只连 127.0.0.1 上的三个端口（21055 / 21056 / 22202），100.x 一律交给代理或跳板去连：
# 开发机自己可能就在真实 tailnet 上，直接连 100.x 会连进真实 tailnet。
set -uo pipefail
cd "$(dirname "$0")"
RUN=$(cd ../.run && pwd)
J=$RUN/headscale.json
[ -s "$J" ] || { echo "没有 $J：先 ./up.sh routes" >&2; exit 1; }
v() { python3 -c "import json,sys;d=json.load(open('$J'));print(eval(sys.argv[1]))" "$1"; }
SERVER=$(v "d['ts-server']['ipv4']")
SOCKS_NODE=$(v "d['ts-socks']['ipv4']")
RELAY_NODE=$(v "d['ts-relay']['ipv4']")
JUMP_NODE=$(v "d['ts-jump']['ipv4']")
export ORDINARY_PASSWORD JUMP_PASSWORD SOCKS_USER SOCKS_PASS
ORDINARY_PASSWORD=$(v "d['ordinaryPassword']")
JUMP_PASSWORD=$(v "d['jump']['password']")
SOCKS_USER=$(v "d['relayProxy']['username']")
SOCKS_PASS=$(v "d['relayProxy']['password']")

# ssh 要密码时按提示里的用户名给：跳板机是 jumper，普通 OpenSSH 是 ordinary。
ASKPASS=$RUN/selfcheck-askpass.sh
KNOWN=$RUN/selfcheck_known_hosts
trap 'rm -f "$ASKPASS" "$KNOWN"' EXIT
cat > "$ASKPASS" <<'EOF'
#!/bin/sh
case "$1" in
  *jumper@*) printf '%s\n' "$JUMP_PASSWORD" ;;
  *ordinary@*) printf '%s\n' "$ORDINARY_PASSWORD" ;;
  *) exit 1 ;;
esac
EOF
chmod 700 "$ASKPASS"
export SSH_ASKPASS=$ASKPASS SSH_ASKPASS_REQUIRE=force DISPLAY=none

PIPE="$PWD/socks5-pipe.py"
LOCAL="nc -X 5 -x 127.0.0.1:21055 %h %p"
RELAY="python3 $PIPE 127.0.0.1 21056 %h %p"
JUMP_DIRECT="ssh -F /dev/null -o UserKnownHostsFile=$KNOWN -o StrictHostKeyChecking=no -o IdentityAgent=none -p 22202 -W %h:%p jumper@127.0.0.1"
# 嵌套：外层 ssh 先替换一遍 %，所以给里层 ssh 的 nc 要写 %%h %%p，-W 的 %h:%p 则由外层换成目标。
JUMP_VIA_SOCKS="ssh -F /dev/null -o UserKnownHostsFile=$KNOWN -o StrictHostKeyChecking=no -o IdentityAgent=none -o 'ProxyCommand=nc -X 5 -x 127.0.0.1:21055 %%h %%p' -W %h:%p jumper@$JUMP_NODE"

pass=0 fail=0
check() {  # check <名字> <ProxyCommand> <用户@端口> <期望：一段输出 或 DENIED>
  local name=$1 proxy=$2 user=${3%@*} port=${3#*@} want=$4 out
  out=$(ssh -F /dev/null -o BatchMode=no -o UserKnownHostsFile="$KNOWN" -o StrictHostKeyChecking=no \
          -o IdentityAgent=none -o PubkeyAuthentication=no -o ConnectTimeout=20 \
          -o "ProxyCommand=$proxy" -p "$port" "$user@$SERVER" 'echo "from=${SSH_CLIENT%% *} user=$(whoami)"' 2>&1)
  if [[ "$want" == DENIED ]]; then
    if grep -q "tailnet policy does not permit" <<<"$out" && ! grep -q "^from=" <<<"$out"; then
      echo "PASS ${name}：Tailscale 拒绝（$(grep -o 'tailscale: [^.]*' <<<"$out" | head -1)）"; pass=$((pass+1))
    else
      echo "FAIL ${name}：期望被 Tailscale 拒绝，实际：$(tail -2 <<<"$out" | tr '\n' ' ')"; fail=$((fail+1))
    fi
  elif grep -q "^$want\$" <<<"$out"; then
    echo "PASS ${name}：$want"; pass=$((pass+1))
  else
    echo "FAIL ${name}：期望 ${want}，实际：$(tail -2 <<<"$out" | tr '\n' ' ')"; fail=$((fail+1))
  fi
}

# 普通 OpenSSH（2222）：四条路线都能密码登录。userspace tailscaled 把进来的连接转给本机端口，来源看到的都是 127.0.0.1。
check "本地 SOCKS → 普通 SSH"       "$LOCAL"          ordinary@2222 "from=127.0.0.1 user=ordinary"
check "远程 SOCKS → 普通 SSH"       "$RELAY"          ordinary@2222 "from=127.0.0.1 user=ordinary"
check "跳板 → 普通 SSH"             "$JUMP_DIRECT"    ordinary@2222 "from=127.0.0.1 user=ordinary"
check "代理入口+跳板 → 普通 SSH"    "$JUMP_VIA_SOCKS" ordinary@2222 "from=127.0.0.1 user=ordinary"
# Tailscale SSH（22，acceptuser）：认的是承载连接的那个节点，不是手机、也不是目录账号。
check "本地 SOCKS → Tailscale SSH"     "$LOCAL"          acceptuser@22 "from=$SOCKS_NODE user=acceptuser"
check "远程 SOCKS → Tailscale SSH"     "$RELAY"          acceptuser@22 DENIED
check "跳板 → Tailscale SSH"           "$JUMP_DIRECT"    acceptuser@22 "from=$JUMP_NODE user=acceptuser"
check "代理入口+跳板 → Tailscale SSH"  "$JUMP_VIA_SOCKS" acceptuser@22 "from=$JUMP_NODE user=acceptuser"

echo "节点：ts-socks=$SOCKS_NODE ts-relay=$RELAY_NODE ts-jump=$JUMP_NODE ts-server=$SERVER"
echo "$pass PASS / $fail FAIL"
[ "$fail" = 0 ]
