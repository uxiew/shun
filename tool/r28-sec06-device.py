#!/usr/bin/env python3
"""SEC06（R28）：安全存储里的密文被改、包裹密钥没了（模拟 Keystore 密钥失效）时，App 失败关闭：
不崩、告诉用户哪几条解不开、不把空值当成「没存过」、不出现明文。

怎么跑：先跑完 tool/r28-sec05-device.py（用它编好的 seed.apk、app.apk 和那一轮的标记），再

  python3 tool/r28-sec06-device.py <SEC05 的输出目录> <输出目录>

保险库用 encryptedSharedPreferences：FlutterSecureStorage.xml 里既有每条凭据的密文，也有两条
`__androidx_security_crypto_encrypted_prefs_{key,value}_keyset__`（Tink 密钥集，外面由 Keystore 主密钥包着）。
FlutterSecureKeyStorage.xml 是不加密偏好模式用的，保险库不用——删它什么都不会发生（R28 第一遍这样测错过）。
两个场景，各自从干净安装、种子写入开始：
  tamper   每条凭据密文中间改一个字符，密钥集不动（密文被改）
  key-lost 删掉两条密钥集，密文不动（等于 Keystore 里的密钥没了，密文再也解不开）
改完冷启动正常 App，看进程还在不在、保险库页有没有「N 条无法解密」，再把私有目录和 logcat 搜一遍标记。
真的删掉 AndroidKeyStore 里的主密钥要 root 或 App 自己来删，这台 Play 镜像做不到；删密钥集是近似。
"""
import importlib.util
import io
import json
import re
import subprocess
import sys
import tarfile
import time
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    'sec05', Path(__file__).resolve().parent / 'r28-sec05-device.py')
sec05 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sec05)
adb, PKG, ACTIVITY = sec05.adb, sec05.PKG, sec05.ACTIVITY
PREFS = 'shared_prefs/FlutterSecureStorage.xml'


def seed(source):
    adb('uninstall', PKG)
    adb('install', str(source / 'seed.apk'), check=True)
    adb('logcat', '-b', 'all', '-c')
    adb('shell', 'am', 'start', '-W', '-n', ACTIVITY)
    for _ in range(60):
        if 'roundTrip=true' in adb('logcat', '-d', '-s', 'flutter').stdout:
            break
        time.sleep(1)
    else:
        raise SystemExit('种子没写成')
    adb('shell', 'am', 'force-stop', PKG)
    adb('install', '-r', str(source / 'app.apk'), check=True)


ENTRY = re.compile(r'(<string name="([^"]+)">)([^<]+)(</string>)')
KEYSET = '__androidx_security_crypto_encrypted_prefs_'


def rewrite(edit):
    xml = adb('shell', f'run-as {PKG} cat {PREFS}').stdout
    changed = edit(xml)
    subprocess.run(['adb', '-s', sec05.SERIAL, 'shell',
                    f"run-as {PKG} sh -c 'cat > {PREFS}'"], input=changed.encode(), check=True)
    after = adb('shell', f'run-as {PKG} cat {PREFS}').stdout
    names = [m.group(2) for m in ENTRY.finditer(xml)]
    return {'keysets': sum(KEYSET in n for n in names),
            'secrets': sum(KEYSET not in n for n in names),
            'keysetsAfter': sum(KEYSET in m.group(2) for m in ENTRY.finditer(after)),
            'changedOnDevice': after != xml and after == changed}


def tamper():
    def flip(match):
        if KEYSET in match.group(2):
            return match.group(0)
        value = match.group(3)
        middle = len(value) // 2
        swapped = 'A' if value[middle] != 'A' else 'B'
        return match.group(1) + value[:middle] + swapped + value[middle + 1:] + match.group(4)

    return rewrite(lambda xml: ENTRY.sub(flip, xml))


def key_lost():
    return rewrite(lambda xml: ENTRY.sub(
        lambda m: '' if KEYSET in m.group(2) else m.group(0), xml))


def main():
    source, out = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
    out.mkdir(parents=True, exist_ok=True)
    markers = json.loads((source / 'markers.json').read_text())['markers']
    report, ok = {}, True
    try:
        for name, change in [('tamper', tamper), ('key-lost', key_lost)]:
            seed(source)
            result = {'change': change()}
            adb('logcat', '-b', 'all', '-c')
            result['start'] = ' '.join(adb('shell', 'am', 'start', '-W', '-n', ACTIVITY)
                                       .stdout.split())
            time.sleep(10)
            result['pid'] = adb('shell', 'pidof', PKG).stdout.strip()
            labels = [n['label'] for n in ui_nodes()]
            result['unreadableBanner'] = [l for l in labels if '无法解密' in l]
            result['hostsShown'] = [l for l in labels if 'sec05' in l]
            logcat = adb('logcat', '-b', 'all', '-d', text=False).stdout
            (out / f'{name}-logcat.txt').write_bytes(logcat)
            result['fatal'] = len(re.findall(rb'FATAL EXCEPTION|Fatal signal', logcat))
            adb('shell', 'am', 'force-stop', PKG)
            tar = adb('exec-out', 'run-as', PKG, 'tar', '-cf', '-', '.', text=False).stdout
            blobs = {'logcat': logcat}
            with tarfile.open(fileobj=io.BytesIO(tar)) as archive:
                for member in archive.getmembers():
                    if member.isfile() and 'flutter_assets/' not in member.name:
                        blobs[f'private:{member.name}'] = archive.extractfile(member).read()
            result['markerHits'] = sec05.search(blobs, markers)
            passed = (bool(result['pid']) and result['fatal'] == 0
                      and bool(result['unreadableBanner']) and not result['markerHits'])
            result['pass'] = passed
            ok = ok and passed
            report[name] = result
            print(name, json.dumps(result, ensure_ascii=False), flush=True)
    finally:
        adb('uninstall', PKG)
    (out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print('SEC06', 'PASS' if ok else 'FAIL')
    sys.exit(0 if ok else 1)


def ui_nodes():
    adb('shell', 'uiautomator', 'dump', '/sdcard/r28-ui.xml')
    xml = adb('exec-out', 'cat', '/sdcard/r28-ui.xml').stdout
    import xml.etree.ElementTree as ET
    return [{'label': (n.get('text') or '') + '|' + (n.get('content-desc') or '')}
            for n in ET.fromstring(xml).iter('node')]


if __name__ == '__main__':
    main()
