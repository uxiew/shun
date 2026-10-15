#!/usr/bin/env python3
"""R39 on the disposable project AVD; check is read-only, run builds fresh APKs."""
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import time
import uuid
from urllib.parse import urlencode, urlparse, urlunparse

ROOT = Path(__file__).resolve().parents[1]
CHAIN = ROOT.parent / '.toolchain'
SDK = CHAIN / 'android-sdk'
AVD_APIS = {'shun-a35-4k': '35', 'shun-r39-a30': '30'}
AVD = os.environ.get('SHUN_R39_AVD', 'shun-a35-4k')
SERIAL = 'emulator-5580'
PKG = 'top.xdwa.shun'
PACKAGES = {
    'host': PKG,
    'fixture-fakeuu': 'com.netease.uuremote',
    'fixture-fakerustdesk': 'com.carriez.flutter_hbb',
    'fixture-echo': 'example.shun.fixture.echo',
}
GATES = {'kill-migrate', 'cold-attached', 'return-rustdesk', 'return-uu',
         'return-migrated-rustdesk', 'return-migrated-uu', 'shot-entries'}
TARGET = 'integration_test/r39_remote_entries_test.dart'
MIN_BUILD_FREE = 12 * 1024 ** 3


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(args, *, env=None, cwd=ROOT, timeout=60, check=True):
    try:
        result = subprocess.run([str(a) for a in args], cwd=cwd, env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=timeout)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f'{Path(args[0]).name} timed out; arguments withheld') from None
    # Do not echo argv: a callback contains synthetic secret markers.
    require(not check or result.returncode == 0,
            f'{Path(args[0]).name} failed ({result.returncode}); inspect evidence')
    return result.stdout.decode(errors='replace').strip()


def environment():
    env = dict(os.environ)
    flutter = Path(env.get('FLUTTER_SDK', '/opt/homebrew/share/flutter'))
    java = Path(env.get('JAVA_HOME',
                       '/Applications/Android Studio.app/Contents/jbr/Contents/Home'))
    zig = Path(run(['mise', 'which', 'zig']))
    require(run([zig, 'version']) == '0.16.0', 'Project requires mise Zig 0.16.0')
    env.update(FLUTTER_SDK=str(flutter), JAVA_HOME=str(java),
               ANDROID_HOME=str(SDK), ANDROID_SDK_ROOT=str(SDK),
               ANDROID_NDK_HOME=str(SDK / 'ndk/28.2.13676358'),
               ANDROID_AVD_HOME=str(CHAIN / 'avd'),
               GRADLE_USER_HOME=str(CHAIN / 'gradle-home'),
               ZIG_GLOBAL_CACHE_DIR=str(CHAIN / 'zig-cache'),
               SHUN_ZIG_EXECUTABLE=str(zig), PUB_HOSTED_URL='https://pub.dev',
               CI='true', NO_PROXY='localhost,127.0.0.1,::1',
               no_proxy='localhost,127.0.0.1,::1')
    # Plugins may request an older compile SDK than the app. Discover/reuse it
    # explicitly instead of letting AGP silently install a duplicate component.
    env['ORG_GRADLE_PROJECT_android.builder.sdkDownload'] = 'false'
    env['PATH'] = os.pathsep.join(map(str, [zig.parent, flutter / 'bin',
        java / 'bin', SDK / 'platform-tools', SDK / 'emulator'])) + os.pathsep + env['PATH']
    return env


def adb(*args, check=True):
    return run([SDK / 'platform-tools/adb', '-s', SERIAL, *args], check=check)


def shell(*args, check=True):
    return adb('shell', shlex.join(map(str, args)), check=check)


def emulator_process_matches(command):
    try:
        args = shlex.split(command)
        return (args[args.index('-avd') + 1] == AVD
                and args[args.index('-port') + 1] == '5580'
                and Path(args[0]).resolve().is_relative_to((SDK / 'emulator').resolve()))
    except (ValueError, IndexError):
        return False


