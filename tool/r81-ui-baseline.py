#!/usr/bin/env python3
"""R81 profile baseline on the locked, disposable project AVD.

Build once, then run bounded stages against the SAME APK and unchanged fixture:
  SHUN_R39_AVD=shun-r39-a30 python3 tool/r81-ui-baseline.py build --output build/r81-profile
  SHUN_R39_AVD=shun-r39-a30 python3 tool/r81-ui-baseline.py run --build-dir build/r81-profile --stage lists
  SHUN_R39_AVD=shun-r39-a30 python3 tool/r81-ui-baseline.py run --build-dir build/r81-profile --stage panels
  SHUN_R39_AVD=shun-r39-a30 python3 tool/r81-ui-baseline.py run --build-dir build/r81-profile --stage terminal
  SHUN_R39_AVD=shun-r39-a30 python3 tool/r81-ui-baseline.py run --build-dir build/r81-profile --stage lifecycle
  python3 tool/r81-ui-baseline.py summarize --build-dir build/r81-profile

For a short wiring check: build --smoke into another directory, then run --stage all.
Smoke is explicitly NOT a baseline. Formal 5s/30s/3 repetitions and 100 cycles
cannot be shortened by command-line flags. Each stage starts a fresh process,
seeds 100 hosts and four real fixture SSH PTYs with 5 MiB of VT, then disposes them.
No emulator, Docker environment, or global toolchain is started or reconfigured.
Only top.xdwa.shun.profile is installed/cleared on the verified project emulator.
"""
import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import queue
import re
import shlex
import shutil
import statistics
import subprocess
import sys
import threading
import time
import uuid
import zipfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
PKG = 'top.xdwa.shun.profile'
TARGET = 'integration_test/r81_ui_baseline_test.dart'
FIXTURE = ROOT / 'tool/fixture-environment/.run/fixture.json'
STAGES = {
    'lists': ['settings-scroll', 'hosts-scroll'],
    'panels': ['host-editor', 'tailscale-nonmodal', 'input-panel'],
    'terminal': ['tabs', 'vt-overview'],
    'lifecycle': [],
}


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


