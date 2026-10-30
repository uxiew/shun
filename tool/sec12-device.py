#!/usr/bin/env python3
"""SEC12 on the disposable project AVD: passwords, proxy passwords, the private key, keystrokes or
terminal text in crash dumps, notifications, intents, the recents screen or the device log?

How to run (emulator booted on port 5580, lock taken, SSH fixture up; see docs/dev/README.md):

  (cd tool/fixture-environment && ./up.sh)
  SHUN_R39_AVD=shun-r39-a30 python3 tool/sec12-device.py native   # or: java

  native  SIGSEGV to the app process through run-as (no root: the project AVD is a Play image)
  java    `am crash`, an uncaught exception on the main thread

Every run makes fresh random markers (letters and digits only, so `input text` can type them) and
passes them, with the fixture logins, to integration_test/sec12_leak_test.dart in a temporary
--dart-define-from-file (never on the command line). The test logs in three ways, fails twice,
types, makes the remote print, title, notify and write the clipboard, then waits; this script
answers its markers:
  SEC12 STEP type     adb shell input text <marker> + Enter (the Android key path)
  SEC12 STEP recents  open recents, screencap, dump the task list, bring the app back
  SEC12 STEP dump     notifications, activities, netstats, logcat so far
  SEC12 STEP crash    crash the app the chosen way
While the test runs it samples /proc/net/{tcp,tcp6,udp,udp6} for the app's uid: every remote
endpoint must be loopback (adb reverse). Afterwards it collects logcat (all buffers), dropbox
(crash records), and the app's private files, and searches all of them for every marker and
fixture secret. It prints only marker names and counts, never the values.

Exit 0 only when nothing leaked and every step ran. Evidence: ../.toolchain/artifacts/sec12-<kind>-<time>/.
Cleanup: removes the reverses and the define file, uninstalls the test app (it holds the fixture
logins and its crash state).
"""
import base64
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('r39_device', ROOT / 'tool/r39-device.py')
r39 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r39)

TARGET = 'integration_test/sec12_leak_test.dart'
FIXTURE = ROOT / 'tool/fixture-environment/.run/fixture.json'
ACTIVITY = 'top.xdwa.shun.MainActivity'
KINDS = {'native', 'java'}


def marker(prefix):
    return prefix + secrets.token_hex(6)


def parse_sockets(text, uid):
    """Remote endpoints of [uid]'s sockets in /proc/net/{tcp,udp}{,6} output."""
    found = set()
    for line in text.splitlines():
        cols = line.split()
        if len(cols) < 8 or cols[7] != str(uid) or ':' not in cols[2]:
            continue
        addr, port = cols[2].split(':')
        found.add(f'{addr}:{int(port, 16)}')
    return found


def loopback_or_unset(endpoint):
    addr, port = endpoint.split(':')
    # 0100007F = 127.0.0.1; 0000000000000000FFFF00000100007F = ::ffff:127.0.0.1; all-zero = no peer.
    return (set(addr) == {'0'} or addr == '0100007F'
            or addr == '0000000000000000FFFF00000100007F'
            or addr == '00000000000000000000000001000000')


def netstats_bytes(text, uid):
    """Total rb+tb the kernel booked to [uid] on real interfaces (loopback is not counted)."""
    total, mine = 0, False
    for line in text.splitlines():
        head = re.search(r'\buid=(-?\d+)\b', line)
        if head:
            mine = head.group(1) == str(uid)
            continue
        if mine:
            for rb, tb in re.findall(r'\brb=(\d+) rp=\d+ tb=(\d+)', line):
                total += int(rb) + int(tb)
    return total


