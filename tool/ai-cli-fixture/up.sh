#!/usr/bin/env bash
# 起 TER13 的测试容器：127.0.0.1:22401 上的 sshd，里面装着 Claude Code、Codex CLI（都不登录）。
# 每次运行都换密码和主机密钥。连接参数写到 .run/fixture.json，设备测试的参数用 ./config.py 取。
set -euo pipefail
cd "$(dirname "$0")"
NAME=xwshun-ai-cli
IMAGE=xwshun-ai-cli:local

docker rm -f "$NAME" >/dev/null 2>&1 || true
rm -rf .run
mkdir -p .run/secrets .run/hostkeys
chmod 700 .run
openssl rand -hex 16 > .run/secrets/ssh_password

docker build -q -t "$IMAGE" . >/dev/null
docker run -d --name "$NAME" -p 127.0.0.1:22401:22 \
  -v "$PWD/.run/secrets:/secrets:ro" -v "$PWD/.run/hostkeys:/hostkeys" "$IMAGE" >/dev/null

for _ in $(seq 60); do
  [[ -s .run/hostkeys/ai-cli.sha256 ]] && nc -z 127.0.0.1 22401 && break
  sleep 1
done
[[ -s .run/hostkeys/ai-cli.sha256 ]] || { echo "没起来" >&2; docker logs --tail 30 "$NAME" >&2; exit 1; }

python3 - <<'EOF'
import json, pathlib
run = pathlib.Path('.run').resolve()
fixture = {
    'note': '临时测试凭据，down.sh 后失效；不得用于任何真实主机',
    'port': 22401,
    'user': 'fixture',
    'password': (run / 'secrets' / 'ssh_password').read_text().strip(),
    'fingerprint': (run / 'hostkeys' / 'ai-cli.sha256').read_text().split()[1],
    'versions': (run / 'hostkeys' / 'versions.txt').read_text().strip().splitlines(),
}
path = run / 'fixture.json'
path.write_text(json.dumps(fixture, indent=2, ensure_ascii=False) + '\n')
path.chmod(0o600)
print(path)
print('\n'.join(fixture['versions']))
EOF
