#!/usr/bin/env bash
# 启动 R21 的 tmux 测试环境，把连接参数写到 .run/fixture.json 给测试读。
# 每次运行都重新生成密码、客户端密钥和主机密钥；旧的立即作废。
set -euo pipefail
cd "$(dirname "$0")"

docker compose down --remove-orphans >/dev/null 2>&1 || true
rm -rf .run
mkdir -p .run/secrets .run/client .run/hostkeys
chmod 700 .run .run/client
openssl rand -hex 16 > .run/secrets/ssh_password
ssh-keygen -q -t ed25519 -N '' -C shun-tmux-fixture -f .run/client/id_ed25519
cp .run/client/id_ed25519.pub .run/secrets/id_ed25519.pub

docker compose up -d --build >/dev/null

nodes="tmux24:22311 tmux27:22312 tmux30:22313 tmux35:22314 notmux:22315 faketmux:22316"
# 60 秒没就绪就报错退出，不假装就绪。
for _ in $(seq 60); do
  ready=yes
  for node in $nodes; do
    [[ -s .run/hostkeys/${node%%:*}.tmux ]] && nc -z 127.0.0.1 "${node##*:}" 2>/dev/null || ready=no
  done
  [[ $ready == yes ]] && break
  sleep 1
done
for node in $nodes; do
  [[ -s .run/hostkeys/${node%%:*}.tmux ]] || { echo "tmux fixture 未就绪：${node%%:*}" >&2; docker compose logs --tail 30 >&2; exit 1; }
done

NODES="$nodes" python3 - <<'EOF'
import json, os, pathlib, datetime
run = pathlib.Path('.run').resolve()
nodes = {}
for item in os.environ['NODES'].split():
    name, port = item.split(':')
    fp = (run / 'hostkeys' / f'{name}.sha256').read_text().split()[1]
    nodes[name] = {
        'host': '127.0.0.1',
        'port': int(port),
        'fingerprintSha256': fp,
        'tmuxVersion': (run / 'hostkeys' / f'{name}.tmux').read_text().strip(),
    }
fixture = {
    'generatedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'note': '临时测试凭据，fixture 销毁即失效；不得用于任何真实主机',
    'users': {'fixture': 1000, 'other': 1001},
    'password': (run / 'secrets' / 'ssh_password').read_text().strip(),
    'nodes': nodes,
}
path = run / 'fixture.json'
path.write_text(json.dumps(fixture, indent=2, ensure_ascii=False) + '\n')
path.chmod(0o600)
for name, node in nodes.items():
    print(f"{name:9} 127.0.0.1:{node['port']}  {node['tmuxVersion']}")
print(path)
EOF
