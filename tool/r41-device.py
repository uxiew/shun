#!/usr/bin/env python3
"""R41 / UX07 on the disposable project AVD: real soft keyboard, real touch, real back key.

How to run (emulator already booted on port 5580, see docs/dev/r39-device-acceptance.md):

  SHUN_R39_AVD=shun-r39-a30 python3 tool/r41-device.py

It refuses any device that tool/r39-device.py would refuse (other AVD, physical phone),
then runs integration_test/r41_host_editor_keyboard_test.dart and answers its markers:
  R41 SHOT <name> -> adb screencap <name>.png
  R41 TAP <x> <y> -> adb shell input tap x y (physical pixels)
  R41 BACK        -> adb shell input keyevent BACK
The tap is the point: if the keyboard covered the save button, the touch would land on the
keyboard and the test would time out waiting for the editor to close.
Evidence goes to ../.toolchain/artifacts/r41-device-<time>/ (log + screenshots).
"""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('r39_device', ROOT / 'tool/r39-device.py')
r39 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r39)

TARGET = 'integration_test/r41_host_editor_keyboard_test.dart'


def main():
    env = r39.environment()
    r39.check_device()
    out = r39.CHAIN / 'artifacts' / time.strftime('r41-device-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    adb = str(r39.SDK / 'platform-tools/adb')
    (out / 'device.txt').write_text('\n'.join([
        f'avd={r39.AVD}',
        'wm size: ' + r39.shell('wm', 'size'),
        'wm density: ' + r39.shell('wm', 'density'),
        'sdk=' + r39.shell('getprop', 'ro.build.version.sdk'),
        'ime=' + r39.shell('settings', 'get', 'secure', 'default_input_method'),
    ]) + '\n')
    log = (out / 'flutter-test.log').open('w')
    proc = subprocess.Popen(
        ['flutter', 'test', '--no-pub', TARGET, '-d', r39.SERIAL],
        cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in proc.stdout:
        log.write(line)
        log.flush()
        marker = line.strip().split()
        if len(marker) < 2 or marker[0] != 'R41':
            continue
        print(line.rstrip(), flush=True)
        if marker[1] == 'SHOT' and len(marker) == 3:
            with (out / f'{marker[2]}.png').open('wb') as png:
                subprocess.run([adb, '-s', r39.SERIAL, 'exec-out', 'screencap', '-p'],
                               stdout=png, check=True, timeout=30)
        elif marker[1] == 'TAP' and len(marker) == 4:
            subprocess.run([adb, '-s', r39.SERIAL, 'shell', 'input', 'tap',
                            str(int(marker[2])), str(int(marker[3]))], check=True, timeout=30)
        elif marker[1] == 'BACK':
            subprocess.run([adb, '-s', r39.SERIAL, 'shell', 'input', 'keyevent', 'BACK'],
                           check=True, timeout=30)
    code = proc.wait()
    log.close()
    print(f'flutter test exit={code}; evidence in {out}', flush=True)
    return code


if __name__ == '__main__':
    sys.exit(main())