def check_device():
    require(AVD in AVD_APIS, 'Unsupported R39 emulator profile')
    require(adb('get-state') == 'device', f'Expected {SERIAL}')
    require(adb('emu', 'avd', 'name').splitlines()[0] == AVD,
            f'Refusing any AVD other than {AVD}')
    require(shell('getprop', 'ro.kernel.qemu') == '1', 'Refusing a physical device')
    require(shell('getprop', 'ro.build.version.sdk') == AVD_APIS[AVD],
            f'Expected Android {AVD_APIS[AVD]}')
    config = CHAIN / 'avd' / f'{AVD}.ini'
    expected = str((CHAIN / 'avd' / f'{AVD}.avd').resolve())
    require(config.is_file() and f'path={expected}' in config.read_text().splitlines(),
            'Dedicated AVD config is missing or points outside the project')
    # Verify the running process, not just an easily duplicated AVD name.
    processes = run(['ps', '-axo', 'command=']).splitlines()
    matches = [p for p in processes if emulator_process_matches(p)]
    require(len(matches) == 1,
            'Expected one emulator process from the selected SDK on port 5580')


def preflight(env, *, build=False):
    missing = [str(p.relative_to(SDK)) for p in [
        SDK / 'platform-tools/adb', SDK / 'emulator/emulator',
        SDK / 'platforms/android-36/android.jar',
        SDK / 'build-tools/36.0.0/apksigner', SDK / 'build-tools/36.0.0/aapt',
        SDK / 'ndk/28.2.13676358/source.properties',
        SDK / 'cmake/3.22.1/bin/cmake',
    ] if not p.is_file()]
    require(not missing, 'Project SDK missing: ' + ', '.join(missing))
    require(Path(env['FLUTTER_SDK'], 'bin/flutter').is_file(), 'Flutter missing')
    if build:
        require(shutil.disk_usage(CHAIN).free >= MIN_BUILD_FREE,
                'Need at least 12 GiB free AFTER SDK installation before building')
    check_device()


def signer(apk, env):
    text = run([SDK / 'build-tools/36.0.0/apksigner', 'verify', '--print-certs', apk], env=env)
    found = re.findall(r'Signer #\d+ certificate SHA-256 digest: ([0-9a-f]{64})', text)
    require(len(found) == 1, 'Expected exactly one verified APK signer')
    return found[0]


def installed_signer(package, out, env):
    paths = shell('pm', 'path', package).splitlines()
    require(len(paths) == 1 and paths[0].startswith('package:/data/app/'),
            'Unexpected installed APK path; refusing cleanup')
    path = paths[0][len('package:'):]
    copy = out / ('installed-' + package + '.apk')
    adb('pull', path, str(copy))
    digest = signer(copy, env)
    copy.unlink()  # Only the inspection copy just created by this run.
    return digest


def apk_package(apk, env):
    text = run([SDK / 'build-tools/36.0.0/aapt', 'dump', 'badging', apk], env=env)
    found = re.search(r"^package: name='([^']+)'", text)
    require(found is not None, 'Cannot read APK package identity')
    return found[1]


