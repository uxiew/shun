#!/usr/bin/env python3
"""SEC05（R28）：App 私有目录、外部存储、整机日志里有没有密码、私钥、代理口令的明文；备份排除有没有生效。

怎么跑（模拟器开好、拿好锁，见 docs/dev/README.md）：

  python3 tool/r28-sec05-device.py <输出目录>

做的事：
  1. 编两个调试包：种子入口 tool/sec05/seed_main.dart（带这轮随机的 SEC05_RUN）和正常的 App。
     种子用 App 自己的 VaultRepository.saveVault 写 6 种假凭据，再读回来。
  2. 同签名覆盖装正常的 App（数据留着），冷启动、打开保险库和设置：真 App 的代码读一遍、该写的缓存写一遍。
  3. run-as 把私有目录整个打包拉回来，连同 /sdcard/Android/data/<包>、logcat 全部缓冲区，
     按 UTF-8、UTF-16LE、base64 三种写法搜 6 个标记。
     app_flutter/flutter_assets/ 是调试包自己的代码（kernel_blob.bin），不搜；标记在运行时拼出来，本来也不在里面。
     对照：先往私有目录和 logcat 各放一个对照标记，搜不到就算失败；主机名这类非秘密字段应当搜得到。
  4. bmgr 用本地传输对调试包和正式包各备份一次，记下系统怎么答，最后换回原来的传输。
只打印标记名字和个数。结束时卸掉调试包（里面是假凭据）。
"""
import base64
import io
import json
import os
import secrets
import shutil
import subprocess
import sys
import tarfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SERIAL = 'emulator-5580'
PKG = 'top.xdwa.shun.debug'
RELEASE = 'top.xdwa.shun'
ACTIVITY = f'{PKG}/top.xdwa.shun.MainActivity'
KINDS = ['hostPassword', 'telnetPassword', 'inlineProxyPassword', 'profileProxyPassword',
         'privateKey', 'passphrase']


def adb(*args, check=False, timeout=120, text=True):
    return subprocess.run(['adb', '-s', SERIAL, *args], capture_output=True, text=text,
                          errors='replace' if text else None, timeout=timeout, check=check)


