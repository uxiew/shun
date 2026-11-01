#!/usr/bin/env python3
"""MON01 on the disposable project AVD: real pages, real touch events, real SSH (fixture ssh-edge).

How to run (emulator booted on port 5580, fixture up, see docs/dev/README.md):

  (cd tool/fixture-environment && ./up.sh)
  SHUN_R39_AVD=shun-r39-a30 python3 tool/r68-device.py

It refuses any device tool/r39-device.py would refuse (other AVD, physical phone), reverses ssh-edge's
port, passes the fixture login in a temporary --dart-define-from-file (never on the command line),
runs integration_test/r68_panel_ssh_test.dart and answers its markers:
  R68 SHOT <name>               -> adb screencap <name>.png
  R68 SWIPE <x0> <y0> <x1> <y1> -> adb shell input swipe
  R68 TAP <x> <y>               -> adb shell input tap
  R68 BACK                      -> adb shell input keyevent BACK
  R68 DROP                      -> docker compose restart ssh-edge (keeps host key and accounts)
Afterwards it clears the test app's data: it holds hosts and passwords pointing at the fixture.
Evidence goes to ../.toolchain/artifacts/r68-device-<time>/ (flutter log, screenshots).
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

TARGET = 'integration_test/r68_panel_ssh_test.dart'
FIXTURE = ROOT / 'tool/fixture-environment/.run/fixture.json'
COMPOSE = ROOT / 'tool/fixture-environment/compose.yaml'


def main():
    env = r39.environment()
    r39.check_device()
    r39.require(FIXTURE.is_file(), 'Start the fixture environment first (tool/fixture-environment/up.sh)')
    fixture = json.loads(FIXTURE.read_text())
    out = r39.CHAIN / 'artifacts' / time.strftime('r68-device-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    adb = str(r39.SDK / 'platform-tools/adb')
    edge_port = str(fixture['sshEdge']['port'])

    def adb_run(*args, check=True):
        return subprocess.run([adb, '-s', r39.SERIAL, *args], check=check, timeout=60,
                              capture_output=True, text=True)

    define = None
    code = 1
    try:
        adb_run('reverse', f'tcp:{edge_port}', f'tcp:{edge_port}')
        adb_run('shell', 'pm', 'clear', r39.PKG, check=False)
        handle, define = tempfile.mkstemp(prefix='fixture-define-', suffix='.json')
        with os.fdopen(handle, 'w') as f:
            json.dump({'SHUN_FIXTURE': json.dumps({
                'user': fixture['user'],
                'password': fixture['password'],
                'edgePort': fixture['sshEdge']['port'],
                'edgeFingerprint': fixture['sshEdge']['fingerprintSha256'],
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
            if len(marker) < 2 or marker[0] != 'R68':
                continue
            print(line.rstrip(), flush=True)
            if marker[1] == 'SHOT' and len(marker) == 3:
                with (out / f'{marker[2]}.png').open('wb') as png:
                    subprocess.run([adb, '-s', r39.SERIAL, 'exec-out', 'screencap', '-p'],
                                   stdout=png, check=True, timeout=30)
            elif marker[1] == 'SWIPE' and len(marker) == 6:
                adb_run('shell', 'input', 'swipe', *marker[2:], '350')
            elif marker[1] == 'TAP' and len(marker) == 4:
                adb_run('shell', 'input', 'tap', *marker[2:])
            elif marker[1] == 'BACK':
                adb_run('shell', 'input', 'keyevent', 'BACK')
            elif marker[1] == 'DROP':
                subprocess.run(['docker', 'compose', '-f', str(COMPOSE), 'restart', 'ssh-edge'],
                               env=env, check=True, timeout=60, capture_output=True)
        code = proc.wait()
        log.close()
    finally:
        if define:
            os.unlink(define)
        adb_run('reverse', '--remove', f'tcp:{edge_port}', check=False)
        adb_run('shell', 'pm', 'clear', r39.PKG, check=False)
    print(f'flutter test exit={code}; evidence in {out}', flush=True)
    return code


if __name__ == '__main__':
    sys.exit(main())
