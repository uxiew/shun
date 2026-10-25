#!/usr/bin/env python3
"""LIFE06 on the disposable project AVD: is the per-cycle Native Heap growth a leak, or memory that
is only returned after a Dart or Java GC?

How to run (emulator booted on port 5580, lock taken, SSH fixture up; see docs/dev/README.md):

  (cd tool/fixture-environment && ./up.sh)
  SHUN_R39_AVD=shun-r39-a30 python3 tool/life06-device.py view     # or: hidden
  # optional: --cycles 300 --every 50

Runs integration_test/life06_native_heap_test.dart and answers its markers:
  LIFE06 VMSERVICE=<ws url>  adb reverse that port (the test talks to its own VM service for Dart GC)
  LIFE06 MEM <name>          dumpsys meminfo, then files/life06-<name>-done
  LIFE06 JAVAGC <name>       run-as kill -USR1 <pid> (ART: full GC), wait 3 s, dumpsys meminfo, done
Prints Native Heap allocated (mallinfo, what R20/R22 called 已分配) per sample and the least-squares
slope per cycle for each of raw / after Dart GC / after Dart + Java GC, from the first sample after
warm-up (cycle >= --every) on.

Evidence: ../.toolchain/artifacts/life06-<mode>-<time>/ (every meminfo, flutter log, summary.json).
Cleanup: removes the reverses and the define file, uninstalls the test app.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('r39_device', ROOT / 'tool/r39-device.py')
r39 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r39)

TARGET = 'integration_test/life06_native_heap_test.dart'
FIXTURE = ROOT / 'tool/fixture-environment/.run/fixture.json'


def meminfo_numbers(text):
    """Native Heap / Dalvik Heap allocated KiB and TOTAL PSS from `dumpsys meminfo <pkg>`."""
    found = {}
    for line in text.splitlines():
        cols = line.split()
        if line.strip().startswith('Native Heap') and len(cols) >= 10:
            found['nativeAllocKiB'] = int(cols[8])
            found['nativePssKiB'] = int(cols[2])
        elif line.strip().startswith('Dalvik Heap') and len(cols) >= 10:
            found['dalvikAllocKiB'] = int(cols[8])
        elif cols[:1] == ['TOTAL'] and len(cols) >= 2 and 'totalPssKiB' not in found:
            found['totalPssKiB'] = int(cols[1])
    return found


def slope(points):
    if len(points) < 2:
        return None
    mx = sum(x for x, _ in points) / len(points)
    my = sum(y for _, y in points) / len(points)
    den = sum((x - mx) ** 2 for x, _ in points)
    return sum((x - mx) * (y - my) for x, y in points) / den


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['view', 'hidden'])
    parser.add_argument('--cycles', type=int, default=300)
    parser.add_argument('--every', type=int, default=50)
    # 对照：在这一轮采完样后调一次 getAllocationProfile(gc: true)，重现 R20/R22 量法里夹着的那一下。
    parser.add_argument('--profile-at', type=int, default=0)
    args = parser.parse_args()
    env = r39.environment()
    r39.check_device()
    r39.require(FIXTURE.is_file(), 'Start the fixture environment first (tool/fixture-environment/up.sh)')
    fixture = json.loads(FIXTURE.read_text())
    out = r39.CHAIN / 'artifacts' / time.strftime(f'life06-{args.mode}-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    adb = str(r39.SDK / 'platform-tools/adb')
    pkg = r39.PKG

    def adb_run(*a, check=True, timeout=60):
        return subprocess.run([adb, '-s', r39.SERIAL, *a], check=check, timeout=timeout,
                              capture_output=True, text=True, errors='replace')

    def meminfo(name):
        text = adb_run('shell', 'dumpsys', 'meminfo', pkg).stdout
        (out / f'mem-{name}.txt').write_text(text)
        numbers = meminfo_numbers(text)
        samples[name] = numbers
        print(f'LIFE06HOST {name} {json.dumps(numbers)}', flush=True)

    def done(name):
        adb_run('shell', 'run-as', pkg, 'touch', f'files/life06-{name}-done')

    edge = str(fixture['sshEdge']['port'])
    (out / 'device.txt').write_text('\n'.join([
        f'avd={r39.AVD}', f'mode={args.mode}', f'cycles={args.cycles}', f'every={args.every}',
        f'profileAt={args.profile_at}',
        'sdk=' + r39.shell('getprop', 'ro.build.version.sdk'),
        'head=' + subprocess.run(['git', 'rev-parse', '--short', 'HEAD'], cwd=ROOT,
                                 capture_output=True, text=True).stdout.strip(),
    ]) + '\n')
    samples = {}
    reverses = [edge]
    define = None
    code = 1
    proc = None
    try:
        adb_run('uninstall', pkg, check=False)
        adb_run('reverse', f'tcp:{edge}', f'tcp:{edge}')
        adb_run('logcat', '-c', check=False)
        handle, define = tempfile.mkstemp(prefix='life06-define-', suffix='.json')
        with os.fdopen(handle, 'w') as f:
            json.dump({
                'R17_SSH': json.dumps({'port': fixture['sshEdge']['port'], 'user': fixture['user'],
                                       'password': fixture['password'],
                                       'fingerprint': fixture['sshEdge']['fingerprintSha256']}),
                'LIFE06_MODE': args.mode,
                'LIFE06_CYCLES': str(args.cycles),
                'LIFE06_EVERY': str(args.every),
                'LIFE06_PROFILE_AT': str(args.profile_at),
            }, f)
        log = (out / 'flutter-test.log').open('w')
        proc = subprocess.Popen(
            ['flutter', 'test', '--no-pub', TARGET, '-d', r39.SERIAL,
             f'--dart-define-from-file={define}'],
            cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            errors='replace')
        for line in proc.stdout:
            log.write(line)
            log.flush()
            words = line.strip().split()
            if not words or not words[0].startswith('LIFE06'):
                continue
            print(line.rstrip(), flush=True)
            found = re.search(r'LIFE06 VMSERVICE=ws://127\.0\.0\.1:(\d+)', line)
            if found and found.group(1) not in reverses:
                adb_run('reverse', f'tcp:{found.group(1)}', f'tcp:{found.group(1)}')
                reverses.append(found.group(1))
            elif len(words) == 3 and words[1] == 'MEM':
                meminfo(words[2])
                done(words[2])
            elif len(words) == 3 and words[1] == 'JAVAGC':
                pid = adb_run('shell', 'pidof', pkg).stdout.strip()
                adb_run('shell', 'run-as', pkg, 'kill', '-USR1', pid)
                time.sleep(3)
                meminfo(words[2])
                done(words[2])
        code = proc.wait()
        log.close()
        logcat = adb_run('logcat', '-d', check=False, timeout=120).stdout
        (out / 'logcat.txt').write_text(logcat)

        table, slopes = [], {}
        for kind in ['raw', 'dartgc', 'allgc']:
            points = []
            for name, numbers in samples.items():
                m = re.fullmatch(rf'c(\d+)-{kind}', name)
                if m and 'nativeAllocKiB' in numbers:
                    points.append((int(m.group(1)), numbers['nativeAllocKiB']))
                    table.append((int(m.group(1)), kind, numbers))
            steady = [p for p in points if p[0] >= args.every]
            slopes[kind] = slope(steady)
        summary = {
            'mode': args.mode, 'testExit': code,
            'javaGcLogged': logcat.count('SIGUSR1 forcing GC'),
            'nativeAllocSlopeKiBPerCycle': slopes,
            'samples': samples,
        }
        (out / 'summary.json').write_text(json.dumps(summary, indent=2))
        for c, kind, numbers in sorted(table):
            print(f'LIFE06HOST c{c:<4} {kind:<7} native={numbers.get("nativeAllocKiB")} '
                  f'dalvik={numbers.get("dalvikAllocKiB")} pss={numbers.get("totalPssKiB")}')
        print('LIFE06HOST slopes ' + json.dumps(
            {k: (round(v, 2) if v is not None else None) for k, v in slopes.items()}),
              f'javaGcLogged={summary["javaGcLogged"]}', flush=True)
    finally:
        if proc and proc.poll() is None:
            proc.kill()
        if define:
            os.unlink(define)
        for port in reverses:
            adb_run('reverse', '--remove', f'tcp:{port}', check=False)
        adb_run('uninstall', pkg, check=False)
    print(f'life06 exit={code}; evidence in {out}', flush=True)
    return code


if __name__ == '__main__':
    sys.exit(main())
