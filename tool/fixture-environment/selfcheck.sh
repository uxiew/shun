#!/usr/bin/env bash
# 用系统自带的 OpenSSH/curl 验证 fixture 拓扑本身成立，和 App 代码无关。
# App 测试失败时先跑这个：这里挂了说明是环境问题，不是 App 的锅。
set -uo pipefail
cd "$(dirname "$0")"
F=.run/fixture.json
[[ -f $F ]] || { echo "没有 $F，先运行 ./up.sh" >&2; exit 1; }
j() { python3 -c "import json,sys;d=json.load(open('$F'));print(eval(sys.argv[1]))" "$1"; }

KH=.run/known_hosts
{
  echo "[127.0.0.1]:22201 $(j "d['sshEdge']['keyType']") $(j "d['sshEdge']['publicKeyBase64']")"
  echo "target.fixture.internal $(j "d['target']['keyType']") $(j "d['target']['publicKeyBase64']")"
  echo "hop2.fixture.internal $(j "d['hop2']['keyType']") $(j "d['hop2']['publicKeyBase64']")"
} > "$KH"
# -F /dev/null + IdentityAgent=none：不让本机 ~/.ssh/config 和 ssh-agent 里的真实密钥掺进来。
SSH=(ssh -F /dev/null -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=yes -o BatchMode=yes
     -o IdentitiesOnly=yes -o IdentityAgent=none -o ConnectTimeout=5 -i .run/client/id_ed25519)
SOCKS_PW=$(j "d['socksAuth']['password']")
fail=0
check() { # 名称 期望(ok|fail) 命令...
  local name=$1 want=$2; shift 2
  if out=$("$@" 2>&1); then got=ok; else got=fail; fi
  if [[ $got == "$want" ]]; then echo "PASS  ${name}"; else echo "FAIL  ${name}（期望 ${want}，实际 ${got}）: ${out:0:200}"; fail=1; fi
}

check "边缘 sshd 公钥登录" ok "${SSH[@]}" -p 22201 fixture@127.0.0.1 true
check "无认证 SOCKS 到达仅代理可解析的目标" ok \
  "${SSH[@]}" -o ProxyCommand='nc -X 5 -x 127.0.0.1:21081 %h %p' fixture@target.fixture.internal true
# 不能用 curl --noproxy '*'：它会连 SOCKS 一起禁掉，curl 变成直连，"错口令被拒"会因为错误的原因通过。
# 用 env -u 去掉本机 http(s)_proxy，再用 -x socks5h:// 明确指定（h = 目标名交给代理解析）。
CURL=(env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy curl -s --max-time 3)
check "认证 SOCKS 正确口令能拿到目标 SSH banner" ok bash -c \
  "${CURL[*]} -x 'socks5h://socksuser:$SOCKS_PW@127.0.0.1:21080' telnet://target.fixture.internal:22 </dev/null | grep -q '^SSH-2.0-'"
check "认证 SOCKS 错口令被拒" fail bash -c \
  "${CURL[*]} -x 'socks5h://socksuser:wrong@127.0.0.1:21080' telnet://target.fixture.internal:22 </dev/null | grep -q '^SSH-2.0-'"
check "认证 SOCKS 不给口令被拒" fail bash -c \
  "${CURL[*]} -x 'socks5h://127.0.0.1:21080' telnet://target.fixture.internal:22 </dev/null | grep -q '^SSH-2.0-'"
# 注意：本机若开了 fake-ip 类 TUN（如 Clash，任何名字都解析成 198.18.x.x），"解析失败"不成立，
# 所以这里检查的是"直连拿不到目标的 SSH banner"，而不是 DNS 失败。
check "本机直连目标名拿不到 SSH banner（证明只能经代理/跳板）" fail bash -c \
  "nc -w 3 target.fixture.internal 22 </dev/null 2>/dev/null | head -c 8 | grep -q '^SSH-2.0'"
check "ProxyJump：边缘→目标" ok \
  "${SSH[@]}" -o ProxyCommand="${SSH[*]} -W %h:%p -p 22201 fixture@127.0.0.1" fixture@target.fixture.internal true
# 内层 ProxyCommand 的 %h:%p 必须写成 %%h:%%p，否则会被外层 ssh 提前替换成目标地址，
# 最内层就跳去了 target 而不是 hop2——此时 hop2 那一跳收到 target 的公钥，报"主机身份已改变"。
check "ProxyJump 二跳：边缘→hop2→目标" ok \
  "${SSH[@]}" -o ProxyCommand="${SSH[*]} -o ProxyCommand='${SSH[*]} -W %%h:%%p -p 22201 fixture@127.0.0.1' -W %h:%p fixture@hop2.fixture.internal" fixture@target.fixture.internal true
exit $fail
