#!/usr/bin/env python3
"""Check dedicated emulator private data and Flutter logs without copying secrets.

Called while the test APK is installed; never scans APK (it embeds disposable
fixture defines). Only boolean results are printed, no values or file contents.
"""
import json
import pathlib
import subprocess

adb = ['adb', '-s', 'emulator-5580']
pkg = 'top.xdwa.shun'
assert subprocess.check_output(adb + ['emu', 'avd', 'name']).decode().splitlines()[0] == 'shun-a35-4k'
cfg = json.loads((pathlib.Path(__file__).parent / '.run/fixture.json').read_text())
secrets = [cfg['password'].encode(), cfg['socksAuth']['password'].encode()]
paths = subprocess.check_output(adb + ['shell', 'run-as', pkg, 'find', 'shared_prefs', 'files', '-type', 'f']).decode().splitlines()
assert any('FlutterSecureStorage' in p for p in paths), 'Missing real secure storage'
for path in paths:
    data = subprocess.check_output(adb + ['exec-out', 'run-as', pkg, 'cat', path])
    assert not any(secret in data for secret in secrets), 'Plaintext fixture credential in private storage'
logs = subprocess.check_output(adb + ['logcat', '-d', '-s', 'flutter'])
assert not any(secret in logs for secret in secrets), 'Fixture credential in Flutter log'
print(f'R40 plaintext credential scan PASS: {len(paths)} private files + Flutter log')
