#!/usr/bin/env python3
"""R67 / TSC11 on the disposable project AVD: real lifecycle, real clock, real HTTP, fake Tailscale API.

How to run (emulator already booted on port 5580, see docs/dev/README.md), about 10 minutes:

  SHUN_R39_AVD=shun-r39-a30 python3 tool/r67-device.py

It refuses any device that tool/r39-device.py would refuse (other AVD, physical phone), then:
  - starts the fake Tailscale API (tool/tailscale-fixture/serve.dart) on 18480 and reverses the port;
  - runs integration_test/r67_auto_refresh_test.dart and answers its markers (see that file);
  - afterwards removes the reverse, stops the fake API and clears the test app's data.
Finally it checks the API log itself, because only it can see requests the App did not show:
  no device read between bg-start and bg-end, none after a 429 or 401 for a whole interval, and
  the source without a saved key was read exactly once (by hand).
Evidence goes to ../.toolchain/artifacts/r67-device-<time>/ (flutter log, fake API log, screenshots).
"""
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('r39_device', ROOT / 'tool/r39-device.py')
r39 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r39)

TARGET = 'integration_test/r67_auto_refresh_test.dart'
ACTIVITY = f'{r39.PKG}/top.xdwa.shun.MainActivity'
BACKGROUND_SECONDS = 75


def devices(connected):
    # 192.0.2.x is documentation-only address space: nothing here is ever dialled, and never 100.x.
    return {'devices': [
        {'id': '2001', 'name': 'edge.tail0000.ts.net.', 'hostname': 'edge',
         'addresses': ['192.0.2.1'], 'os': 'linux', 'connectedToControl': connected},
    ]}


SCENARIOS = {
    'online': devices(True),
    'offline': devices(False),
    '429': {'__status': 429, '__retryAfter': '120', 'message': 'rate limited'},
    '401': {'__status': 401, 'message': 'unauthorized'},
}


def wait_port(port, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        with socket.socket() as s:
            if s.connect_ex(('127.0.0.1', port)) == 0:
                return
        time.sleep(0.5)
    raise SystemExit(f'fake Tailscale API did not listen on {port}')


def device_reads(path):
    reads = []
    for line in path.read_text().splitlines():
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if entry.get('method') == 'GET' and str(entry.get('path', '')).endswith('/devices'):
            reads.append(entry)
    return reads


def main():
    env = r39.environment()
    r39.check_device()
    out = r39.CHAIN / 'artifacts' / time.strftime('r67-device-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    adb = str(r39.SDK / 'platform-tools/adb')

    def adb_run(*args, check=True):
        return subprocess.run([adb, '-s', r39.SERIAL, *args], check=check, timeout=60,
                              capture_output=True, text=True)

    def ack(number):
        adb_run('shell', 'run-as', r39.PKG, 'touch', f'files/r67-ack-{number}')

    (out / 'device.txt').write_text('\n'.join([
        f'avd={r39.AVD}',
        'wm size: ' + r39.shell('wm', 'size'),
        'sdk=' + r39.shell('getprop', 'ro.build.version.sdk'),
    ]) + '\n')
    served = out / 'devices.json'
    served.write_text(json.dumps(SCENARIOS['online']))
    api_path = out / 'fake-api.log'
    api_log = api_path.open('w')
    api = subprocess.Popen(['dart', 'run', 'tool/tailscale-fixture/serve.dart', str(served)],
                           cwd=ROOT, env=env, stdout=api_log, stderr=subprocess.STDOUT)
    marks = {}
    code = 1
    try:
        wait_port(18480)
        adb_run('reverse', 'tcp:18480', 'tcp:18480')
        adb_run('shell', 'pm', 'clear', r39.PKG, check=False)
        log = (out / 'flutter-test.log').open('w')
        proc = subprocess.Popen(
            ['flutter', 'test', '--no-pub', TARGET, '-d', r39.SERIAL],
            cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in proc.stdout:
            log.write(line)
            log.flush()
            marker = line.strip().split()
            if len(marker) < 2 or marker[0] != 'R67':
                continue
            print(line.rstrip(), flush=True)
            if marker[1] == 'SHOT' and len(marker) == 3:
                with (out / f'{marker[2]}.png').open('wb') as png:
                    subprocess.run([adb, '-s', r39.SERIAL, 'exec-out', 'screencap', '-p'],
                                   stdout=png, check=True, timeout=30)
            elif marker[1] == 'MARK' and len(marker) == 3:
                api_log.flush()
                marks[marker[2]] = len(device_reads(api_path))
            elif marker[1] == 'SERVE' and len(marker) == 4:
                scenario = marker[2]
                if scenario == 'down':
                    adb_run('reverse', '--remove', 'tcp:18480')
                elif scenario == 'up':
                    adb_run('reverse', 'tcp:18480', 'tcp:18480')
                else:
                    served.write_text(json.dumps(SCENARIOS[scenario]))
                ack(marker[3])
            elif marker[1] == 'HOME' and len(marker) == 3:
                adb_run('shell', 'input', 'keyevent', 'HOME')
                time.sleep(BACKGROUND_SECONDS)
                api_log.flush()
                marks['bg-reads-end'] = len(device_reads(api_path))
                # 回前台之前先放回执：测试在 ack 之后才取「回来之前最后一次读的时间」。
                ack(marker[2])
                time.sleep(1.5)
                adb_run('shell', 'am', 'start', '-n', ACTIVITY)
        code = proc.wait()
        log.close()
    finally:
        adb_run('reverse', '--remove', 'tcp:18480', check=False)
        api.terminate()
        api.wait(timeout=10)
        api_log.close()
        adb_run('shell', 'pm', 'clear', r39.PKG, check=False)

    reads = device_reads(api_path)
    other = [r for r in reads if r.get('authorization') == 'bearer-other']
    def window(start, end):
        return marks[end] - marks[start] if start in marks and end in marks else None
    result = {
        'test_exit': code,
        'marks': marks,
        'device_reads_total': len(reads),
        'reads_while_in_background': window('bg-start', 'bg-reads-end'),
        'reads_after_429_within_70s': window('429-hit', '429-wait'),
        'reads_after_401_within_70s': window('401-hit', '401-wait'),
        'reads_of_source_without_key': len(other),
    }
    (out / 'result.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2), flush=True)
    checks = (
        result['reads_while_in_background'] == 0
        and result['reads_after_429_within_70s'] == 0
        and result['reads_after_401_within_70s'] == 0
        and result['reads_of_source_without_key'] == 1
    )
    print(f'flutter test exit={code}; log checks ok={checks}; evidence in {out}', flush=True)
    return code if code else (0 if checks else 1)


if __name__ == '__main__':
    sys.exit(main())