r39 = module('r81_r39', ROOT / 'tool/r39-device.py')
life06 = module('r81_life06', ROOT / 'tool/life06-device.py')
require = r39.require


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as file:
        for block in iter(lambda: file.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def json_write(path, value):
    Path(path).write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')


def build_path(value):
    path = Path(value)
    path = (path if path.is_absolute() else ROOT / path).resolve()
    require(path.is_relative_to((ROOT / 'build').resolve()),
            'Evidence must stay inside this repository build/ directory')
    return path


def inputs():
    roots = ['lib', 'android', 'assets', 'pubspec.yaml', 'pubspec.lock',
             'mise.toml', 'analysis_options.yaml',
             'packages/plugin_api/lib', 'packages/plugin_api/pubspec.yaml',
             'third_party/libghostty/pubspec.yaml',
             'third_party/libghostty/packages/flterm/lib',
             'third_party/libghostty/packages/flterm/pubspec.yaml',
             'third_party/libghostty/packages/libghostty/lib',
             'third_party/libghostty/packages/libghostty/hook',
             'third_party/libghostty/packages/libghostty/pubspec.yaml',
             'third_party/libghostty/packages/libghostty/ghostty.version',
             'third_party/libghostty/packages/libghostty/ghostty.sha256']
    tracked = r39.run(['git', 'ls-files', '-z', '--', *roots]).split('\0')
    paths = {name for name in tracked if name and (ROOT / name).is_file()}
    paths.update([TARGET, 'tool/r81-ui-baseline.py', 'tool/r39-device.py',
                  'tool/life06-device.py', 'test_driver/integration_test.dart'])
    return {name: sha(ROOT / name) for name in sorted(paths)}


def fixture():
    require(FIXTURE.is_file(),
            'Start tool/fixture-environment once before building; keep it unchanged')
    value = json.loads(FIXTURE.read_text())
    require(value['sshEdge']['port'] == 22201, 'Expected the local ssh-edge fixture')
    require(isinstance(value['password'], str) and value['password'],
            'Fixture password is missing')
    return value


def device():
    def read(*args):
        return r39.shell(*args)
    return {
        'avd': r39.AVD, 'serial': r39.SERIAL,
        'api': read('getprop', 'ro.build.version.sdk'),
        'abi': read('getprop', 'ro.product.cpu.abi'),
        'model': read('getprop', 'ro.product.model'),
        'buildFingerprint': read('getprop', 'ro.build.fingerprint'),
        'pageSize': read('getconf', 'PAGE_SIZE'),
        'wmSize': read('wm', 'size'),
        'wmDensity': read('wm', 'density'),
        'systemFontScale': read('settings', 'get', 'system', 'font_scale'),
        'systemLocale': read('getprop', 'persist.sys.locale'),
    }


def preflight():
    env = r39.environment()
    r39.preflight(env, build=True)
    lock = r39.CHAIN / 'locks/emulator/owner'
    require(lock.is_file(), 'Acquire the project emulator lock before running')
    return env


def sdk(env):
    flutter = json.loads(r39.run(['flutter', '--version', '--machine'], env=env))
    required = ('frameworkVersion', 'frameworkRevision', 'engineRevision', 'dartSdkVersion')
    require(all(isinstance(flutter.get(key), str) and flutter[key] for key in required),
            'Flutter machine version response is incomplete')
    # Human --version includes relative ages ("4 weeks ago"), which change
    # across days without any SDK change. Compare stable identities only.
    stable = {key: flutter[key] for key in required}
    for key in ('channel', 'engineContentHash', 'devToolsVersion'):
        if flutter.get(key) is not None:
            stable[key] = flutter[key]
    return {
        'flutter': stable,
        'zig': r39.run([env['SHUN_ZIG_EXECUTABLE'], 'version'], env=env),
    }


def build(args):
    env = preflight()
    conf = fixture()
    out = build_path(args.output or
                     time.strftime('build/r81-profile-%Y%m%d-%H%M%S'))
    require(not out.exists(), 'Use a new output directory; preserve earlier evidence')
    out.mkdir(parents=True)
    run_id = uuid.uuid4().hex
    definitions = out / 'temporary-defines.json'
    metadata = {
        'format': 'shun-r81-build-v1',
        'runId': run_id,
        'mode': 'smoke-not-baseline' if args.smoke else 'baseline',
        'head': r39.run(['git', 'rev-parse', 'HEAD']),
        'branch': r39.run(['git', 'branch', '--show-current']),
        'dirty': r39.run(['git', 'status', '--porcelain']),
        'sourceFiles': inputs(),
        'fixtureSha256': sha(FIXTURE),
        'device': device(),
        'sdk': sdk(env),
        'package': PKG,
        'completed': False,
    }
    require(metadata['device']['abi'] == 'arm64-v8a',
            'This fixed baseline expects the existing arm64 project AVD')
    metadata['sourceSha256'] = hashlib.sha256(
        json.dumps(metadata['sourceFiles'], sort_keys=True).encode()).hexdigest()
    metadata['lockSha256'] = sha(ROOT / 'pubspec.lock')
    metadata['runnerSha256'] = sha(__file__)
    metadata['testSha256'] = sha(ROOT / TARGET)
    json_write(out / 'build.json', metadata)
    fd = os.open(definitions, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, 'w') as handle:
        json.dump({
            'R81_RUN_ID': run_id,
            'R81_SMOKE': 'true' if args.smoke else 'false',
            'R81_FIXTURE': json.dumps({
                'port': conf['sshEdge']['port'],
                'user': conf['user'],
                'password': conf['password'],
                'fingerprint': conf['sshEdge']['fingerprintSha256'],
            }),
        }, handle)
    command = ['flutter', 'build', 'apk', '--profile', '--no-pub',
               '--target-platform=android-arm64', f'--target={TARGET}',
               f'--dart-define-from-file={definitions}']
    metadata['buildFlags'] = command[1:-1] + ['--dart-define-from-file=<temporary>']
    try:
        with (out / 'build.log').open('w') as log:
            result = subprocess.run(command, cwd=ROOT, env=env, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=570)
        metadata['buildExit'] = result.returncode
        require(result.returncode == 0, f'Build failed; inspect {out / "build.log"}')
        require(inputs() == metadata['sourceFiles'], 'Source changed while building')
        apk = out / 'baseline-profile.apk'
        shutil.copyfile(ROOT / 'build/app/outputs/flutter-apk/app-profile.apk', apk)
        require(r39.apk_package(apk, env) == PKG, 'Refusing any other applicationId')
        metadata.update(apkSha256=sha(apk), signerSha256=r39.signer(apk, env),
                        completed=True)
        # The native hook can reuse a previously compiled library. Fingerprint
        # the actual packaged libraries as well as the pinned source inputs.
        with zipfile.ZipFile(apk) as package:
            metadata['packagedNativeSha256'] = {
                name: hashlib.sha256(package.read(name)).hexdigest()
                for name in package.namelist()
                if name.startswith('lib/arm64-v8a/') and name.endswith('.so')
            }
    except subprocess.TimeoutExpired:
        metadata['buildExit'] = 'timeout-after-570s'
        raise RuntimeError('Build exceeded 570s; evidence/cache remain, no test was run') from None
    finally:
        definitions.unlink(missing_ok=True)
        # No fixture password is retained in the build transcript.
        log_path = out / 'build.log'
        if log_path.exists():
            log_path.write_text(log_path.read_text(errors='replace')
                                .replace(conf['password'], '<fixture-password>'))
        json_write(out / 'build.json', metadata)
    print(f'R81 build complete: {out}', flush=True)
    return 0


def load_build(path):
    out = build_path(path)
    metadata = json.loads((out / 'build.json').read_text())
    require(metadata.get('completed') is True, 'The profile build is incomplete')
    require(metadata['package'] == PKG, 'Not an R81 profile artifact')
    apk = out / 'baseline-profile.apk'
    require(sha(apk) == metadata['apkSha256'], 'APK changed after the build')
    return out, metadata, apk


def percentile(values):
    return sorted(values)[max(0, math.ceil(len(values) * .95) - 1)] / 1000


def validate_stage(out, build_info, stage, native):
    manifest = json.loads((out / 'manifest.json').read_text())
    smoke = build_info['mode'] == 'smoke-not-baseline'
    expected_scenes = sum(STAGES.values(), []) if stage == 'all' else STAGES[stage]
    repetitions, seconds, warm = (1, 3, 1) if smoke else (3, 30, 5)
    cycles = (3 if smoke else 100) if stage in ('all', 'lifecycle') else 0
    for key, value in {
        'runId': build_info['runId'], 'mode': build_info['mode'],
        'stage': stage, 'profile': True, 'completed': True,
        'framePolicy': 'benchmarkLive', 'timelineStreams': [],
        'repetitions': repetitions, 'sampleSeconds': seconds,
        'warmupSeconds': warm, 'cycles': cycles,
        'hostCount': 100, 'activeSessions': 4,
        'corpusTotalBytes': 5 * 1024 * 1024,
        'allSessionEnginesReleased': True,
    }.items():
        require(manifest.get(key) == value, f'Unexpected manifest {key}')
    expected = {(name, rep) for name in expected_scenes
                for rep in range(1, repetitions + 1)}
    require({(run['scene'], run['repetition']) for run in manifest['runs']} == expected,
            'Missing or extra scene repetitions')
    require(len(manifest['runs']) == len(expected), 'Repeated scene record')
    require(set(native) == set(manifest['memory']), 'Missing native or Dart memory sample')
    raw_files, runs = {}, []
    for run in manifest['runs']:
        name = f'{run["scene"]}-{run["repetition"]}.frames.json'
        record = json.loads((out / name).read_text())
        frames = record['frameTimings']
        require(len(frames) == run['frames'] and len(frames) > 1,
                'Missing raw frames')
        require(record['measuredSeconds'] >= seconds,
                'Short capture cannot be a baseline')
        require(record['traceKind'] == 'raw-frame-records-not-vm-timeline',
                'Unexpected trace format')
        require(all(record['windowStartUs'] <= frame['vsyncStartUs']
                    < record['windowEndUs'] for frame in frames),
                'Frames outside the measured window')
        budget = 1000000 / record['refreshHz']
        measured = {
            'buildP95Ms': percentile([frame['buildUs'] for frame in frames]),
            'rasterP95Ms': percentile([frame['rasterUs'] for frame in frames]),
            'jankRatio': sum(frame['buildUs'] > budget or frame['rasterUs'] > budget
                             for frame in frames) / len(frames),
        }
        for key, value in measured.items():
            require(math.isclose(value, run[key], rel_tol=1e-8, abs_tol=1e-8),
                    f'Raw frame summary disagrees: {key}')
        raw_files[name] = sha(out / name)
        runs.append({**run, **measured})
    if cycles:
        require(manifest['resourceCycles'][-1]['cycle'] == cycles,
                'Lifecycle cycles are incomplete')
        require(all(row['sessions'] == 4 and row['closedEnginesNotReleased'] == 0
                    and row['closedActiveViews'] == 0
                    for row in manifest['resourceCycles']),
                'A closed native engine or view remains active')
    medians = {
        scene: {key: statistics.median(run[key] for run in runs if run['scene'] == scene)
                for key in ('buildP95Ms', 'rasterP95Ms', 'jankRatio')}
        for scene in expected_scenes
    }
    memory = {name: {'dart': value, 'android': native[name]}
              for name, value in manifest['memory'].items()}
    return {'completed': True, 'mode': manifest['mode'], 'stage': stage,
            'runs': runs, 'medianOfRuns': medians, 'memory': memory,
            'resourceCycles': manifest['resourceCycles'],
            'manifestSha256': sha(out / 'manifest.json'),
            'frameFilesSha256': raw_files}


def run_stage(args):
    env = preflight()
    conf = fixture()
    build_dir, build_info, apk = load_build(args.build_dir)
    stage = args.stage
    require(stage != 'all' or build_info['mode'] == 'smoke-not-baseline',
            'Formal baseline uses lists/panels/terminal/lifecycle in separate commands')
    require(inputs() == build_info['sourceFiles'],
            'Source or harness changed after build; build a new candidate APK')
    require(sha(FIXTURE) == build_info['fixtureSha256'],
            'Fixture changed after build; do not mix runs or use stale credentials')
    require(r39.apk_package(apk, env) == PKG, 'Refusing any other applicationId')
    current_device, current_sdk = device(), sdk(env)
    require(current_device == build_info['device'], 'Device configuration changed')
    require(current_sdk == build_info['sdk'], 'SDK changed after build')
    out = build_dir / stage
    require(not out.exists(), 'Preserve earlier stage evidence; use a new build directory')
    out.mkdir()
    adb = str(r39.SDK / 'platform-tools/adb')

    def adb_run(*argv, check=True, timeout=45, input=None):
        result = subprocess.run([adb, '-s', r39.SERIAL, *argv], cwd=ROOT,
                                capture_output=True, text=True, input=input,
                                timeout=timeout, errors='replace')
        require(not check or result.returncode == 0,
                'ADB command failed; arguments withheld')
        return result.stdout

    stage_meta = {
        'stage': stage, 'runId': build_info['runId'], 'apkSha256': sha(apk),
        'sourceSha256': build_info['sourceSha256'],
        'fixtureSha256': sha(FIXTURE), 'sdk': current_sdk,
        'device': current_device, 'startedUtc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'completed': False,
    }
    json_write(out / 'environment.json', stage_meta)
    (out / 'display.txt').write_text(adb_run('shell', 'dumpsys', 'display'))
    native, extracted = {}, []
    reverse_created, proc = False, None
    vm_reverses = []
    code, failure = 1, None
    command = [
        'flutter', 'drive', '--no-pub', '--profile', '--no-dds',
        '--driver=test_driver/integration_test.dart', f'--target={TARGET}',
        f'--use-application-binary={apk}', '-d', r39.SERIAL,
    ]
    stage_meta['driveFlags'] = command[1:]
    try:
        existing = adb_run('reverse', '--list')
        pairs = [line.split()[-2:] for line in existing.splitlines() if line.strip()]
        edge = f'tcp:{conf["sshEdge"]["port"]}'
        for local, remote in pairs:
            if local == edge:
                require(remote == edge, 'Fixture port is forwarded elsewhere')
        if not any(local == edge for local, _ in pairs):
            adb_run('reverse', edge, edge)
            reverse_created = True
        adb_run('uninstall', PKG, check=False)
        proc = subprocess.Popen(command, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, bufsize=1,
                                errors='replace')
        lines = queue.Queue()

        def reader():
            for line in proc.stdout:
                lines.put(line)
            lines.put(None)

        threading.Thread(target=reader, daemon=True).start()
        started = time.monotonic()
        with (out / 'flutter-drive.log').open('w') as log:
            while True:
                require(time.monotonic() - started < 540,
                        'Stage exceeded 540s; partial evidence retained')
                try:
                    line = lines.get(timeout=1)
                except queue.Empty:
                    continue
                if line is None:
                    break
                safe = line.replace(conf['password'], '<fixture-password>')
                log.write(safe)
                log.flush()
                if 'R81 ' in safe or 'Error' in safe or 'failed' in safe:
                    print(safe.rstrip(), flush=True)
                found = re.search(r'R81 (CONFIG|VMPORT|FILE|MEM|JAVAGC) ([a-z0-9.-]+)\s*$', line)
                if not found:
                    continue
                verb, name = found.groups()
                if verb == 'CONFIG':
                    require(name == 'run', 'Unexpected configuration gate')
                    script = 'cat > files/r81/config.json'
                    adb_run('shell', shlex.join(['run-as', PKG, 'sh', '-c', script]),
                            input=json.dumps({'stage': stage}))
                elif verb == 'VMPORT':
                    require(name.isdigit() and 1024 <= int(name) <= 65535,
                            'Unexpected VM service port')
                    endpoint = f'tcp:{name}'
                    require(endpoint != edge, 'VM and SSH ports must differ')
                    current = adb_run('reverse', '--list')
                    mappings = [row.split()[-2:] for row in current.splitlines() if row.strip()]
                    owned = [remote for local, remote in mappings if local == endpoint]
                    require(not owned or owned == [endpoint], 'VM port is forwarded elsewhere')
                    if not owned:
                        # With --no-dds this can already be the device-local VM
                        # port, so bind failure is expected and direct connect
                        # remains authoritative (the same behavior as LIFE06).
                        bridge = subprocess.run(
                            [adb, '-s', r39.SERIAL, 'reverse', endpoint, endpoint],
                            capture_output=True, text=True, timeout=30)
                        if bridge.returncode == 0:
                            vm_reverses.append(endpoint)
                        stage_meta['vmReverseExit'] = bridge.returncode
                elif verb == 'FILE':
                    require(name.endswith('.json'), 'Unexpected evidence file')
                    raw = adb_run('exec-out', 'run-as', PKG, 'cat', f'files/r81/{name}')
                    json.loads(raw)  # Fail before acknowledging a partial transfer.
                    (out / name).write_text(raw)
                    extracted.append(name)
                else:
                    if verb == 'JAVAGC':
                        pid = adb_run('shell', 'pidof', PKG).strip()
                        require(re.fullmatch(r'[0-9]+', pid) is not None,
                                'Expected exactly one profile app process')
                        adb_run('shell', 'run-as', PKG, 'kill', '-USR1', pid)
                        time.sleep(3)
                    raw = adb_run('shell', 'dumpsys', 'meminfo', PKG)
                    (out / f'mem-{name}.txt').write_text(raw)
                    numbers = life06.meminfo_numbers(raw)
                    require({'nativeAllocKiB', 'nativePssKiB', 'totalPssKiB'} <= numbers.keys(),
                            'Android native/process memory sample is incomplete')
                    native[name] = numbers
                    json_write(out / 'native-memory.json', native)
                adb_run('shell', 'run-as', PKG, 'touch',
                        f'files/r81/ack-{verb.lower()}-{name}')
        code = proc.wait(timeout=30)
        require(code == 0, 'flutter drive failed; partial evidence retained')
        summary = validate_stage(out, build_info, stage, native)
        json_write(out / 'summary.json', summary)
        stage_meta['completed'] = True
    except Exception as error:
        failure = str(error).replace(conf['password'], '<fixture-password>')
        print(f'R81 stage failed: {failure}', file=sys.stderr, flush=True)
        code = 1
    finally:
        if proc and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=10)
        cleanup = {}
        try:
            # Never send cleanup to a different device after an adb reconnect.
            r39.check_device()

            def clean(name, *argv):
                result = subprocess.run(
                    [adb, '-s', r39.SERIAL, *argv], capture_output=True,
                    text=True, timeout=45, errors='replace')
                cleanup[name] = {
                    'returncode': result.returncode,
                    'stdout': result.stdout.strip(),
                    'stderr': result.stderr.strip(),
                }
                return result

            removed = []
            if reverse_created:
                endpoint = f'tcp:{conf["sshEdge"]["port"]}'
                removed.append(clean('reverse-' + endpoint, 'reverse', '--remove', endpoint))
            for endpoint in vm_reverses:
                removed.append(clean('reverse-' + endpoint, 'reverse', '--remove', endpoint))
            before = clean('before-packages', 'shell', 'pm', 'list', 'packages', PKG)
            before_lines = before.stdout.splitlines()
            require(before.returncode == 0 and not before.stderr.strip() and
                    all(line.startswith('package:') for line in before_lines),
                    'Cannot establish package state before cleanup')
            if f'package:{PKG}' in before_lines:
                uninstall = clean('uninstall', 'uninstall', PKG)
                uninstall_ok = (uninstall.returncode == 0 and
                                uninstall.stdout.strip() == 'Success' and
                                not uninstall.stderr.strip())
            else:
                # flutter drive normally removes this package itself. Do not
                # issue another uninstall against a verified absent package.
                cleanup['uninstall'] = {
                    'skipped': True, 'reason': 'target-package-already-absent',
                    'returncode': None, 'stdout': '', 'stderr': '',
                }
                uninstall_ok = True
            remaining = clean('final-packages', 'shell', 'pm', 'list', 'packages', PKG)
            paths = clean('final-pm-path', 'shell', 'pm', 'path', PKG)
            absent = (remaining.returncode == 0 and
                      not remaining.stdout.strip() and not remaining.stderr.strip() and
                      paths.returncode in (0, 1) and
                      not paths.stdout.strip() and not paths.stderr.strip())
            # Android 11 returns rc=1 with empty stdout/stderr for an absent
            # package. Accept that only alongside a successful empty list;
            # transport, permissions and PackageManager errors remain failures.
            package_clean = absent and uninstall_ok
            cleanup_complete = package_clean and all(item.returncode == 0 for item in removed)
        except Exception as error:
            cleanup['error'] = str(error)
            cleanup_complete = False
        stage_meta['cleanup'] = cleanup
        stage_meta['cleanupComplete'] = cleanup_complete
        if not cleanup_complete:
            code = 1
            failure = failure or 'Cleanup incomplete; inspect environment.json before retrying'
            stage_meta['completed'] = False
        summary_file = out / 'summary.json'
        if summary_file.is_file():
            measured = json.loads(summary_file.read_text())
            measured['cleanupComplete'] = cleanup_complete
            measured['completed'] = stage_meta['completed']
            json_write(summary_file, measured)
        stage_meta.update(exitCode=code, failure=failure, extracted=extracted)
        json_write(out / 'environment.json', stage_meta)
    print(f'R81 {stage} exit={code}; evidence: {out}', flush=True)
    return code