def logged(args, path, env, timeout=1200):
    with path.open('wb') as log:
        result = subprocess.run(list(map(str, args)), cwd=ROOT, env=env,
                                stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
    require(result.returncode == 0, f'Command failed; see {path}')


def build(out, env):
    keys = CHAIN / 'plugin-keys'
    keys.mkdir(mode=0o700, exist_ok=True)
    key = keys / 'fixture-author.jks'
    if not key.exists():
        logged(['keytool', '-genkeypair', '-keystore', key,
                '-storepass', 'shun-fixture', '-keypass', 'shun-fixture',
                '-alias', 'author', '-keyalg', 'RSA', '-keysize', '3072',
                '-validity', '3650', '-dname', 'CN=shun fixture author, O=shun test only'],
               out / 'fixture-key.log', env)
        key.chmod(0o600)
    cert = run(['keytool', '-list', '-v', '-keystore', key, '-storepass',
                'shun-fixture', '-alias', 'author', '-J-Duser.language=en'], env=env)
    match = re.search(r'SHA256: ([0-9A-F:]{95})', cert)
    require(match is not None, 'Cannot read test author certificate')
    cfg = {'runId': uuid.uuid4().hex,
           'fixtureSigner': match[1].replace(':', '').lower()}
    defines = out / 'defines.json'
    defines.write_text(json.dumps({'R39_CONFIG': json.dumps(cfg)}))
    defines.chmod(0o600)
    logged(['flutter', 'build', 'apk', '--no-pub', '--debug',
            '--target-platform', 'android-arm64', '--target', TARGET,
            f'--dart-define-from-file={defines}'], out / 'build-host.log', env)
    host = out / 'host.apk'
    shutil.copy2(ROOT / 'build/app/outputs/flutter-apk/app-debug.apk', host)
    host_signer = signer(host, env)
    modules = [m for m in PACKAGES if m != 'host']
    logged([ROOT / 'android/gradlew', '-p', ROOT / 'plugins', '--no-daemon',
            *[f':{m}:assembleRelease' for m in modules],
            f'-PhostSha256={host_signer}', '-PsignWith=author'],
           out / 'build-fixtures.log', env)
    apks = {'host': host}
    for module in modules:
        apk = out / f'{module}.apk'
        shutil.copy2(ROOT / f'plugins/{module}/build/outputs/apk/release/{module}-release.apk', apk)
        apks[module] = apk
    for module, apk in apks.items():
        require(apk_package(apk, env) == PACKAGES[module], 'Unexpected APK identity')
        require(signer(apk, env) == (host_signer if module == 'host' else cfg['fixtureSigner']),
                'Unexpected APK certificate')
    return cfg, defines, apks


def private_read(name):
    return shell('run-as', PKG, 'cat', f'files/r39/{name}', check=False)


def private_write(name, value):
    require(re.fullmatch(r'[a-z-]+', name) is not None, 'Unsafe fixture file name')
    shell('run-as', PKG, 'sh', '-c',
          f'printf %s {shlex.quote(value)} > files/r39/{name}')


def callback(cfg):
    run_id = cfg['runId']
    state = base64.urlsafe_b64encode(bytes.fromhex(run_id)).decode().rstrip('=')
    return 'shun-uuremote://callback/bind?' + urlencode({
        'state': state, 'nonce': 'r39-' + run_id,
        'anonymous_device_id': 'r39-new-' + run_id})


def report(text, cfg, phase, status):
    data = json.loads(text)
    require(data.get('runId') == cfg['runId'] and data.get('phase') == phase
            and data.get('status') == status and type(data.get('pid')) is int
            and data['pid'] > 0, 'Missing/mismatched device phase evidence')
    return data


def vm_service(text):
    match = re.search(r'(?:Dart VM service is listening on|VM Service is listening on)'
                      r'\s+(http://127\.0\.0\.1:\d+/[^\s]+)', text)
    if not match:
        return None
    uri = urlparse(match[1])
    require(uri.port is not None and 1024 <= uri.port <= 65535, 'Invalid VM port')
    return uri


def stop():
    shell('am', 'force-stop', PKG)
    require(not shell('pidof', PKG, check=False), 'App process did not stop')


def wait_foreground(package):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        top = shell('dumpsys', 'activity', 'activities')
        resumed = [line for line in top.splitlines() if 'ResumedActivity' in line]
        if any(package in line for line in resumed):
            return
        time.sleep(0.25)
    raise RuntimeError('External fixture did not become foreground')


def execute_phase(phase, cfg, defines, apk, out, env):
    stop()
    private_write('phase', phase)
    private_write('gate', '')
    driver = ['flutter', 'drive', '--no-pub', '--keep-app-running', '-d', SERIAL,
              '--driver', 'test_driver/integration_test.dart', '--target', TARGET,
              f'--dart-define-from-file={defines}']
    forward = None
    process = None
    try:
        if phase == 'cold':
            # Actual callback boots the Android process BEFORE drive attaches.
            # am start output contains the URI; discard it, never put it in logs.
            shell('am', 'start', '-W', '-a', 'android.intent.action.VIEW',
                  '-d', callback(cfg), '-n', PKG + '/.UuCallbackActivity')
            deadline = time.monotonic() + 45
            uri = None
            while time.monotonic() < deadline and uri is None:
                pid = shell('pidof', PKG, check=False)
                if re.fullmatch(r'\d+', pid):
                    uri = vm_service(adb('logcat', '-d', '--pid=' + pid, '-s', 'flutter:I'))
                if uri is None:
                    time.sleep(0.5)
            require(uri is not None, 'Cold callback did not expose a Dart VM service')
            port = adb('forward', 'tcp:0', f'tcp:{uri.port}')
            require(port.isdigit(), 'Invalid forwarded VM port')
            forward = 'tcp:' + port
            driver += ['--use-existing-app=' + urlunparse(uri._replace(netloc='127.0.0.1:' + port))]
        else:
            driver += ['--use-application-binary=' + str(apk)]
        # Flutter's localhost WebSocket must never go through the user's proxy.
        driver_env = {k: v for k, v in env.items() if k.lower() not in
                      {'http_proxy', 'https_proxy', 'all_proxy'}}
        with (out / f'{phase}.log').open('wb') as log:
            process = subprocess.Popen(driver, cwd=ROOT, env=driver_env,
                                       stdout=log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 480
            handled = set()
            killed = False
            while process.poll() is None and time.monotonic() < deadline:
                gate = private_read('gate')
                if gate in GATES and gate not in handled:
                    handled.add(gate)
                    if gate == 'kill-migrate':
                        require(phase == 'migrate', 'Unexpected kill gate')
                        data = report(private_read('migrate.json'), cfg, phase, 'kill-ready')
                        require(shell('pidof', PKG) == str(data['pid']), 'Wrong process at kill gate')
                        stop()
                        killed = True
                        deadline = time.monotonic() + 20
                        continue
                    if gate.startswith('return-'):
                        expected = PACKAGES['fixture-fakerustdesk' if gate.endswith('rustdesk') else 'fixture-fakeuu']
                        wait_foreground(expected)
                        if gate.startswith('return-migrated-'):
                            fixture_pid = shell('pidof', expected)
                            require(fixture_pid.isdigit(), 'Missing fixture process')
                            rd = gate.endswith('rustdesk')
                            tag = 'ShunFakeRd' if rd else 'ShunFakeUu'
                            trace = adb('logcat', '-d', '--pid=' + fixture_pid, '-s', tag + ':I')
                            marker = ('uri=rustdesk://connect/r39-' + cfg['runId'][:10]
                                      if rd else 'idHash=' + hashlib.sha256(
                                          ('r39-new-' + cfg['runId']).encode()).hexdigest()[:12])
                            requests = [line for line in trace.splitlines()
                                        if ('RECEIVED via=' if rd else 'request control ') in line]
                            require(bool(requests) and marker in requests[-1],
                                    'Fixture did not receive the migrated identity')
                            (out / (gate + '.log')).write_text(trace)
                        shell('am', 'start', '-n', PKG + '/.MainActivity')
                    if gate == 'shot-entries':
                        with (out / 'entries.png').open('wb') as shot:
                            subprocess.run([str(SDK / 'platform-tools/adb'), '-s', SERIAL,
                                            'exec-out', 'screencap', '-p'], stdout=shot, check=True, timeout=20)
                    private_write('ack-' + gate, 'ok')
                time.sleep(0.5)
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=15)
            if phase == 'migrate':
                require(killed, 'No live pending request was force-stopped')
                status = 'kill-ready'
            else:
                require(process.returncode == 0, f'{phase} failed; inspect device log')
                status = 'passed'
        data = report(private_read(f'{phase}.json'), cfg, phase, status)
        (out / f'{phase}.json').write_text(json.dumps(data, indent=2))
        trace = adb('logcat', '-d', '--pid=' + str(data['pid']))
        (out / f'{phase}-app.log').write_text(trace)
        require(not any(marker in trace for marker in sensitive_markers(cfg)),
                'Fixture secret appeared in the host app log')
        return data
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        if forward:
            adb('forward', '--remove', forward, check=False)


def sensitive_markers(cfg):
    run_id = cfg['runId']
    return ['r39-' + run_id[:10], 'r39-old-' + run_id, 'r39-new-' + run_id,
            'r39-' + run_id, base64.urlsafe_b64encode(bytes.fromhex(run_id)).decode().rstrip('='),
            'Zm9v+YmFy/YmF6==']  # fakeUU ID_A from its successful new-entry bind.


def scan_storage(cfg, out):
    command = [str(SDK / 'platform-tools/adb'), '-s', SERIAL, 'exec-out',
               'run-as', PKG, 'tar', '-cf', '-', 'shared_prefs', 'files']
    data = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          check=True, timeout=30).stdout
    require(len(data) < 32 * 1024 ** 2, 'Unexpectedly large fixture storage archive')
    markers = sensitive_markers(cfg)
    files = []
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        for entry in archive:
            if entry.isdir():
                continue
            require(entry.isfile() and entry.size <= 8 * 1024 ** 2,
                    'Unexpected storage member type or size')
            content = archive.extractfile(entry).read()
            require(not any(m.encode() in content for m in markers),
                    f'Plaintext fixture secret in {entry.name}')
            files.append(entry.name)
    require(any('shun_uuremote' in p for p in files)
            and any('shun_rustdesk' in p for p in files), 'Missing encrypted provider files')
    (out / 'storage-scan.json').write_text(json.dumps({
        'passed': True, 'files': files, 'archiveSha256': hashlib.sha256(data).hexdigest()}, indent=2))


