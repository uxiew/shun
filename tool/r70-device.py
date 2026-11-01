#!/usr/bin/env python3
"""F31–F37 walkthrough on the disposable project AVD: real pages, real touch events, no network.

How to run (emulator already booted on port 5580, see docs/dev/README.md):

  SHUN_R39_AVD=shun-r39-a30 python3 tool/r70-device.py

It refuses any device that tool/r39-device.py would refuse (other AVD, physical phone), then runs
integration_test/r70_walkthrough_test.dart and answers its markers:
  R70 SHOT <name>            -> adb screencap <name>.png
  R70 SWIPE <x0> <y0> <x1> <y1> -> adb shell input swipe (a real touch event, not a synthetic one)
  R70 TAP <x> <y>            -> adb shell input tap
  R70 TWO <x0> <y0> <x1> <y1> <dy> -> two real fingers through the emulator console (adb input is single touch)
  R70 ONE <x> <y> <dy>       -> one finger the same way; adb input reports its pointer kind as unknown, not touch
  R70 BACK                   -> adb shell input keyevent BACK
  R70 FRONT                  -> am start the app's activity (leaves picture in picture)
Afterwards it clears the test app's data. Sessions in that test are seeded, so this proves the UI,
the gesture and the layout with Chinese fonts, not logging in.
Evidence goes to ../.toolchain/artifacts/r70-device-<time>/ (flutter log, screenshots).
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

# 只想看某一段时换目标，比如 integration_test/r73_editor_walkthrough_test.dart。
TARGET = os.environ.get('SHUN_R70_TARGET', 'integration_test/r70_walkthrough_test.dart')


def fingers(adb, starts, dy, size):
    """Multi-touch protocol B through `adb emu event send`: reaches /dev/input like a real finger,
    and needs no root (sendevent is blocked by sepolicy on these images)."""
    width, height = size

    def send(*events):
        subprocess.run([adb, '-s', r39.SERIAL, 'emu', 'event', 'send', *events, 'EV_SYN:0:0'],
                       check=True, timeout=10, capture_output=True)

    def slot(index, x, y, tracking=None):
        return [f'EV_ABS:ABS_MT_SLOT:{index}',
                # Without a tool type Flutter reports the pointer kind as unknown, not touch.
                *([f'EV_ABS:ABS_MT_TRACKING_ID:{tracking}', 'EV_ABS:ABS_MT_TOOL_TYPE:0']
                  if tracking is not None else []),
                f'EV_ABS:ABS_MT_POSITION_X:{x * 32767 // width}',
                f'EV_ABS:ABS_MT_POSITION_Y:{y * 32767 // height}',
                # Without pressure Android treats the finger as hovering and the app sees no touch at all.
                'EV_ABS:ABS_MT_PRESSURE:512']

    def all_at(moved, tracking=False):
        return [event for index, (x, y) in enumerate(starts)
                for event in slot(index, x, y + moved, 101 + index if tracking else None)]

    send(*all_at(0, tracking=True))
    steps = 12
    for step in range(1, steps + 1):
        send(*all_at(dy * step // steps))
    send(*[event for index in range(len(starts))
           for event in (f'EV_ABS:ABS_MT_SLOT:{index}', 'EV_ABS:ABS_MT_TRACKING_ID:-1')])


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
            elif marker[1] == 'TWO' and len(marker) == 7:
                x0, y0, x1, y1, dy = map(int, marker[2:])
                size = r39.shell('wm', 'size').split()[-1].split('x')
                fingers(adb, [(x0, y0), (x1, y1)], dy, (int(size[0]), int(size[1])))
            elif marker[1] == 'ONE' and len(marker) == 5:
                x, y, dy = map(int, marker[2:])
                size = r39.shell('wm', 'size').split()[-1].split('x')
                fingers(adb, [(x, y)], dy, (int(size[0]), int(size[1])))
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