def summarize(args):
    out, build_info, _ = load_build(args.build_dir)
    smoke = build_info['mode'] == 'smoke-not-baseline'
    stages = ['all'] if smoke else list(STAGES)
    combined = {'mode': build_info['mode'], 'apkSha256': build_info['apkSha256'],
                'sourceSha256': build_info['sourceSha256'],
                'fixtureSha256': build_info['fixtureSha256'],
                'stageProcessBoundary': 'separate fresh processes with identical seeds',
                'stages': {}, 'completed': True}
    reference_view = None
    for stage in stages:
        directory = out / stage
        meta = json.loads((directory / 'environment.json').read_text())
        require(meta.get('completed') is True and meta['exitCode'] == 0 and
                meta.get('cleanupComplete') is True,
                f'Stage {stage} is not complete')
        for key in ('apkSha256', 'sourceSha256', 'fixtureSha256', 'device', 'sdk'):
            require(meta[key] == build_info[key], f'Stage {stage} changed {key}')
        summary = validate_stage(directory, build_info, stage,
                                 json.loads((directory / 'native-memory.json').read_text()))
        manifest = json.loads((directory / 'manifest.json').read_text())
        viewport = {key: manifest[key] for key in
                    ('logicalSize', 'devicePixelRatio', 'textScaleAt14', 'refreshHz',
                     'theme', 'language', 'terminalFontSize',
                     'scrollbackMaxLines', 'scrollbackMaxBytes')}
        if reference_view is None:
            reference_view = viewport
        require(viewport == reference_view, f'Stage {stage} viewport/font/theme changed')
        combined['stages'][stage] = summary
    combined['view'] = reference_view
    combined['baselineCaptured'] = not smoke
    combined['scope'] = 'emulator profile regression evidence, not real-phone smoothness'
    combined['notMeasured'] = manifest['notMeasured']
    json_write(out / 'summary.json', combined)
    print(f'R81 {"smoke only" if smoke else "baseline captured"}: {out / "summary.json"}',
          flush=True)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    actions = parser.add_subparsers(dest='action', required=True)
    build_parser = actions.add_parser('build')
    build_parser.add_argument('--smoke', action='store_true')
    build_parser.add_argument('--output')
    run_parser = actions.add_parser('run')
    run_parser.add_argument('--build-dir', required=True)
    run_parser.add_argument('--stage', required=True, choices=['all', *STAGES])
    summary_parser = actions.add_parser('summarize')
    summary_parser.add_argument('--build-dir', required=True)
    args = parser.parse_args()
    try:
        return {'build': build, 'run': run_stage, 'summarize': summarize}[args.action](args)
    except Exception as error:
        print(f'R81 stopped: {error}', file=sys.stderr, flush=True)
        return 1


if __name__ == '__main__':
    sys.exit(main())