def build(out, name, extra):
    log = (out / f'build-{name}.log').open('w')
    subprocess.run(['flutter', 'build', 'apk', '--debug', '--target-platform', 'android-arm64',
                    *extra], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    apk = out / f'{name}.apk'
    shutil.copy(ROOT / 'build/app/outputs/flutter-apk/app-debug.apk', apk)
    return apk


def forms(value):
    raw = value.encode()
    return {'utf8': raw, 'utf16le': value.encode('utf-16-le'),
            'base64': base64.b64encode(raw).rstrip(b'=')[:-2]}


def search(blobs, needles):
    """blobs: 名字 → 字节。返回 标记名 → [命中的 文件（写法）]。"""
    hits = {}
    for name, value in needles.items():
        for form, needle in forms(value).items():
            for where, blob in blobs.items():
                if needle in blob:
                    hits.setdefault(name, []).append(f'{where} ({form})')
    return hits


def main():
    out = Path(sys.argv[1]).resolve()
    out.mkdir(parents=True, exist_ok=True)
    run = secrets.token_hex(4)
    markers = {k: f'SEC05-{k}-{run}' for k in KINDS}
    control = f'R28CONTROL-{secrets.token_hex(4)}'
    (out / 'markers.json').write_text(json.dumps({'run': run, 'markers': markers,
                                                  'control': control}, indent=2))
    report = {'run': run}
    seed = build(out, 'seed', ['-t', 'tool/sec05/seed_main.dart', f'--dart-define=SEC05_RUN={run}'])
    app = build(out, 'app', [])
    try:
        adb('uninstall', PKG)
        adb('install', str(seed), check=True)
        adb('logcat', '-b', 'all', '-c')
        adb('shell', 'am', 'start', '-W', '-n', ACTIVITY)
        seeded = ''
        for _ in range(60):
            seeded = adb('logcat', '-d', '-s', 'flutter').stdout
            if 'SEC05 seeded' in seeded:
                break
            time.sleep(1)
        report['seed'] = [l.split('flutter', 1)[-1].strip(' :') for l in seeded.splitlines()
                          if 'SEC05 seeded' in l]
        adb('shell', 'am', 'force-stop', PKG)
        report['install-app'] = adb('install', '-r', str(app)).stdout.strip()
        adb('shell', 'am', 'start', '-W', '-n', ACTIVITY)
        time.sleep(10)
        # 保险库是首页；再点开设置。按屏幕底栏位置点（1080×2340），点偏了也只是少读一页。
        adb('shell', 'input', 'tap', '972', '2114')
        time.sleep(4)
        adb('shell', 'input', 'tap', '108', '2114')
        time.sleep(4)
        report['pid'] = adb('shell', 'pidof', PKG).stdout.strip()
        # 整条作为一个参数交给 adb shell：拆开传的话设备上的 sh 把「>」当成 run-as 外面的重定向，
        # 文件写不进私有目录（R28 第一遍就这样，对照只在 logcat 里立住）。
        adb('shell', f"run-as {PKG} sh -c 'mkdir -p files && echo {control} > files/r28-control.txt'")
        adb('shell', 'log', '-t', 'R28', control)
        adb('shell', 'am', 'force-stop', PKG)

        tar = adb('exec-out', 'run-as', PKG, 'tar', '-cf', '-', '.', text=False).stdout
        (out / 'private.tar').write_bytes(tar)
        blobs, skipped, size = {}, [], 0
        with tarfile.open(fileobj=io.BytesIO(tar)) as archive:
            for member in archive.getmembers():
                if not member.isfile():
                    continue
                name = member.name.lstrip('./')
                if name.startswith('app_flutter/flutter_assets/'):
                    skipped.append(name)
                    continue
                blobs[f'private:{name}'] = archive.extractfile(member).read()
                size += member.size
        report['private'] = {'files': len(blobs), 'bytes': size, 'skipped': len(skipped),
                             'list': sorted(blobs)}
        external = adb('shell', 'ls', '-R', f'/sdcard/Android/data/{PKG}').stdout
        report['externalListing'] = external.strip() or '（没有）'
        for line in adb('shell', 'find', f'/sdcard/Android/data/{PKG}', '-type', 'f').stdout.split():
            blobs[f'external:{line}'] = adb('exec-out', 'cat', line, text=False).stdout
        logcat = adb('logcat', '-b', 'all', '-d', text=False).stdout
        (out / 'logcat.txt').write_bytes(logcat)
        blobs['logcat'] = logcat
        report['logcatLines'] = logcat.count(b'\n')

        report['controlHits'] = search(blobs, {'control': control})
        report['nonSecretHits'] = search(
            {k: v for k, v in blobs.items() if k.startswith('private:')},
            {'hostname': 'sec05.example.com', 'proxyUser': 'sec05-proxy'})
        report['markerHits'] = search(blobs, markers)

        transports = adb('shell', 'bmgr', 'list', 'transports').stdout
        original = next((l.split()[-1] for l in transports.splitlines() if l.startswith('  *')),
                        None)
        # 「Backup Manager currently disabled」：别用 'enabled' in …，「disabled」里也有这几个字母。
        was_enabled = adb('shell', 'bmgr', 'enabled').stdout.strip().endswith(' enabled')
        report['bmgr'] = {'enabled': adb('shell', 'bmgr', 'enabled').stdout.strip(),
                          'transports': transports.strip()}
        adb('shell', 'bmgr', 'enable', 'true')
        adb('shell', 'bmgr', 'transport', 'com.android.localtransport/.LocalTransport')
        for package in [PKG, RELEASE]:
            report['bmgr'][package] = adb('shell', 'bmgr', 'backupnow', package,
                                          timeout=180).stdout.strip()
        if original:
            adb('shell', 'bmgr', 'transport', original)
        if not was_enabled:
            adb('shell', 'bmgr', 'enable', 'false')
        report['bmgr']['restoredTransport'] = original
        report['bmgr']['restoredEnabled'] = adb('shell', 'bmgr', 'enabled').stdout.strip()
    finally:
        adb('uninstall', PKG)
    (out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
    printable = {k: v for k, v in report.items() if k != 'private'}
    printable['private'] = {k: v for k, v in report['private'].items() if k != 'list'}
    print(json.dumps(printable, ensure_ascii=False, indent=2))
    places = {hit.split(':')[0].split(' ')[0] for hit in report['controlHits'].get('control', [])}
    ok = ({'private', 'logcat'} <= places and not report['markerHits']
          and report['nonSecretHits'])
    print('SEC05', 'PASS' if ok else 'FAIL')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
