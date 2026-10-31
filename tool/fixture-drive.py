#!/usr/bin/env python3
"""Run one integration test against the SSH fixture on the disposable project AVD.

How to run (emulator booted on port 5580, fixture up, see docs/dev/README.md):

  (cd tool/fixture-environment && ./up.sh)
  SHUN_R39_AVD=shun-r39-a30 python3 tool/fixture-drive.py integration_test/r65_known_hosts_test.dart

It refuses any device tool/r39-device.py would refuse (other AVD, physical phone), then reverses
ssh-edge's port, clears the test app's data, passes the fixture login in a temporary
--dart-define-from-file (never on the command line) as SHUN_FIXTURE, runs the test, and clears the
app's data again: it holds hosts and passwords pointing at the fixture.
The flutter log goes to ../.toolchain/artifacts/fixture-drive-<time>/flutter-test.log.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('r39_device', ROOT / 'tool/r39-device.py')
r39 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r39)

FIXTURE = ROOT / 'tool/fixture-environment/.run/fixture.json'


def main():
    r39.require(len(sys.argv) == 2, 'Usage: fixture-drive.py integration_test/<x>_test.dart')
    target = sys.argv[1]
    env = r39.environment()
    r39.check_device()
    r39.require(FIXTURE.is_file(), 'Start the fixture environment first (tool/fixture-environment/up.sh)')
    fixture = json.loads(FIXTURE.read_text())
    out = r39.CHAIN / 'artifacts' / time.strftime('fixture-drive-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    adb = str(r39.SDK / 'platform-tools/adb')
    edge_port = str(fixture['sshEdge']['port'])

    def adb_run(*args, check=True):
        return subprocess.run([adb, '-s', r39.SERIAL, *args], check=check, timeout=60,
                              capture_output=True, text=True)

    define = None
    code = 1
    try:
        adb_run('reverse', f'tcp:{edge_port}', f'tcp:{edge_port}')
        adb_run('shell', 'pm', 'clear', r39.PKG, check=False)
        handle, define = tempfile.mkstemp(prefix='fixture-define-', suffix='.json')
        with os.fdopen(handle, 'w') as f:
            json.dump({'SHUN_FIXTURE': json.dumps({
                'user': fixture['user'],
                'password': fixture['password'],
                'edgePort': fixture['sshEdge']['port'],
                'edgeFingerprint': fixture['sshEdge']['fingerprintSha256'],
            })}, f)
        with (out / 'flutter-test.log').open('w') as log:
            proc = subprocess.Popen(
                ['flutter', 'test', '--no-pub', target, '-d', r39.SERIAL,
                 f'--dart-define-from-file={define}'],
                cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            for line in proc.stdout:
                log.write(line)
                log.flush()
                print(line.rstrip(), flush=True)
            code = proc.wait()
    finally:
        if define:
            os.unlink(define)
        adb_run('reverse', '--remove', f'tcp:{edge_port}', check=False)
        adb_run('shell', 'pm', 'clear', r39.PKG, check=False)
    print(f'flutter test exit={code}; log in {out}', flush=True)
    return code


if __name__ == '__main__':
    sys.exit(main())
