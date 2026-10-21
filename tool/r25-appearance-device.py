#!/usr/bin/env python3
"""R25 appearance on the disposable project AVD: terminal colours in light and dark, font size, full-screen
programs, system font scale and landscape.

How to run (emulator already booted on port 5580 and the SSH fixture up, see docs/dev/README.md):

  (cd tool/fixture-environment && ./up.sh)
  SHUN_R39_AVD=shun-r39-a30 python3 tool/r25-appearance-device.py

It refuses any device that tool/r39-device.py would refuse (other AVD, physical phone), then:
  - adb reverse 22201 (ssh-edge) of the fixture environment;
  - clears the test app's data, passes the fixture login in a temporary --dart-define-from-file
    (never on the command line);
  - runs integration_test/r25_appearance_test.dart and answers its markers:
      R25 SHOT <name>        -> adb screencap <name>.png
      R25 FONT <scale> <n>   -> settings put system font_scale, then files/r25-ack-<n> in the app's dir
      R25 ROTATE <0|1> <n>   -> lock portrait / landscape, then the same ack
  - afterwards puts font_scale and rotation back to what they were before the run, removes the reverse
    and the define file and clears the test app's data (it holds a host and password for the fixture).
Evidence goes to ../.toolchain/artifacts/r25-appearance-<time>/ (flutter log, screenshots).
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

TARGET = 'integration_test/r25_appearance_test.dart'
FIXTURE = ROOT / 'tool/fixture-environment/.run/fixture.json'
# Only these values are ever written to the emulator's system settings.
FONT_SCALES = {'1.0', '1.3', '2.0'}
ROTATIONS = {'0', '1'}


def main():
    env = r39.environment()
    r39.check_device()
    r39.require(FIXTURE.is_file(), 'Start the fixture environment first (tool/fixture-environment/up.sh)')
    fixture = json.loads(FIXTURE.read_text())
    out = r39.CHAIN / 'artifacts' / time.strftime('r25-appearance-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    adb = str(r39.SDK / 'platform-tools/adb')
    edge_port = str(fixture['sshEdge']['port'])

    def adb_run(*args, check=True):
        return subprocess.run([adb, '-s', r39.SERIAL, *args], check=check, timeout=60,
                              capture_output=True, text=True)

    def setting(name):
        return adb_run('shell', 'settings', 'get', 'system', name).stdout.strip()

    # Put back exactly what was there: "null" means the key was never set, so delete it again.
    original = {name: setting(name)
                for name in ('font_scale', 'accelerometer_rotation', 'user_rotation')}
    (out / 'device.txt').write_text('\n'.join([
        f'avd={r39.AVD}',
        'wm size: ' + r39.shell('wm', 'size'),
        'sdk=' + r39.shell('getprop', 'ro.build.version.sdk'),
        'before: ' + json.dumps(original),
    ]) + '\n')
    define = None
    code = 1
    try:
        adb_run('reverse', f'tcp:{edge_port}', f'tcp:{edge_port}')
        adb_run('shell', 'pm', 'clear', r39.PKG, check=False)
        handle, define = tempfile.mkstemp(prefix='r25-define-', suffix='.json')
        with os.fdopen(handle, 'w') as f:
            json.dump({'R25_SSH': json.dumps({
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
            if len(marker) < 2 or marker[0] != 'R25':
                continue
            print(line.rstrip(), flush=True)
            if marker[1] == 'SHOT' and len(marker) == 3:
                with (out / f'{marker[2]}.png').open('wb') as png:
                    subprocess.run([adb, '-s', r39.SERIAL, 'exec-out', 'screencap', '-p'],
                                   stdout=png, check=True, timeout=30)
            elif marker[1] == 'FONT' and len(marker) == 4 and marker[2] in FONT_SCALES:
                adb_run('shell', 'settings', 'put', 'system', 'font_scale', marker[2])
                adb_run('shell', 'run-as', r39.PKG, 'touch', f'files/r25-ack-{marker[3]}')
            elif marker[1] == 'ROTATE' and len(marker) == 4 and marker[2] in ROTATIONS:
                adb_run('shell', 'settings', 'put', 'system', 'accelerometer_rotation', '0')
                adb_run('shell', 'settings', 'put', 'system', 'user_rotation', marker[2])
                adb_run('shell', 'run-as', r39.PKG, 'touch', f'files/r25-ack-{marker[3]}')
        code = proc.wait()
        log.close()
    finally:
        if define:
            os.unlink(define)
        for name, value in original.items():
            if value == 'null':
                adb_run('shell', 'settings', 'delete', 'system', name, check=False)
            else:
                adb_run('shell', 'settings', 'put', 'system', name, value, check=False)
        after = {name: setting(name) for name in original}
        with (out / 'device.txt').open('a') as f:
            f.write('after: ' + json.dumps(after) + '\n')
        adb_run('reverse', '--remove', f'tcp:{edge_port}', check=False)
        adb_run('shell', 'pm', 'clear', r39.PKG, check=False)
    print(f'flutter test exit={code}; evidence in {out}', flush=True)
    return code


if __name__ == '__main__':
    sys.exit(main())
