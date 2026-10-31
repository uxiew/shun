#!/usr/bin/env python3
"""release 包里 R8 有没有裁坏原生功能：扫码页、互传页、应用锁。只在模拟器上跑。

    flutter build apk --release --target-platform android-arm64
    python3 tool/release-features.py emulator-5580

会卸掉模拟器上的 top.xdwa.shun、给模拟器设 PIN 1234，结束时都清掉。真机上直接拒跑：那会清所有者的数据。

release 包没有测试框架，这里用 uiautomator 读界面、adb 点按，和 tool/release-smoke.sh 一样。
裁坏了会怎样：扫码页报 ActivityNotFoundException 或 ClassNotFoundException（这里输出在 crashes 里），
通道名对不上报 MissingPluginException（界面上是「打不开扫码页」）。
"""
import re
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from pathlib import Path

PKG = 'top.xdwa.shun'
ACTIVITY = f'{PKG}/top.xdwa.shun.MainActivity'
PIN = '1234'
UI_DUMP = '/data/local/tmp/shun-release-ui.xml'

serial = sys.argv[1] if len(sys.argv) > 1 else 'emulator-5580'
apk = sys.argv[2] if len(sys.argv) > 2 else 'build/app/outputs/flutter-apk/app-release.apk'
work = Path(tempfile.mkdtemp(prefix='release-features'))
results = {}


def adb(*args, check=False):
    return subprocess.run(
        ['adb', '-s', serial, *args],
        capture_output=True,
        text=True,
        check=check,
    ).stdout


def report(name, value):
    results[name] = value
    print(f'{name}={value}', flush=True)


def nodes():
    adb('shell', 'uiautomator', 'dump', UI_DUMP)
    adb('pull', UI_DUMP, str(work / 'ui.xml'))
    try:
        return list(ET.parse(work / 'ui.xml').getroot().iter('node'))
    except ET.ParseError:
        return []


def center(node):
    x1, y1, x2, y2 = map(int, re.findall(r'\d+', node.get('bounds')))
    return (x1 + x2) // 2, (y1 + y2) // 2


def find(text):
    for node in nodes():
        if text in (node.get('text') or '') + '\n' + (node.get('content-desc') or ''):
            return node
    return None


def wait(text, seconds=30):
    deadline = time.time() + seconds
    while time.time() < deadline:
        node = find(text)
        if node is not None:
            return node
        time.sleep(1)
    raise SystemExit(f'等不到「{text}」')


def tap(node):
    x, y = center(node)
    adb('shell', 'input', 'tap', str(x), str(y))


def scroll_to(text):
    for _ in range(14):
        node = find(text)
        if node is not None:
            return node
        adb('shell', 'input', 'swipe', '500', '1600', '500', '800', '300')
        time.sleep(0.6)
    raise SystemExit(f'翻不到「{text}」')


def back():
    adb('shell', 'input', 'keyevent', '4')


def resumed():
    match = re.search(r'mResumedActivity: .*? (\S+/\S+)', adb('shell', 'dumpsys', 'activity', 'activities'))
    return match.group(1) if match else ''


def wait_app(seconds=15):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if resumed().startswith(PKG + '/') and 'MainActivity' in resumed():
            return True
        time.sleep(0.5)
    return False


def enter_pin():
    time.sleep(3)
    adb('shell', 'input', 'text', PIN)
    time.sleep(0.5)
    adb('shell', 'input', 'keyevent', '66')


def check_send_page():
    tap(scroll_to('发到另一台手机'))
    node = wait('等对方扫码')
    report('sendPageWaiting', node is not None)
    back()
    time.sleep(1.5)


def check_scan_page():
    adb('shell', 'pm', 'grant', PKG, 'android.permission.CAMERA')
    tap(scroll_to('从另一台手机接收'))
    deadline = time.time() + 20
    while time.time() < deadline and 'CaptureActivity' not in resumed():
        time.sleep(0.5)
    report('scanPageOpened', 'CaptureActivity' in resumed())
    time.sleep(2)
    # 无窗口模拟器没有相机：zxing 弹我们盖过的中文提示。有相机就没这个框。
    ok = find('知道了')
    print(f'scanNoCameraDialog={ok is not None}', flush=True)
    if ok is not None:
        tap(ok)
    else:
        back()
    report('scanReturnsToApp', wait_app())
    time.sleep(1.5)
    # 没扫到码退出来，接收页自己关掉，回到设置页。
    report('scanBackOnSettings', find('发到另一台手机') is not None)


def lock_switch():
    for node in nodes():
        if node.get('checkable') == 'true':
            return node
    return None


def check_app_lock():
    adb('shell', 'locksettings', 'set-pin', PIN)
    time.sleep(1)
    tap(scroll_to('应用锁'))
    time.sleep(1.5)
    switch = lock_switch()
    report('lockOffAtFirst', switch is not None and switch.get('checked') == 'false')
    tap(switch)
    enter_pin()
    report('lockEnableReturnsToApp', wait_app())
    time.sleep(1.5)
    switch = lock_switch()
    report('lockOn', switch is not None and switch.get('checked') == 'true')

    # 默认离开 60 秒才锁。
    adb('shell', 'input', 'keyevent', '3')
    time.sleep(65)
    adb('shell', 'am', 'start', '-n', ACTIVITY)
    time.sleep(2)
    # 回来自己弹系统验证；没弹就是停在解锁页，点按钮。
    if 'MainActivity' in resumed():
        tap(wait('解锁'))
    enter_pin()
    report('unlockReturnsToApp', wait_app())
    time.sleep(1.5)
    report('unlocked', find('解锁') is None and find('应用锁') is not None)


def main():
    if not adb('emu', 'avd', 'name').strip():
        raise SystemExit(f'{serial} 不是模拟器：这个脚本会卸 App、设 PIN，不在真机上跑')
    adb('uninstall', PKG)
    adb('install', apk, check=True)
    adb('logcat', '-c')
    adb('shell', 'am', 'start', '-W', '-n', ACTIVITY)
    try:
        tap(wait('设置'))
        time.sleep(1)
        check_send_page()
        check_scan_page()
        check_app_lock()
    finally:
        log = adb('logcat', '-d')
        crashes = re.findall(
            r'.*(?:FATAL EXCEPTION|ClassNotFoundException|NoClassDefFoundError|NoSuchMethodError|'
            r'MissingPluginException|ActivityNotFoundException).*',
            log,
        )
        report('crashes', len(crashes))
        for line in crashes[:8]:
            print(line[:200])
        adb('uninstall', PKG)
        adb('shell', 'rm', '-f', UI_DUMP)
        adb('shell', 'locksettings', 'clear', '--old', PIN)
    failed = [
        name
        for name, value in results.items()
        if value is False or (name == 'crashes' and value)
    ]
    print('FAIL ' + ','.join(failed) if failed else 'OK')
    sys.exit(1 if failed else 0)


main()
