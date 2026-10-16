#!/usr/bin/env bash
# 启动 Mosh 测试环境，把连接参数写到 .run/fixture.json。每次运行都重新生成密码、客户端密钥和主机密钥。
set -euo pipefail
cd "$(dirname "$0")"

docker compose down --remove-orphans >/dev/null 2>&1 || true
rm -rf .run
mkdir -p .run/secrets .run/client .run/hostkeys .run/hostkeys-nomosh .run/hostkeys-moshalt
chmod 700 .run .run/client
openssl rand -hex 16 > .run/secrets/ssh_password
ssh-keygen -q -t ed25519 -N '' -C shun-mosh-fixture -f .run/client/id_ed25519
cp .run/client/id_ed25519.pub .run/secrets/id_ed25519.pub

docker compose up -d --build >/dev/null

for _ in $(seq 60); do
  if [[ -s .run/hostkeys/mosh.pub && -s .run/hostkeys-nomosh/mosh.pub && -s .run/hostkeys-moshalt/mosh.pub ]] \
     && nc -z 127.0.0.1 22301 && nc -z 127.0.0.1 22302 && nc -z 127.0.0.1 22303; then break; fi
  sleep 1
done
[[ -s .run/hostkeys/mosh.pub && -s .run/hostkeys-nomosh/mosh.pub && -s .run/hostkeys-moshalt/mosh.pub ]] \
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
# moshalt 要同时满足三条，R41 的覆盖项测试才有意义：PATH 里没有 mosh-server、它在 /opt/mosh-alt/bin、没有 en_US.UTF-8。
if ssh_fixture 22303 'command -v mosh-server' >/dev/null 2>&1; then
  echo "22303 的 PATH 里有 mosh-server，测不了「不在默认路径」" >&2; exit 1
fi
ssh_fixture 22303 'test -x /opt/mosh-alt/bin/mosh-server' \
  || { echo "22303 上没有 /opt/mosh-alt/bin/mosh-server" >&2; exit 1; }
if ssh_fixture 22303 'locale -a' | grep -qiE '^en_US\.utf-?8$'; then
  echo "22303 上有 en_US.UTF-8，测不了 locale 覆盖" >&2; exit 1
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
moshalt_fp, _ = host('hostkeys-moshalt')
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
    # Debian：mosh-server 只在这个路径，只有 C.UTF-8（R41 的 Mosh 覆盖项）。
    'moshaltPort': 22303,
    'moshaltFingerprintSha256': moshalt_fp,
    'moshaltServerPath': '/opt/mosh-alt/bin/mosh-server',
    'moshaltLocale': 'C.UTF-8',
}
path = run / 'fixture.json'
path.write_text(json.dumps(fixture, indent=2, ensure_ascii=False) + '\n')
path.chmod(0o600)
print(path)
PY
