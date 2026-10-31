#!/usr/bin/env python3
"""SYN01（R60）的设备部分：加密备份存进系统文件选择器再选回来，短文件覆盖长文件。

    source ../.toolchain/env.sh
    python3 tool/r60-backup.py emulator-5580

跑 integration_test/r60_backup_saf_test.dart，测试打 `R60 ACTION=...`，这里用 uiautomator 点系统界面。
用 profile 构建（AOT）：口令派生的耗时才和发布版一致。包名 top.xdwa.shun.profile，跑完卸掉。
只在模拟器上跑：会在 Download 目录写文件并删掉。退出码 0 表示测试过了。
"""
import re
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET

SERIAL = sys.argv[1]
if not SERIAL.startswith('emulator-'):
    sys.exit('只在模拟器上跑：会写并删 Download 目录的文件')
NAME = 'shun-backup-encrypted'
SAVE = {'SAVE', 'Save', '保存'}
OK = {'OK', '确定'}


def adb(*args, check=False):
    return subprocess.run(['adb', '-s', SERIAL, *args], capture_output=True, text=True, check=check).stdout


def nodes():
    adb('shell', 'uiautomator', 'dump', '/data/local/tmp/r60-ui.xml')
    raw = adb('shell', 'cat', '/data/local/tmp/r60-ui.xml')
    try:
        return list(ET.fromstring(raw).iter('node'))
    except ET.ParseError:
        return []


def tap(node):
    x1, y1, x2, y2 = map(int, re.findall(r'\d+', node.get('bounds')))
    adb('shell', 'input', 'tap', str((x1 + x2) // 2), str((y1 + y2) // 2))


def choose_first_file():
    """用键盘选列表第一项：文件选择器的列表不理 input tap 和 swipe（按钮理），键盘可以。"""
    for _ in range(8):
        if any(n.get('focused') == 'true' and (n.get('resource-id') or '').endswith('item_root') for n in nodes()):
            adb('shell', 'input', 'keyevent', 'KEYCODE_ENTER')
            return
        adb('shell', 'input', 'keyevent', 'KEYCODE_TAB')
        time.sleep(0.5)
    raise SystemExit('键盘选不到文件')


def wait_for(match, what, seconds=60):
    end = time.time() + seconds
    while time.time() < end:
        found = [n for n in nodes() if match(n)]
        if found:
            return found[0]
        time.sleep(0.5)
    texts = sorted({n.get('text') for n in nodes() if n.get('text')})
    raise SystemExit(f'等不到 {what}，屏幕上有：{texts}')


def is_button(labels):
    return lambda n: (n.get('text') or '') in labels and n.get('clickable') == 'true'


def is_listed_file(n):
    # 保存页的文件名输入框里也是这个名字，点它不算选中文件。
    return (n.get('text') or '').startswith(NAME) and 'EditText' not in n.get('class', '')


def act(action):
    print('动作', action, flush=True)
    # 上一个选择器关掉要一会儿，太早看到的是它的界面。
    time.sleep(3)
    if action == 'save-new':
        tap(wait_for(is_button(SAVE), '保存按钮'))
    elif action == 'pick':
        wait_for(is_listed_file, '备份文件')
        choose_first_file()
    elif action == 'save-overwrite':
        wait_for(is_listed_file, '列表里的备份文件')
        choose_first_file()
        time.sleep(1)
        tap(wait_for(is_button(SAVE), '保存按钮'))
        tap(wait_for(is_button(OK), '覆盖确认'))
    else:
        raise SystemExit(f'不认识的动作 {action}')


def cleanup():
    adb('root')
    adb('wait-for-device')
    # 只 rm 的话媒体库里还留着条目，选择器会列出一堆打不开的旧文件。
    adb('shell', 'content', 'delete', '--uri', 'content://media/external/file',
        '--where', f"_display_name\\ LIKE\\ \\'{NAME}%\\'")
    adb('shell', f'rm -f /sdcard/Download/{NAME}*')
    adb('uninstall', 'top.xdwa.shun.profile')
    adb('shell', 'rm -f /data/local/tmp/r60-ui.xml')


def main():
    cleanup()
    log = tempfile.NamedTemporaryFile('w+', suffix='-r60.log', delete=False)
    print('日志', log.name, flush=True)
    drive = subprocess.Popen(
        ['flutter', 'drive', '--profile', '-d', SERIAL,
         '--driver', 'test_driver/integration_test.dart',
         '--target', 'integration_test/r60_backup_saf_test.dart'],
        stdout=log, stderr=subprocess.STDOUT)
    seen = 0
    try:
        while drive.poll() is None:
            with open(log.name, encoding='utf-8', errors='replace') as reader:
                actions = re.findall(r'R60 ACTION=([\w-]+)', reader.read())
            for action in actions[seen:]:
                act(action)
            seen = len(actions)
            time.sleep(0.5)
    finally:
        if drive.poll() is None:
            drive.kill()
        with open(log.name, encoding='utf-8', errors='replace') as reader:
            for line in reader:
                if re.search(r'R60 (?!ACTION)|All tests|Some tests|\[E\]|Expected|Actual|EXCEPTION', line):
                    print(line.rstrip()[:200])
        cleanup()
    print('退出码', drive.returncode)
    sys.exit(drive.returncode)


main()
