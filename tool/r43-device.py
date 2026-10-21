#!/usr/bin/env python3
"""R43 / UX09 on the disposable project AVD: host list type badges, Tailscale section, ⋮ menu.

How to run (emulator already booted on port 5580 and the SSH fixture up, see docs/dev/README.md):

  (cd tool/fixture-environment && ./up.sh)
  SHUN_R39_AVD=shun-r39-a30 python3 tool/r43-device.py

It refuses any device that tool/r39-device.py would refuse (other AVD, physical phone), then:
  - starts the fake Tailscale API (tool/tailscale-fixture/serve.dart) on 18480 with DEVICES_1;
  - adb reverse 18480 (fake API) and 22201 (ssh-edge of the fixture environment);
  - passes the fixture login in a temporary --dart-define-from-file, never on the command line;
  - runs integration_test/r43_host_list_test.dart and answers its markers:
      R43 SHOT <name> -> adb screencap <name>.png
      R43 SWAP        -> serve DEVICES_2 (edge leaves the control plane), then tell the test
                         through files/r43-swapped in the app's private dir
  - afterwards removes the reverses and the define file, stops the fake API and clears the
    test app's data (it holds a fake OAuth client and hosts pointing at 127.0.0.1).
Evidence goes to ../.toolchain/artifacts/r43-device-<time>/ (flutter log, fake API log, screenshots).
"""
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('r39_device', ROOT / 'tool/r39-device.py')
r39 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r39)

TARGET = 'integration_test/r43_host_list_test.dart'
FIXTURE = ROOT / 'tool/fixture-environment/.run/fixture.json'


def device(id, host, ip, os_name, connected=None):
    entry = {'id': id, 'name': f'{host}.tail0000.ts.net.', 'hostname': host,
             'addresses': [ip], 'os': os_name}
    if connected is not None:
        entry['connectedToControl'] = connected
    return entry


# Both catalog sources read this same list: same name, same IP, same device id in two sources.
# 2001 is the fixture's ssh-edge (127.0.0.1 + adb reverse 22201); 2003 reports no control-plane field.
DEVICES_1 = {'devices': [
    device('2001', 'edge', '127.0.0.1', 'linux', True),
    device('2002', 'laptop', '127.0.0.3', 'macOS', False),
    device('2003', 'unknown', '127.0.0.2', 'linux'),
]}
DEVICES_2 = {'devices': [
    device('2001', 'edge', '127.0.0.1', 'linux', False),
    device('2002', 'laptop', '127.0.0.3', 'macOS', False),
    device('2003', 'unknown', '127.0.0.2', 'linux'),
]}


def wait_port(port, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        with socket.socket() as s:
            if s.connect_ex(('127.0.0.1', port)) == 0:
                return
        time.sleep(0.5)
    raise SystemExit(f'fake Tailscale API did not listen on {port}')


def main():
    env = r39.environment()
    r39.check_device()
    r39.require(FIXTURE.is_file(), 'Start the fixture environment first (tool/fixture-environment/up.sh)')
    fixture = json.loads(FIXTURE.read_text())
    out = r39.CHAIN / 'artifacts' / time.strftime('r43-device-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    adb = str(r39.SDK / 'platform-tools/adb')

    def adb_run(*args, check=True):
        return subprocess.run([adb, '-s', r39.SERIAL, *args], check=check, timeout=60,
                              capture_output=True, text=True)

    (out / 'device.txt').write_text('\n'.join([
        f'avd={r39.AVD}',
        'wm size: ' + r39.shell('wm', 'size'),
        'sdk=' + r39.shell('getprop', 'ro.build.version.sdk'),
        'mosh plugin: ' + (r39.shell('pm', 'list', 'packages', 'top.xdwa.shun.mosh') or 'absent'),
    ]) + '\n')
    devices = out / 'devices.json'
    devices.write_text(json.dumps(DEVICES_1))
    api_log = (out / 'fake-api.log').open('w')
    api = subprocess.Popen(['dart', 'run', 'tool/tailscale-fixture/serve.dart', str(devices)],
                           cwd=ROOT, env=env, stdout=api_log, stderr=subprocess.STDOUT)
    define = None
    code = 1
    try:
        wait_port(18480)
        adb_run('reverse', 'tcp:18480', 'tcp:18480')
        adb_run('reverse', 'tcp:22201', 'tcp:22201')
        # Start from an empty app: earlier manual runs leave hosts and catalog sources behind.
        adb_run('shell', 'pm', 'clear', r39.PKG, check=False)
        handle, define = tempfile.mkstemp(prefix='r43-define-', suffix='.json')
        with os.fdopen(handle, 'w') as f:
            json.dump({'R43_SSH': json.dumps({
                'port': fixture['sshEdge']['port'],
                'user': fixture['user'],
                'password': fixture['password'],
                'fingerprint': fixture['sshEdge']['fingerprintSha256'],
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
            if len(marker) < 2 or marker[0] != 'R43':
                continue
            print(line.rstrip(), flush=True)
            if marker[1] == 'SHOT' and len(marker) == 3:
                with (out / f'{marker[2]}.png').open('wb') as png:
                    subprocess.run([adb, '-s', r39.SERIAL, 'exec-out', 'screencap', '-p'],
                                   stdout=png, check=True, timeout=30)
            elif marker[1] == 'SWAP':
                devices.write_text(json.dumps(DEVICES_2))
                adb_run('shell', 'run-as', r39.PKG, 'touch', 'files/r43-swapped')
        code = proc.wait()
        log.close()
    finally:
        if define:
            os.unlink(define)
        adb_run('reverse', '--remove', 'tcp:18480', check=False)
        adb_run('reverse', '--remove', 'tcp:22201', check=False)
        api.terminate()
        api.wait(timeout=10)
        api_log.close()
        adb_run('shell', 'pm', 'clear', r39.PKG, check=False)
    print(f'flutter test exit={code}; evidence in {out}', flush=True)
    return code


if __name__ == '__main__':
    sys.exit(main())
