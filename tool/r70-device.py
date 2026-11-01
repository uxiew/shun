#!/usr/bin/env python3
"""F31–F35 walkthrough on the disposable project AVD: real pages, real touch events, no network.

How to run (emulator already booted on port 5580, see docs/dev/README.md):

  SHUN_R39_AVD=shun-r39-a30 python3 tool/r70-device.py

It refuses any device that tool/r39-device.py would refuse (other AVD, physical phone), then runs
integration_test/r70_walkthrough_test.dart and answers its markers:
  R70 SHOT <name>            -> adb screencap <name>.png
  R70 SWIPE <x0> <y0> <x1> <y1> -> adb shell input swipe (a real touch event, not a synthetic one)
  R70 TAP <x> <y>            -> adb shell input tap
  R70 BACK                   -> adb shell input keyevent BACK
  R70 FRONT                  -> am start the app's activity (leaves picture in picture)
Afterwards it clears the test app's data. Sessions in that test are seeded, so this proves the UI,
the gesture and the layout with Chinese fonts, not logging in.
Evidence goes to ../.toolchain/artifacts/r70-device-<time>/ (flutter log, screenshots).
"""
import importlib.util
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('r39_device', ROOT / 'tool/r39-device.py')
r39 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r39)

TARGET = 'integration_test/r70_walkthrough_test.dart'


def main():
    env = r39.environment()
    r39.check_device()
    out = r39.CHAIN / 'artifacts' / time.strftime('r70-device-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    adb = str(r39.SDK / 'platform-tools/adb')

    def adb_run(*args, check=True):
        return subprocess.run([adb, '-s', r39.SERIAL, *args], check=check, timeout=60,
                              capture_output=True, text=True)

    (out / 'device.txt').write_text('\n'.join([
        f'avd={r39.AVD}',
        'wm size: ' + r39.shell('wm', 'size'),
        'sdk=' + r39.shell('getprop', 'ro.build.version.sdk'),
    ]) + '\n')
    adb_run('shell', 'pm', 'clear', r39.PKG, check=False)
    code = 1
    try:
        log = (out / 'flutter-test.log').open('w')
        proc = subprocess.Popen(
            ['flutter', 'test', '--no-pub', TARGET, '-d', r39.SERIAL],
            cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in proc.stdout:
            log.write(line)
            log.flush()
            marker = line.strip().split()
            if len(marker) < 2 or marker[0] != 'R70':
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
            elif marker[1] == 'FRONT':
                adb_run('shell', 'am', 'start', '-n', f'{r39.PKG}/top.xdwa.shun.MainActivity')
        code = proc.wait()
        log.close()
    finally:
        adb_run('shell', 'pm', 'clear', r39.PKG, check=False)
    print(f'flutter test exit={code}; evidence in {out}', flush=True)
    return code


if __name__ == '__main__':
    sys.exit(main())
