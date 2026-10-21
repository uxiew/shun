#!/usr/bin/env python3
"""R25 / UX10, SEC12 on the disposable project AVD: the connection log over Direct, SOCKS and Jump.

How to run (emulator already booted on port 5580 and the SSH fixture up, see docs/dev/README.md):

  (cd tool/fixture-environment && ./up.sh)
  SHUN_R39_AVD=shun-r39-a30 python3 tool/r25-device.py

docker must be on PATH: the KILL marker kills sshd sessions inside the fixture containers.
It refuses any device that tool/r39-device.py would refuse (other AVD, physical phone), then:
  - adb reverse 22201 (ssh-edge) and 21080 (dante with auth) of the fixture environment;
  - clears the test app's data, passes the fixture logins in a temporary --dart-define-from-file
    (never on the command line);
  - runs integration_test/r25_connection_log_test.dart and answers its markers:
      R25 SHOT <name>        -> adb screencap <name>.png
      R25 KILL <service> <n> -> pkill sshd-session in that fixture container, then tell the test
                                through files/r25-killed-<n> in the app's private dir
  - copies the app's connection log file out before clearing (it must not hold any login, address
    or host name; the script checks that again on the host side);
  - afterwards removes the reverses and the define file and clears the test app's data
    (it holds hosts and passwords pointing at the fixture).
Evidence goes to ../.toolchain/artifacts/r25-device-<time>/ (flutter log, screenshots).
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('r39_device', ROOT / 'tool/r39-device.py')
r39 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r39)

TARGET = 'integration_test/r25_connection_log_test.dart'
FIXTURE = ROOT / 'tool/fixture-environment/.run/fixture.json'
COMPOSE = ROOT / 'tool/fixture-environment/compose.yaml'
# Only this one may be killed: both the direct and the jump tab go through it.
SERVICES = {'ssh-edge'}


def main():
    env = r39.environment()
    r39.check_device()
    r39.require(FIXTURE.is_file(), 'Start the fixture environment first (tool/fixture-environment/up.sh)')
    r39.require(shutil.which('docker', path=env['PATH']) is not None, 'docker is not on PATH')
    fixture = json.loads(FIXTURE.read_text())
    out = r39.CHAIN / 'artifacts' / time.strftime('r25-device-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    adb = str(r39.SDK / 'platform-tools/adb')
    edge_port = str(fixture['sshEdge']['port'])
    socks_port = str(fixture['socksAuth']['port'])
    secrets = [fixture['password'], fixture['socksAuth']['username'],
               fixture['socksAuth']['password'], fixture['target']['name'], '127.0.0.1']

    def adb_run(*args, check=True):
        return subprocess.run([adb, '-s', r39.SERIAL, *args], check=check, timeout=60,
                              capture_output=True, text=True)

    (out / 'device.txt').write_text('\n'.join([
        f'avd={r39.AVD}',
        'wm size: ' + r39.shell('wm', 'size'),
        'sdk=' + r39.shell('getprop', 'ro.build.version.sdk'),
    ]) + '\n')
    define = None
    code = 1
    try:
        adb_run('reverse', f'tcp:{edge_port}', f'tcp:{edge_port}')
        adb_run('reverse', f'tcp:{socks_port}', f'tcp:{socks_port}')
        adb_run('shell', 'pm', 'clear', r39.PKG, check=False)
        handle, define = tempfile.mkstemp(prefix='r25-define-', suffix='.json')
        with os.fdopen(handle, 'w') as f:
            json.dump({'R25_SSH': json.dumps({
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
                # The clear step deletes the file; grab it while it is still there.
                if marker[2] == '05-all-hosts':
                    copy = adb_run('exec-out', 'run-as', r39.PKG, 'cat',
                                   'files/diagnostics/connection_events.json', check=False)
                    (out / 'connection_events.json').write_text(copy.stdout)
            elif marker[1] == 'KILL' and len(marker) == 4 and marker[2] in SERVICES:
                result = subprocess.run(
                    ['docker', 'compose', '-f', str(COMPOSE), 'exec', '-T', marker[2],
                     'pkill', '-KILL', '-f', 'sshd-session'],
                    env=env, capture_output=True, text=True, timeout=60)
                print(f'R25 KILLED {marker[2]} exit={result.returncode}', flush=True)
                log.write(f'R25 KILLED {marker[2]} exit={result.returncode} {result.stderr}\n')
                adb_run('shell', 'run-as', r39.PKG, 'touch', f'files/r25-killed-{marker[3]}')
        code = proc.wait()
        log.close()
        copied = out / 'connection_events.json'
        if copied.is_file():
            text = copied.read_text()
            found = [s for s in secrets if s and s in text]
            print(f'R25 HOST-SIDE file bytes={len(text)} leaks={found}', flush=True)
            if found:
                code = code or 1
    finally:
        if define:
            os.unlink(define)
        adb_run('reverse', '--remove', f'tcp:{edge_port}', check=False)
        adb_run('reverse', '--remove', f'tcp:{socks_port}', check=False)
        adb_run('shell', 'pm', 'clear', r39.PKG, check=False)
    print(f'flutter test exit={code}; evidence in {out}', flush=True)
    return code


if __name__ == '__main__':
    sys.exit(main())
