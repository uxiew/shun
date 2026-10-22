#!/usr/bin/env python3
"""R25 / UX04 on the disposable project AVD: common failures -> hint, real route, connection log;
host details, terminal engine and the supported-types list.

How to run (emulator already booted on port 5580 and the SSH fixture up, see docs/dev/README.md):

  (cd tool/fixture-environment && ./up.sh)
  SHUN_R39_AVD=shun-r39-a30 python3 tool/r25-ux04-device.py

It refuses any device that tool/r39-device.py would refuse (other AVD, physical phone), then:
  - adb reverse 22201 (ssh-edge) and 21080 (dante with auth) of the fixture environment;
  - clears the test app's data, passes the fixture logins in a temporary --dart-define-from-file
    (never on the command line);
  - runs integration_test/r25_ux04_test.dart and answers its "UX04 SHOT <name>" markers with
    adb screencap <name>.png;
  - afterwards removes the reverses and the define file and clears the test app's data
    (it holds hosts and passwords pointing at the fixture).
Evidence goes to ../.toolchain/artifacts/r25-ux04-<time>/ (flutter log, screenshots).
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

TARGET = 'integration_test/r25_ux04_test.dart'
FIXTURE = ROOT / 'tool/fixture-environment/.run/fixture.json'


def main():
    env = r39.environment()
    r39.check_device()
    r39.require(FIXTURE.is_file(), 'Start the fixture environment first (tool/fixture-environment/up.sh)')
    fixture = json.loads(FIXTURE.read_text())
    out = r39.CHAIN / 'artifacts' / time.strftime('r25-ux04-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    adb = str(r39.SDK / 'platform-tools/adb')
    edge_port = str(fixture['sshEdge']['port'])
    socks_port = str(fixture['socksAuth']['port'])

    def adb_run(*args, check=True):
        return subprocess.run([adb, '-s', r39.SERIAL, *args], check=check, timeout=60,
                              capture_output=True, text=True)

    packages = adb_run('shell', 'pm', 'list', 'packages', check=False).stdout
    (out / 'device.txt').write_text('\n'.join([
        f'avd={r39.AVD}',
        'wm size: ' + r39.shell('wm', 'size'),
        'sdk=' + r39.shell('getprop', 'ro.build.version.sdk'),
        # The supported-types list depends on what is installed: record it next to the screenshot.
        'mosh plugin installed=' + str('top.xdwa.shun.mosh' in packages),
        'rustdesk installed=' + str('com.carriez.flutter_hbb' in packages),
        'uu installed=' + str('com.netease.uuremote' in packages),
    ]) + '\n')
    define = None
    code = 1
    try:
        adb_run('reverse', f'tcp:{edge_port}', f'tcp:{edge_port}')
        adb_run('reverse', f'tcp:{socks_port}', f'tcp:{socks_port}')
        adb_run('shell', 'pm', 'clear', r39.PKG, check=False)
        handle, define = tempfile.mkstemp(prefix='ux04-define-', suffix='.json')
        with os.fdopen(handle, 'w') as f:
            json.dump({'UX04_SSH': json.dumps({
                'user': fixture['user'],
                'password': fixture['password'],
                'edgePort': fixture['sshEdge']['port'],
                'edgeFingerprint': fixture['sshEdge']['fingerprintSha256'],
                'targetName': fixture['target']['name'],
                'targetPort': fixture['target']['port'],
                'targetFingerprint': fixture['target']['fingerprintSha256'],
                'socksPort': fixture['socksAuth']['port'],
                'socksUser': fixture['socksAuth']['username'],
                'socksPassword': fixture['socksAuth']['password'],
            })}, f)
        log = (out / 'flutter-test.log').open('w')
        proc = subprocess.Popen(
            ['flutter', 'test', '--no-pub', TARGET, '-d', r39.SERIAL,
             f'--dart-define-from-file={define}'],
            cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in proc.stdout:
            log.write(line)
            log.flush()
            marker = line.strip().split()
            if len(marker) < 2 or marker[0] != 'UX04':
                continue
            print(line.rstrip(), flush=True)
            if marker[1] == 'SHOT' and len(marker) == 3:
                with (out / f'{marker[2]}.png').open('wb') as png:
                    subprocess.run([adb, '-s', r39.SERIAL, 'exec-out', 'screencap', '-p'],
                                   stdout=png, check=True, timeout=30)
        code = proc.wait()
        log.close()
    finally:
        if define:
            os.unlink(define)
        adb_run('reverse', '--remove', f'tcp:{edge_port}', check=False)
        adb_run('reverse', '--remove', f'tcp:{socks_port}', check=False)
        adb_run('shell', 'pm', 'clear', r39.PKG, check=False)
    print(f'flutter test exit={code}; evidence in {out}', flush=True)
    return code


if __name__ == '__main__':
    sys.exit(main())