def main():
    kind = sys.argv[1] if len(sys.argv) > 1 else ''
    r39.require(kind in KINDS, 'usage: sec12-device.py native|java')
    env = r39.environment()
    r39.check_device()
    r39.require(FIXTURE.is_file(), 'Start the fixture environment first (tool/fixture-environment/up.sh)')
    fixture = json.loads(FIXTURE.read_text())
    out = r39.CHAIN / 'artifacts' / time.strftime(f'sec12-{kind}-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    adb = str(r39.SDK / 'platform-tools/adb')
    pkg = r39.PKG

    def adb_run(*args, check=True, timeout=60):
        return subprocess.run([adb, '-s', r39.SERIAL, *args], check=check, timeout=timeout,
                              capture_output=True, text=True, errors='replace')

    def save(name, *args):
        text = adb_run(*args, check=False, timeout=120).stdout
        (out / name).write_text(text)
        return text

    marks = {name: marker(f'sec12{name[:2]}') for name in [
        'typed', 'injected', 'outputA', 'outputB', 'title', 'osc9', 'osc777', 'osc52',
        'wrongPassword', 'wrongProxyPassword', 'forwarded', 'aiOutputA', 'aiOutputB']}
    control = marker('sec12control')
    key_pem = Path(fixture['privateKeyPath']).read_text()
    key_lines = [l for l in key_pem.strip().splitlines()[1:-1] if len(l) >= 40]
    r39.require(key_lines, 'fixture private key has no body lines')
    # 名字 → 不该出现在 App 进程和远端以外任何地方的字。
    secret = {
        'password': fixture['password'],
        'socksPassword': fixture['socksAuth']['password'],
        'wrongPassword': marks['wrongPassword'],
        'wrongProxyPassword': marks['wrongProxyPassword'],
        **{f'privateKey.line{i}': l for i, l in enumerate(key_lines)},
        'typed': marks['typed'],
        'injected': marks['injected'],
        'output': marks['outputA'] + marks['outputB'],
        'title': marks['title'],
        'osc9': marks['osc9'],
        'osc777': marks['osc777'],
        'osc52': marks['osc52'],
        'osc52.base64': base64.b64encode(marks['osc52'].encode()).decode(),
        # R28：经本地端口转发送出去的字节、AI 工具终端里的输出。
        'forwarded': marks['forwarded'],
        'aiOutput': marks['aiOutputA'] + marks['aiOutputB'],
    }

    # 只存这轮随机生成的标记（复查时能重搜）；测试环境的密码和私钥只存摘要。
    (out / 'markers.json').write_text(json.dumps({
        'markers': marks,
        'control': control,
        'fixtureSha256': {n: hashlib.sha256(v.encode()).hexdigest()
                          for n, v in secret.items() if n not in marks
                          and n not in ('output', 'aiOutput')
                          and not n.startswith(('osc', 'title', 'typed', 'injected'))},
    }, indent=2))
    (out / 'device.txt').write_text('\n'.join([
        f'avd={r39.AVD}', f'kind={kind}',
        'sdk=' + r39.shell('getprop', 'ro.build.version.sdk'),
        'debuggable=' + r39.shell('getprop', 'ro.debuggable'),
    ]) + '\n')
    edge_port = str(fixture['sshEdge']['port'])
    socks_port = str(fixture['socksAuth']['port'])
    define = None
    steps = {}
    endpoints = set()
    stop = threading.Event()
    uid = [None]
    net_before = [None]

    def sample_sockets():
        while not stop.is_set():
            if uid[0] is None:
                listed = adb_run('shell', 'cmd', 'package', 'list', 'packages', '-U', pkg,
                                 check=False).stdout
                found = re.search(rf'package:{re.escape(pkg)} uid:(\d+)', listed)
                if found:
                    uid[0] = found.group(1)
                    # API 30 上 shell 没权限 --poll（报 Requires … NETWORK_STACK），detail 里是系统自己上次读的旧数，
                    # 读出来的 0 不代表没有流量（R28）。这时只记「没刷新」，以 /proc/net 采样为准。
                    if 'Security exception' in adb_run('shell', 'dumpsys', 'netstats', '--poll',
                                                       check=False).stdout:
                        net_before[0] = 'poll refused'
                        continue
                    net_before[0] = netstats_bytes(
                        adb_run('shell', 'dumpsys', 'netstats', 'detail', check=False).stdout,
                        uid[0])
            else:
                text = adb_run('shell', 'cat', '/proc/net/tcp', '/proc/net/tcp6',
                               '/proc/net/udp', '/proc/net/udp6', check=False).stdout
                endpoints.update(parse_sockets(text, uid[0]))
            stop.wait(0.5)

    def done(name):
        adb_run('shell', 'run-as', pkg, 'touch', f'files/sec12-{name}-done')

    code = 1
    sampler = threading.Thread(target=sample_sockets, daemon=True)
    proc = None
    try:
        adb_run('uninstall', pkg, check=False)
        adb_run('reverse', f'tcp:{edge_port}', f'tcp:{edge_port}')
        adb_run('reverse', f'tcp:{socks_port}', f'tcp:{socks_port}')
        adb_run('logcat', '-b', 'all', '-c', check=False)
        dropbox_since = int(time.time() * 1000)
        handle, define = tempfile.mkstemp(prefix='sec12-define-', suffix='.json')
        with os.fdopen(handle, 'w') as f:
            json.dump({'SEC12': json.dumps({
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
                'privateKey': key_pem,
                **marks,
            })}, f)
        sampler.start()
        log = (out / 'flutter-test.log').open('w')
        proc = subprocess.Popen(
            # --no-uninstall：不加的话 flutter test 一结束就卸掉 App，私有目录跟着没了，后面查不到。
            ['flutter', 'test', '--no-pub', '--no-uninstall', TARGET, '-d', r39.SERIAL,
             f'--dart-define-from-file={define}'],
            cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            errors='replace')
        for line in proc.stdout:
            log.write(line)
            log.flush()
            words = line.strip().split()
            if len(words) < 2 or words[0] != 'SEC12':
                continue
            print(line.rstrip(), flush=True)
            if words[1] != 'STEP' or len(words) != 3:
                continue
            step = words[2]
            if step == 'type':
                adb_run('shell', 'input', 'text', marks['injected'])
                adb_run('shell', 'input', 'keyevent', 'KEYCODE_ENTER')
                steps[step] = 'ok'
                done(step)
            elif step == 'recents':
                adb_run('shell', 'input', 'keyevent', 'KEYCODE_APP_SWITCH')
                time.sleep(3)
                with (out / 'recents.png').open('wb') as png:
                    subprocess.run([adb, '-s', r39.SERIAL, 'exec-out', 'screencap', '-p'],
                                   stdout=png, check=True, timeout=30)
                save('recents.txt', 'shell', 'dumpsys', 'activity', 'recents')
                # singleTask: 把原来的任务带回前台，不新建 Activity。
                adb_run('shell', 'am', 'start', '-n', f'{pkg}/{ACTIVITY}')
                time.sleep(2)
                resumed = adb_run('shell', 'dumpsys', 'activity', 'activities').stdout
                back = any(pkg in l for l in resumed.splitlines() if 'ResumedActivity' in l)
                steps[step] = 'ok' if back else 'app not resumed'
                done(step)
            elif step == 'dump':
                # 阳性对照：脚本自己往 logcat 写一个标记，后面必须搜得到，否则是搜索本身不灵。
                adb_run('shell', 'log', '-t', 'SEC12CONTROL', control)
                save('notifications.txt', 'shell', 'dumpsys', 'notification', '--noredact')
                save('activities.txt', 'shell', 'dumpsys', 'activity', 'activities')
                save('logcat-before-crash.txt', 'logcat', '-b', 'all', '-d', '-v', 'threadtime')
                steps[step] = 'ok'
                done(step)
            elif step == 'crash':
                pid = adb_run('shell', 'pidof', pkg, check=False).stdout.strip()
                if kind == 'native':
                    result = adb_run('shell', 'run-as', pkg, 'kill', '-SEGV', pid, check=False)
                else:
                    result = adb_run('shell', 'am', 'crash', pkg, check=False)
                steps[step] = f'pid={pid} exit={result.returncode} {result.stderr.strip()}'
                print(f'SEC12 CRASHED {steps[step]}', flush=True)
                break
        # 崩了以后 flutter test 未必关输出（它起的 adb 子进程还拿着管道），另起线程接着收，主线程限时等。
        drain = threading.Thread(target=lambda: [log.write(l) for l in proc.stdout], daemon=True)
        drain.start()
        try:
            proc.wait(timeout=120)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        drain.join(timeout=10)
        log.close()
        time.sleep(5)
        stop.set()
        sampler.join(timeout=10)

        pid_after = adb_run('shell', 'pidof', pkg, check=False).stdout.strip()
        save('logcat-after.txt', 'logcat', '-b', 'all', '-d', '-v', 'threadtime')
        dropbox = adb_run('shell', 'dumpsys', 'dropbox', '--print', check=False, timeout=180).stdout
        (out / 'dropbox.txt').write_text(dropbox)
        # toybox tar 碰到不存在的目录就什么都不出，先看有哪些。
        present = adb_run('shell', 'run-as', pkg, 'ls').stdout.split()
        wanted = [d for d in ['shared_prefs', 'files', 'cache', 'app_flutter', 'databases']
                  if d in present]
        tar = subprocess.run([adb, '-s', r39.SERIAL, 'exec-out', 'run-as', pkg, 'tar', '-cf', '-',
                              *wanted],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=60).stdout
        storage = {}
        with tarfile.open(fileobj=io.BytesIO(tar)) as archive:
            for entry in archive:
                if entry.isfile():
                    storage[entry.name] = archive.extractfile(entry).read().decode('latin-1')
        (out / 'storage-files.txt').write_text('\n'.join(sorted(storage)) + '\n')
        refused = 'Security exception' in adb_run('shell', 'dumpsys', 'netstats', '--poll',
                                                  check=False).stdout
        net_after = 'poll refused' if refused else netstats_bytes(
            adb_run('shell', 'dumpsys', 'netstats', 'detail', check=False).stdout, uid[0]) \
            if uid[0] else None

        sources = {name: (out / name).read_text(errors='replace') for name in [
            'logcat-before-crash.txt', 'logcat-after.txt', 'dropbox.txt', 'notifications.txt',
            'activities.txt', 'recents.txt', 'flutter-test.log'] if (out / name).is_file()}
        # flutter_assets 是调试包自己的代码：测试经 --dart-define 拿到的标记和登录被编进 kernel_blob.bin，
        # 是测试带进去的、不是 App 写的，不算。其余私有文件都搜。
        sources.update({f'storage:{k}': v for k, v in storage.items()
                        if not k.startswith('app_flutter/flutter_assets/')})
        leaks = {src: {n: text.count(v) for n, v in secret.items() if v in text}
                 for src, text in sources.items()}
        leaks = {k: v for k, v in leaks.items() if v}
        control_found = sorted(src for src, text in sources.items() if control in text)
        # 私有文件这一路的对照：主机 id 不是秘密，保险库的普通偏好里应当搜得到。
        # 搜不到说明打包或解码没拿到内容，「私有文件 0 命中」就不算数（R28 补的）。
        storage_control = sorted(src for src, text in sources.items()
                                 if src.startswith('storage:') and 'sec12-socks' in text)
        app_lines = [l for l in sources.get('logcat-after.txt', '').splitlines()
                     if pkg in l or 'AndroidRuntime' in l or ' DEBUG ' in l or 'flutter' in l]
        (out / 'logcat-app-lines.txt').write_text('\n'.join(app_lines) + '\n')
        crash_entries = [m.group(0) for m in re.finditer(
            r'^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d (data_app_\w+|SYSTEM_TOMBSTONE)[^\n]*', dropbox, re.M)]
        intents = [l for l in sources.get('logcat-after.txt', '').splitlines()
                   if 'START u0' in l or 'Displayed' in l]
        (out / 'intents.txt').write_text('\n'.join(intents) + '\n')
        notif = sources.get('notifications.txt', '')
        app_notifications = len(re.findall(rf'NotificationRecord\(\S+: pkg={re.escape(pkg)}\b', notif))
        summary = {
            'kind': kind,
            'testExit': proc.returncode,
            'steps': steps,
            'pidAfter': pid_after or None,
            'uid': uid[0],
            'remoteEndpoints': sorted(endpoints),
            'nonLoopbackEndpoints': sorted(e for e in endpoints if not loopback_or_unset(e)),
            'netstatsBytes': {'before': net_before[0], 'after': net_after},
            'appNotifications': app_notifications,
            'dropboxCrashEntries': crash_entries[-6:],
            'startIntents': len(intents),
            'storageFiles': len(storage),
            'controlFoundIn': control_found,
            'storageControlFoundIn': storage_control,
            'searched': sorted(secret),
            'leaks': leaks,
        }
        (out / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2))
        print(json.dumps({k: v for k, v in summary.items() if k != 'searched'},
                         ensure_ascii=False, indent=2), flush=True)
        ran = all(steps.get(s) for s in ['type', 'recents', 'dump', 'crash'])
        control_ok = control_found == ['logcat-after.txt', 'logcat-before-crash.txt']
        code = 0 if (ran and control_ok and storage_control and not leaks
                     and not summary['nonLoopbackEndpoints']) else 1
    finally:
        stop.set()
        if proc and proc.poll() is None:
            proc.kill()
        if define:
            os.unlink(define)
        adb_run('reverse', '--remove', f'tcp:{edge_port}', check=False)
        adb_run('reverse', '--remove', f'tcp:{socks_port}', check=False)
        adb_run('uninstall', pkg, check=False)
    print(f'sec12 exit={code}; evidence in {out}', flush=True)
    return code


if __name__ == '__main__':
    sys.exit(main())
