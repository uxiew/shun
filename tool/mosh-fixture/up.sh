#!/usr/bin/env bash
# 启动 Mosh 测试环境，把连接参数写到 .run/fixture.json。每次运行都重新生成密码、客户端密钥和主机密钥。
set -euo pipefail
cd "$(dirname "$0")"

docker compose down --remove-orphans >/dev/null 2>&1 || true
rm -rf .run
mkdir -p .run/secrets .run/client .run/hostkeys .run/hostkeys-nomosh
chmod 700 .run .run/client
openssl rand -hex 16 > .run/secrets/ssh_password
ssh-keygen -q -t ed25519 -N '' -C shun-mosh-fixture -f .run/client/id_ed25519
cp .run/client/id_ed25519.pub .run/secrets/id_ed25519.pub

docker compose up -d --build >/dev/null

for _ in $(seq 60); do
  if [[ -s .run/hostkeys/mosh.pub && -s .run/hostkeys-nomosh/mosh.pub ]] \
     && nc -z 127.0.0.1 22301 && nc -z 127.0.0.1 22302; then break; fi
  sleep 1
done
[[ -s .run/hostkeys/mosh.pub && -s .run/hostkeys-nomosh/mosh.pub ]] \
  || { echo "mosh fixture 未就绪" >&2; docker compose logs --tail 30 >&2; exit 1; }

# 记账的假命令要排在真命令前面才数得到（Dockerfile 里的说明）。不对就别用这套环境出 X09 的计数证据。
ssh_fixture() {
  ssh -F /dev/null -o IdentityAgent=none -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i .run/client/id_ed25519 -p "$1" mosh@127.0.0.1 "$2"
}
[[ "$(ssh_fixture 22301 'command -v mosh-server')" == /usr/local/bin/mosh-server ]] \
  || { echo "22301 上 mosh-server 没走记账脚本，计数不可信" >&2; exit 1; }
[[ "$(ssh_fixture 22302 'command -v sudo')" == /usr/local/bin/sudo ]] \
  || { echo "22302 上 sudo 没走记账脚本，计数不可信" >&2; exit 1; }
if ssh_fixture 22302 'command -v mosh-server' >/dev/null 2>&1; then
  echo "22302 上居然有 mosh-server，nomosh 那台装错了" >&2; exit 1
fi

python3 - <<'PY'
import json, pathlib, datetime
run = pathlib.Path('.run').resolve()
def host(directory):
    fp = (run / directory / 'mosh.sha256').read_text().split()[1]
    pub = (run / directory / 'mosh.pub').read_text().split()
    return fp, pub
fp, pub = host('hostkeys')
nomosh_fp, _ = host('hostkeys-nomosh')
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
    # 同样的账号和密码，但服务器上没装 mosh（X09 的 MOS02）。
    'nomoshPort': 22302,
    'nomoshFingerprintSha256': nomosh_fp,
}
path = run / 'fixture.json'
path.write_text(json.dumps(fixture, indent=2, ensure_ascii=False) + '\n')
path.chmod(0o600)
print(path)
PY
