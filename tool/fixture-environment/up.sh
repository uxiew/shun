#!/usr/bin/env bash
# 启动测试用 SSH/SOCKS 拓扑，并把连接参数写到 .run/fixture.json 给测试读。
# 每次运行都重新生成密码、客户端密钥和主机密钥；旧的立即作废。
set -euo pipefail
cd "$(dirname "$0")"

docker compose down --remove-orphans >/dev/null 2>&1 || true
rm -rf .run
# secrets/ 挂进容器（只放密码和公钥）；client/ 放私钥，只给本机测试用，不进容器。
mkdir -p .run/secrets .run/client .run/hostkeys
chmod 700 .run .run/client
openssl rand -hex 16 > .run/secrets/ssh_password
openssl rand -hex 16 > .run/secrets/socks_password
ssh-keygen -q -t ed25519 -N '' -C xwshun-fixture -f .run/client/id_ed25519
cp .run/client/id_ed25519.pub .run/secrets/id_ed25519.pub

docker compose up -d --build >/dev/null

# 等三台 sshd 写出主机密钥、三个端口可连。60 秒没好就报错退出，不假装就绪。
for _ in $(seq 60); do
  if [[ -s .run/hostkeys/ssh-edge.pub && -s .run/hostkeys/target.pub && -s .run/hostkeys/ssh-hop2.pub ]] \
    && nc -z 127.0.0.1 22201 && nc -z 127.0.0.1 21080 && nc -z 127.0.0.1 21081; then
    break
  fi
  sleep 1
done
for f in ssh-edge target ssh-hop2; do
  [[ -s .run/hostkeys/$f.pub ]] || { echo "fixture 未就绪：$f 没有主机密钥" >&2; docker compose logs --tail 30 >&2; exit 1; }
done

python3 - <<'EOF'
import json, pathlib, datetime
run = pathlib.Path('.run').resolve()
def key(name):
    fp = (run / 'hostkeys' / f'{name}.sha256').read_text().split()[1]
    pub = (run / 'hostkeys' / f'{name}.pub').read_text().split()
    return {'fingerprintSha256': fp, 'keyType': pub[0], 'publicKeyBase64': pub[1]}
secret = lambda n: (run / 'secrets' / n).read_text().strip()
fixture = {
    'generatedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'note': '临时测试凭据，fixture 销毁即失效；不得用于任何真实主机',
    'user': 'fixture',
    'password': secret('ssh_password'),
    'privateKeyPath': str(run / 'client' / 'id_ed25519'),
    'sshEdge': {'host': '127.0.0.1', 'port': 22201, **key('ssh-edge')},
    'socksAuth': {'host': '127.0.0.1', 'port': 21080, 'username': 'socksuser', 'password': secret('socks_password')},
    'socksNoAuth': {'host': '127.0.0.1', 'port': 21081},
    'target': {'name': 'target.fixture.internal', 'port': 22, **key('target')},
    'hop2': {'name': 'hop2.fixture.internal', 'port': 22, **key('ssh-hop2')},
}
path = run / 'fixture.json'
path.write_text(json.dumps(fixture, indent=2, ensure_ascii=False) + '\n')
path.chmod(0o600)
print(path)
EOF
