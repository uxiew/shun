#!/usr/bin/env python3
"""经本机 HTTP 代理从 Docker 官方仓库拉镜像，逐个校验 SHA256 后 docker load。

什么时候用：fixture 的 up.sh 构建时报
  failed to fetch anonymous token: Get "https://auth.docker.io/token?...": dial tcp [...]:443: i/o timeout
说白了就是 Docker 守护进程直连 Docker Hub 连不上。OrbStack 只跟随系统代理，本机代理只靠环境变量用时它就走直连。
先用这个脚本把 Dockerfile 里 FROM 的基础镜像拉到本机，再重跑 up.sh（本地有了就不再去拉）。

只在当前命令里走代理：不改 OrbStack/Docker 的全局设置（会影响别的项目），不用第三方镜像站。
清单和每个 blob 都按仓库给的 sha256 摘要核对，对不上就停、不 load。

  python3 tool/docker-pull-via-proxy.py alpine:3.22 debian:trixie-slim
  python3 tool/docker-pull-via-proxy.py --proxy http://127.0.0.1:7890 --platform linux/arm64 alpine:3.22
"""
import argparse
import hashlib
import json
import os
import platform
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request

REGISTRY = 'https://registry-1.docker.io'
AUTH = 'https://auth.docker.io/token'
INDEX_TYPES = {
    'application/vnd.oci.image.index.v1+json',
    'application/vnd.docker.distribution.manifest.list.v2+json',
}
MANIFEST_TYPES = {
    'application/vnd.oci.image.manifest.v1+json',
    'application/vnd.docker.distribution.manifest.v2+json',
}


def parse_ref(ref):
    name, _, tag = ref.partition(':')
    if not name or '@' in ref or '.' in name.split('/')[0]:
        raise SystemExit(f'只支持 Docker Hub 的 name[:tag]：{ref}')
    repo = name if '/' in name else f'library/{name}'
    tag = tag or 'latest'
    return repo, tag, f'{name}:{tag}'


class Registry:
    def __init__(self, proxy):
        handlers = [urllib.request.ProxyHandler({'http': proxy, 'https': proxy})] if proxy else []
        self.opener = urllib.request.build_opener(*handlers)
        self.tokens = {}

    def _token(self, repo):
        if repo not in self.tokens:
            query = urllib.parse.urlencode({'service': 'registry.docker.io',
                                            'scope': f'repository:{repo}:pull'})
            with self.opener.open(f'{AUTH}?{query}', timeout=60) as r:
                self.tokens[repo] = json.load(r)['token']
        return self.tokens[repo]

    def open(self, repo, path, accept=None):
        headers = {'Authorization': f'Bearer {self._token(repo)}'}
        if accept:
            headers['Accept'] = ', '.join(sorted(accept))
        request = urllib.request.Request(f'{REGISTRY}/v2/{repo}/{path}', headers=headers)
        return self.opener.open(request, timeout=120)

    def manifest(self, repo, reference, expected=None):
        with self.open(repo, f'manifests/{reference}', INDEX_TYPES | MANIFEST_TYPES) as r:
            body = r.read()
            media = r.headers.get('Content-Type', '').split(';')[0]
            header = r.headers.get('Docker-Content-Digest')
        digest = 'sha256:' + hashlib.sha256(body).hexdigest()
        if digest != (expected or header):
            raise SystemExit(f'清单摘要对不上：{repo}:{reference} 算出 {digest}，应为 {expected or header}')
        return media, json.loads(body), digest

    def blob(self, repo, digest, path):
        algorithm, _, hexdigest = digest.partition(':')
        if algorithm != 'sha256' or len(hexdigest) != 64:
            raise SystemExit(f'不认识的摘要：{digest}')
        h = hashlib.sha256()
        with self.open(repo, f'blobs/{digest}') as r, open(path, 'wb') as out:
            while chunk := r.read(1 << 20):
                h.update(chunk)
                out.write(chunk)
        if h.hexdigest() != hexdigest:
            raise SystemExit(f'blob 摘要对不上：{digest}')


def default_platform():
    machine = platform.machine().lower()
    return 'linux/' + {'x86_64': 'amd64', 'aarch64': 'arm64'}.get(machine, machine)


def pull(registry, ref, wanted, workdir):
    repo, tag, name = parse_ref(ref)
    media, manifest, digest = registry.manifest(repo, tag)
    if media in INDEX_TYPES:
        os_name, arch = wanted.split('/', 1)
        choices = [m for m in manifest['manifests']
                   if m.get('platform', {}).get('os') == os_name
                   and m.get('platform', {}).get('architecture') == arch]
        if len(choices) != 1:
            raise SystemExit(f'{name} 没有唯一的 {wanted} 清单（找到 {len(choices)} 个）')
        digest = choices[0]['digest']
        media, manifest, digest = registry.manifest(repo, digest, expected=digest)
    if media not in MANIFEST_TYPES:
        raise SystemExit(f'{name} 的清单类型不认识：{media}')
    blobs = os.path.join(workdir, 'blobs', 'sha256')
    os.makedirs(blobs, exist_ok=True)
    def local(d):
        return os.path.join('blobs', 'sha256', d.split(':', 1)[1])
    config = manifest['config']['digest']
    registry.blob(repo, config, os.path.join(workdir, local(config)))
    layers = [layer['digest'] for layer in manifest['layers']]
    for layer in layers:
        registry.blob(repo, layer, os.path.join(workdir, local(layer)))
    print(f'{name} {wanted} manifest {digest}：{len(layers)} 层，全部摘要核对通过')
    return {'Config': local(config), 'RepoTags': [name], 'Layers': [local(d) for d in layers]}


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('images', nargs='+')
    parser.add_argument('--proxy', default=os.environ.get('https_proxy')
                        or os.environ.get('HTTPS_PROXY') or 'http://127.0.0.1:7890')
    parser.add_argument('--platform', default=default_platform())
    args = parser.parse_args()
    registry = Registry(args.proxy)
    with tempfile.TemporaryDirectory(prefix='shun-image-') as workdir:
        entries = [pull(registry, ref, args.platform, workdir) for ref in args.images]
        with open(os.path.join(workdir, 'manifest.json'), 'w') as f:
            json.dump(entries, f)
        archive = os.path.join(workdir, 'images.tar')
        with tarfile.open(archive, 'w') as tar:
            tar.add(os.path.join(workdir, 'manifest.json'), 'manifest.json')
            tar.add(os.path.join(workdir, 'blobs'), 'blobs')
        subprocess.run(['docker', 'load', '-i', archive], check=True)


if __name__ == '__main__':
    try:
        main()
    except (OSError, subprocess.CalledProcessError) as error:
        print(f'FAIL: {error}', file=sys.stderr)
        sys.exit(1)
