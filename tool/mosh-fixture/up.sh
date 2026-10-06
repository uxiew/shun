#!/usr/bin/env bash
# 启动 Mosh 测试环境，把连接参数写到 .run/fixture.json。每次运行都重新生成密码、客户端密钥和主机密钥。
set -euo pipefail
cd "$(dirname "$0")"

docker compose down --remove-orphans >/dev/null 2>&1 || true
rm -rf .run
mkdir -p .run/secrets .run/client .run/hostkeys
chmod 700 .run .run/client
openssl rand -hex 16 > .run/secrets/ssh_password
ssh-keygen -q -t ed25519 -N '' -C xwshun-mosh-fixture -f .run/client/id_ed25519
cp .run/client/id_ed25519.pub .run/secrets/id_ed25519.pub

docker compose up -d --build >/dev/null

for _ in $(seq 60); do
  if [[ -s .run/hostkeys/mosh.pub ]] && nc -z 127.0.0.1 22301; then break; fi
  sleep 1
done
[[ -s .run/hostkeys/mosh.pub ]] || { echo "mosh fixture 未就绪" >&2; docker compose logs --tail 30 >&2; exit 1; }

python3 - <<'PY'
import json, pathlib, datetime
run = pathlib.Path('.run').resolve()
fp = (run / 'hostkeys' / 'mosh.sha256').read_text().split()[1]
pub = (run / 'hostkeys' / 'mosh.pub').read_text().split()
fixture = {
    'generatedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'note': '临时测试凭据，fixture 销毁即失效；不得用于任何真实主机',
    'user': 'mosh',
    'password': (run / 'secrets' / 'ssh_password').read_text().strip(),
    'privateKeyPath': str(run / 'client' / 'id_ed25519'),
    'host': '127.0.0.1',
    'sshPort': 22301,
    'udpPorts': [60101, 60108],
    'fingerprintSha256': fp,
    'keyType': pub[0],
    'publicKeyBase64': pub[1],
}
path = run / 'fixture.json'
path.write_text(json.dumps(fixture, indent=2, ensure_ascii=False) + '\n')
path.chmod(0o600)
print(path)
PY
