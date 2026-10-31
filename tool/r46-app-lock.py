#!/usr/bin/env python3
"""R46 on the disposable project AVD: the real system PIN prompt, home, recents, cold start.

How to run (emulator booted on port 5580, fixture up, see docs/dev/README.md):

  (cd tool/fixture-environment && ./up.sh)
  SHUN_R39_AVD=shun-r39-a30 python3 tool/r46-app-lock.py

It sets screen lock PIN 1234 and answers the markers of integration_test/r46_app_lock_test.dart.
flutter test uninstalls the app when it ends, so the cold start is a second part: build
integration_test/r46_cold_seed.dart, run it once to write a host and turn the lock on, install the
normal debug app over it (same data), then start it: lock first, host only after the PIN.
At the end it clears the app's data and the screen lock.
If you stop it midway: adb shell locksettings clear --old 1234
R46_COLD_ONLY=1 skips the first part.
Screenshots and the log go to ../.toolchain/artifacts/r46-<time>/. Exit code 0 means passed.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('r39_device', ROOT / 'tool/r39-device.py')
r39 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r39)

TARGET = 'integration_test/r46_app_lock_test.dart'
FIXTURE = ROOT / 'tool/fixture-environment/.run/fixture.json'
PIN = '1234'


def main():
    env = r39.environment()
    r39.check_device()
    r39.require(FIXTURE.is_file(), 'Start the fixture environment first (tool/fixture-environment/up.sh)')
    fixture = json.loads(FIXTURE.read_text())
    out = r39.CHAIN / 'artifacts' / time.strftime('r46-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    adb = str(r39.SDK / 'platform-tools/adb')
    edge_port = str(fixture['sshEdge']['port'])

    def adb_run(*args, check=True):
        return subprocess.run([adb, '-s', r39.SERIAL, *args], check=check, timeout=60,
                              capture_output=True, text=True)

    def shot(name):
        with (out / f'{name}.png').open('wb') as png:
            subprocess.run([adb, '-s', r39.SERIAL, 'exec-out', 'screencap', '-p'],
                           stdout=png, check=True, timeout=30)

    def open_app():
        adb_run('shell', 'am', 'start', '-a', 'android.intent.action.MAIN',
                '-c', 'android.intent.category.LAUNCHER',
                '-n', f'{r39.PKG}/top.xdwa.shun.MainActivity')

    def enter_pin():
        time.sleep(3)
        shot('pin-prompt')
        adb_run('shell', 'input', 'text', PIN)
        time.sleep(0.5)
        adb_run('shell', 'input', 'keyevent', '66')

    def handle(name):
        if name == 'pin':
            enter_pin()
        elif name == 'cancel':
            time.sleep(3)
            # 系统 PIN 框防截屏，还开着时 screencap 是 0 字节。键盘弹着时第一下返回只收键盘，再按才取消。
            # 不能闭着眼按两下：框已经关了的话，第二下会把 App 退到后台。
            for _ in range(3):
                adb_run('shell', 'input', 'keyevent', '4')
                time.sleep(2)
                shot('after-back')
                if (out / 'after-back.png').stat().st_size > 0:
                    break
        elif name == 'open-app':
            open_app()
        elif name == 'home-return':
            adb_run('shell', 'input', 'keyevent', '3')
            time.sleep(2)
            open_app()
        elif name == 'home-recents-return':
            adb_run('shell', 'input', 'keyevent', '3')
            time.sleep(2)
            adb_run('shell', 'input', 'keyevent', 'KEYCODE_APP_SWITCH')
            time.sleep(3)
            shot('recents')
            adb_run('shell', 'input', 'keyevent', '3')
            time.sleep(1)
            open_app()
        elif name.startswith('shot-'):
            time.sleep(1)
            shot(name[len('shot-'):])

    define = None
    code = 1
    try:
        adb_run('reverse', f'tcp:{edge_port}', f'tcp:{edge_port}')
        adb_run('shell', 'pm', 'clear', r39.PKG, check=False)
        adb_run('shell', 'locksettings', 'set-pin', PIN)
        handle_, define = tempfile.mkstemp(prefix='fixture-define-', suffix='.json')
        with os.fdopen(handle_, 'w') as f:
            json.dump({'SHUN_FIXTURE': json.dumps({
                'user': fixture['user'],
                'password': fixture['password'],
                'edgePort': fixture['sshEdge']['port'],
            })}, f)
        # R46_COLD_ONLY=1：跳过这段，只跑后面的冷启动和指纹。
        code = 0 if os.environ.get('R46_COLD_ONLY') else None
        with (out / 'flutter-test.log').open('w') as log:
            proc = None if code == 0 else subprocess.Popen(
                ['flutter', 'test', '--no-pub', TARGET, '-d', r39.SERIAL,
                 f'--dart-define-from-file={define}'],
                cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            for line in proc.stdout if proc else ():
                log.write(line)
                log.flush()
                print(line.rstrip(), flush=True)
                marker = line.strip()
                if marker.startswith('R46 ACTION='):
                    handle(marker[len('R46 ACTION='):])
            code = proc.wait() if proc else 0
        if code != 0:
            return code

        # 冷启动：先用种子包写数据，再覆盖安装真 App（install -r 不清数据）。
        apk = str(ROOT / 'build/app/outputs/flutter-apk/app-debug.apk')
        subprocess.run(['flutter', 'build', 'apk', '--debug', '--no-pub',
                        '-t', 'integration_test/r46_cold_seed.dart'],
                       cwd=ROOT, env=env, check=True, stdout=subprocess.DEVNULL)
        adb_run('install', '-r', apk)
        adb_run('logcat', '-c')
        open_app()
        deadline = time.time() + 60
        while 'R46 SEEDED' not in adb_run('logcat', '-d', '-s', 'flutter:I').stdout:
            r39.require(time.time() < deadline, 'seed did not finish in 60 s')
            time.sleep(1)
        subprocess.run(['flutter', 'build', 'apk', '--debug', '--no-pub'], cwd=ROOT, env=env,
                       check=True, stdout=subprocess.DEVNULL)
        adb_run('install', '-r', apk)
        adb_run('shell', 'am', 'force-stop', r39.PKG)
        time.sleep(1)

        def texts():
            adb_run('shell', 'uiautomator', 'dump', '/data/local/tmp/r46-ui.xml', check=False)
            raw = adb_run('shell', 'cat', '/data/local/tmp/r46-ui.xml', check=False).stdout
            try:
                return list(ET.fromstring(raw).iter('node'))
            except ET.ParseError:
                return []

        def has(word):
            return any(word in (n.get('text') or '') + (n.get('content-desc') or '') for n in texts())

        def tap_text(word):
            for node in texts():
                if word in (node.get('text') or '') + (node.get('content-desc') or ''):
                    x1, y1, x2, y2 = map(int, re.findall(r'\d+', node.get('bounds')))
                    adb_run('shell', 'input', 'tap', str((x1 + x2) // 2), str((y1 + y2) // 2))
                    return
            raise SystemExit(f'not on screen: {word}')

        def check(name, ok):
            print(f'R46 cold.{name}={ok}', flush=True)
            failed.extend([] if ok else [name])

        failed = []
        open_app()
        time.sleep(5)
        # 系统 PIN 页开着。取消之后停在锁屏页：有「解锁」，没有主机。
        handle('cancel')
        time.sleep(1)
        shot('cold-start-canceled')
        check('hasUnlock', has('解锁'))
        check('hidesHost', not has('R46-SENTINEL'))
        # 锁屏页按返回：回桌面。再打开还是要解锁。
        adb_run('shell', 'input', 'keyevent', '4')
        time.sleep(2)
        activities = adb_run('shell', 'dumpsys', 'activity', 'activities').stdout.splitlines()
        resumed = next((line for line in activities if 'mResumedActivity' in line), '')
        check('backLeavesApp', r39.PKG not in resumed)
        open_app()
        time.sleep(4)
        enter_pin()
        time.sleep(3)
        shot('cold-start-unlocked')
        # 这一条让上面的 hidesHost 不是空话：主机确实在，解锁才看得到。
        check('hostAfterUnlock', has('R46-SENTINEL'))
        # 设成了立即：退到桌面回来又要解锁，点解锁再输一次。
        adb_run('shell', 'input', 'keyevent', '3')
        time.sleep(2)
        open_app()
        time.sleep(4)
        handle('cancel')
        time.sleep(1)
        check('relockHidesHost', not has('R46-SENTINEL'))
        tap_text('解锁')
        enter_pin()
        time.sleep(3)
        check('hostAfterSecondUnlock', has('R46-SENTINEL'))

        # 指纹：真手机上最常走的路。模拟器能录、能按。录指纹放在这里：录了之后上面那些 PIN 的路走不到。
        def finger(number):
            adb_run('emu', 'finger', 'touch', str(number))
            time.sleep(1)
            adb_run('emu', 'finger', 'remove', str(number), check=False)
            time.sleep(1)

        def wait_text(word, seconds=30):
            deadline = time.time() + seconds
            while not has(word):
                r39.require(time.time() < deadline, f'not on screen after {seconds} s: {word}')
                time.sleep(1)

        adb_run('shell', 'am', 'start', '-a', 'android.settings.FINGERPRINT_ENROLL')
        enter_pin()
        wait_text('NEXT')
        tap_text('NEXT')
        wait_text('Touch the sensor')
        for _ in range(15):
            finger(1)
            if has('DONE'):
                break
        check('fingerEnrolled', has('DONE'))
        tap_text('DONE')
        time.sleep(1)
        open_app()
        time.sleep(4)
        shot('finger-prompt')
        check('fingerPromptOffersPin', has('Use PIN'))
        check('fingerPromptHidesHost', not has('R46-SENTINEL'))
        finger(2)
        check('wrongFingerStaysLocked', has('Use PIN') and not has('R46-SENTINEL'))
        finger(1)
        time.sleep(3)
        check('hostAfterFinger', has('R46-SENTINEL'))
        # 取消：停在锁屏页。再点解锁，这次转 PIN。
        adb_run('shell', 'input', 'keyevent', '3')
        time.sleep(2)
        open_app()
        time.sleep(4)
        adb_run('shell', 'input', 'keyevent', '4')
        time.sleep(2)
        check('fingerCancelStaysLocked', has('解锁') and not has('R46-SENTINEL'))
        tap_text('解锁')
        time.sleep(3)
        tap_text('Use PIN')
        enter_pin()
        time.sleep(3)
        check('hostAfterPinFallback', has('R46-SENTINEL'))
        # 指纹错太多次（系统按 5 次算）：要能转 PIN，不能把人挡在外面。
        adb_run('shell', 'input', 'keyevent', '3')
        time.sleep(2)
        open_app()
        time.sleep(4)
        for _ in range(5):
            finger(2)
        time.sleep(3)
        shot('finger-lockout')
        check('lockoutHidesHost', not has('R46-SENTINEL'))
        if has('Use PIN'):
            tap_text('Use PIN')
        elif has('解锁'):
            tap_text('解锁')
        enter_pin()
        time.sleep(3)
        check('hostAfterLockoutPin', has('R46-SENTINEL'))
        code = 1 if failed else 0
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
