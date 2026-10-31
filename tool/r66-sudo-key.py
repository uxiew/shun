#!/usr/bin/env python3
"""SEC15 on the disposable project AVD: the sudo key against a real shell, through a real jump host.

How to run (emulator booted on port 5580, fixture up, see docs/dev/README.md):

  (cd tool/fixture-environment && ./up.sh)
  SHUN_R39_AVD=shun-r39-a30 python3 tool/r66-sudo-key.py

It sets screen lock PIN 1234 and answers the markers of integration_test/r66_sudo_key_test.dart.
At the end it searches logcat for the passwords and clears the screen lock.
If you stop it midway: adb shell locksettings clear --old 1234
The log goes to ../.toolchain/artifacts/r66-<time>/. Exit code 0 means passed.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('r39_device', ROOT / 'tool/r39-device.py')
r39 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r39)

TARGET = 'integration_test/r66_sudo_key_test.dart'
FIXTURE = ROOT / 'tool/fixture-environment/.run/fixture.json'
PIN = '1234'
# integration_test/r66_sudo_key_test.dart 写进保险库的记号。
SECRETS = ['E p"w$1', 'T p"w$2']


def main():
    env = r39.environment()
    r39.check_device()
    r39.require(FIXTURE.is_file(), 'Start the fixture environment first (tool/fixture-environment/up.sh)')
    fixture = json.loads(FIXTURE.read_text())
    out = r39.CHAIN / 'artifacts' / time.strftime('r66-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    adb = str(r39.SDK / 'platform-tools/adb')
    edge_port = str(fixture['sshEdge']['port'])

    def adb_run(*args, check=True):
        return subprocess.run([adb, '-s', r39.SERIAL, *args], check=check, timeout=60,
                              capture_output=True, text=True)

    def screen_text():
        adb_run('shell', 'uiautomator', 'dump', '/data/local/tmp/r66-ui.xml', check=False)
        return adb_run('shell', 'cat', '/data/local/tmp/r66-ui.xml', check=False).stdout

    def handle(name):
        time.sleep(3)
        if name == 'pin':
            adb_run('shell', 'input', 'text', PIN)
            time.sleep(0.5)
            adb_run('shell', 'input', 'keyevent', '66')
        elif name == 'cancel':
            # 系统验证页防截屏，文字用 uiautomator 看。按错的后果要写在框上。
            text = screen_text()
            print(f"R66 promptWarns={'密码会明文显示' in text}", flush=True)
            print(f"R66 promptNamesHost={'R66-TARGET' in text}", flush=True)
            # 键盘弹着时第一下返回只收键盘。
            adb_run('shell', 'input', 'keyevent', '4')
            time.sleep(1)
            adb_run('shell', 'input', 'keyevent', '4')

    define = None
    code = 1
    try:
        adb_run('reverse', f'tcp:{edge_port}', f'tcp:{edge_port}')
        adb_run('shell', 'pm', 'clear', r39.PKG, check=False)
        adb_run('shell', 'locksettings', 'set-pin', PIN)
        adb_run('logcat', '-c')
        handle_, define = tempfile.mkstemp(prefix='fixture-define-', suffix='.json')
        with os.fdopen(handle_, 'w') as f:
            json.dump({'SHUN_FIXTURE': json.dumps({
                'user': fixture['user'],
                'password': fixture['password'],
                'edgePort': fixture['sshEdge']['port'],
                'targetName': fixture['target']['name'],
                'targetPort': fixture['target']['port'],
            })}, f)
        with (out / 'flutter-test.log').open('w') as log:
            proc = subprocess.Popen(
                ['flutter', 'test', '--no-pub', TARGET, '-d', r39.SERIAL,
                 f'--dart-define-from-file={define}'],
                cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            for line in proc.stdout:
                log.write(line)
                log.flush()
                print(line.rstrip(), flush=True)
                marker = line.strip()
                if marker.startswith('R66 ACTION='):
                    handle(marker[len('R66 ACTION='):])
            code = proc.wait()
        logcat = adb_run('logcat', '-d').stdout
        leaked = [s for s in [*SECRETS, fixture['password']] if s in logcat]
        print(f'R66 logcatLeaks={len(leaked)}', flush=True)
        if leaked:
            code = 1
    finally:
        if define:
            os.unlink(define)
        adb_run('reverse', '--remove', f'tcp:{edge_port}', check=False)
        adb_run('shell', 'pm', 'clear', r39.PKG, check=False)
        adb_run('shell', 'locksettings', 'clear', '--old', PIN, check=False)
    print(f'exit={code}; evidence in {out}', flush=True)
    return code


if __name__ == '__main__':
    sys.exit(main())
