#!/usr/bin/env python3
"""R24 / UX12 on the disposable project AVD: the host file entry over Direct, SOCKS and Jump.

How to run (emulator already booted on port 5580 and the SSH fixture up, see docs/dev/README.md):

  (cd tool/fixture-environment && ./up.sh)
  SHUN_R39_AVD=shun-r39-a30 python3 tool/r24-device.py

docker must be on PATH: the KILL marker kills sshd sessions inside the fixture containers.
It refuses any device that tool/r39-device.py would refuse (other AVD, physical phone), then:
  - adb reverse 22201 (ssh-edge) and 21080 (dante with auth) of the fixture environment;
  - clears the test app's data, passes the fixture logins in a temporary --dart-define-from-file
    (never on the command line);
  - runs integration_test/r24_files_test.dart and answers its markers:
      R24 SHOT <name>       -> adb screencap <name>.png
      R24 KILL <service> <n> -> pkill sshd-session in that fixture container, then tell the test
                               through files/r24-killed-<n> in the app's private dir
  - afterwards removes the reverses and the define file and clears the test app's data
    (it holds hosts and passwords pointing at the fixture).
Evidence goes to ../.toolchain/artifacts/r24-device-<time>/ (flutter log, screenshots).
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

TARGET = 'integration_test/r24_files_test.dart'
FIXTURE = ROOT / 'tool/fixture-environment/.run/fixture.json'
COMPOSE = ROOT / 'tool/fixture-environment/compose.yaml'
# Only these may be killed: the test names the last hop of each route.
SERVICES = {'ssh-edge', 'target'}


def main():
    env = r39.environment()
    r39.check_device()
    r39.require(FIXTURE.is_file(), 'Start the fixture environment first (tool/fixture-environment/up.sh)')
    r39.require(shutil.which('docker', path=env['PATH']) is not None, 'docker is not on PATH')
    fixture = json.loads(FIXTURE.read_text())
    out = r39.CHAIN / 'artifacts' / time.strftime('r24-device-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    adb = str(r39.SDK / 'platform-tools/adb')
    edge_port = str(fixture['sshEdge']['port'])
    socks_port = str(fixture['socksAuth']['port'])

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
        handle, define = tempfile.mkstemp(prefix='r24-define-', suffix='.json')
        with os.fdopen(handle, 'w') as f:
            json.dump({'R24_SSH': json.dumps({
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
            if len(marker) < 2 or marker[0] != 'R24':
                continue
            print(line.rstrip(), flush=True)
            if marker[1] == 'SHOT' and len(marker) == 3:
                with (out / f'{marker[2]}.png').open('wb') as png:
                    subprocess.run([adb, '-s', r39.SERIAL, 'exec-out', 'screencap', '-p'],
                                   stdout=png, check=True, timeout=30)
            elif marker[1] == 'KILL' and len(marker) == 4 and marker[2] in SERVICES:
                result = subprocess.run(
                    ['docker', 'compose', '-f', str(COMPOSE), 'exec', '-T', marker[2],
                     'pkill', '-KILL', '-f', 'sshd-session'],
                    env=env, capture_output=True, text=True, timeout=60)
                print(f'R24 KILLED {marker[2]} exit={result.returncode}', flush=True)
                log.write(f'R24 KILLED {marker[2]} exit={result.returncode} {result.stderr}\n')
                adb_run('shell', 'run-as', r39.PKG, 'touch', f'files/r24-killed-{marker[3]}')
        code = proc.wait()
        log.close()
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