def main():
    require(len(sys.argv) == 2 and sys.argv[1] in {'check', 'run'},
            'Usage: python3 tool/r39-device.py check|run')
    env = environment()
    preflight(env, build=sys.argv[1] == 'run')
    if sys.argv[1] == 'check':
        print('PASS: project toolchain and dedicated emulator')
        return
    require(os.environ.get('SHUN_R39_DISPOSABLE') == '1',
            'Set SHUN_R39_DISPOSABLE=1 to authorize test APK installation/data reset')
    for package in PACKAGES.values():
        require(not shell('pm', 'path', package, check=False),
                f'{package} is already installed; refusing to overwrite unknown data')
    out = CHAIN / 'artifacts' / ('r39-device-' + time.strftime('%Y%m%d-%H%M%S'))
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    source_paths = run(['git', 'ls-files', '--', 'lib', 'android', 'plugins',
                       'packages', 'integration_test', 'test_driver', 'pubspec.lock',
                       'pubspec.yaml', 'mise.toml', 'tool/r39-device.py']).splitlines()
    sources = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest()
               for p in source_paths if (ROOT / p).is_file()}
    (out / 'source.json').write_text(json.dumps({
        'head': run(['git', 'rev-parse', 'HEAD']), 'sha256': sources}, indent=2))
    installed = []
    try:
        cfg, defines, apks = build(out, env)
        check_device()
        for module, apk in apks.items():
            require(not shell('pm', 'path', PACKAGES[module], check=False), 'Package appeared during build')
            adb('install', str(apk))
            installed.append((PACKAGES[module], signer(apk, env)))
        require(shell('pm', 'clear', PKG) == 'Success', 'Cannot reset disposable test data')
        shell('run-as', PKG, 'mkdir', '-p', 'files/r39')
        private_write('authorized', cfg['runId'])
        results = [execute_phase(p, cfg, defines, apks['host'], out, env)
                   for p in ('seed', 'migrate', 'cold', 'verify')]
        require(len({r['pid'] for r in results}) == 4, 'Expected four distinct Android processes')
        scan_storage(cfg, out)
        (out / 'result.json').write_text(json.dumps({'passed': True, 'phases': results}, indent=2))
    finally:
        # Only packages installed by this invocation, on the guarded AVD.
        try:
            if installed:
                check_device()
                for package, expected in reversed(installed):
                    require(installed_signer(package, out, env) == expected,
                            'Installed package changed signer; refusing cleanup')
                    adb('uninstall', package)
        finally:
            manifest = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                        for p in out.iterdir() if p.is_file() and p.name != 'manifest.json'}
            (out / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    print(f'PASS: Android fixture migration/callback/UI and package cleanup; evidence: {out}')


if __name__ == '__main__':
    try:
        main()
    except subprocess.SubprocessError:
        print('FAIL: command transport failed; arguments withheld, inspect evidence', file=sys.stderr)
        sys.exit(1)
    except (RuntimeError, OSError, ValueError, tarfile.TarError) as error:
        print(f'FAIL: {error}', file=sys.stderr)
        sys.exit(1)
