#!/usr/bin/env python3
"""LIFE06 on the disposable project AVD: is the per-cycle Native Heap growth a leak, or memory that
is only returned after a Dart or Java GC?

How to run (emulator booted on port 5580, lock taken, SSH fixture up; see docs/dev/README.md):

  (cd tool/fixture-environment && ./up.sh)
  SHUN_R39_AVD=shun-r39-a30 python3 tool/life06-device.py view     # or: hidden
  # optional: --cycles 300 --every 50
  # closest to a release build (10-25 reference run):
  SHUN_R39_AVD=shun-r39-a30 python3 tool/life06-device.py view --profile --same-host --timeline-off \
      --cycles 400 --every 100 [--heapprofd 100:400 --flutter-symbols <unstripped libflutter.so>]

  --profile        profile build (AOT, no JIT) via flutter drive, package top.xdwa.shun.profile
  --same-host      reopen one host every cycle (default: a new host id per cycle)
  --timeline-off   stop the Dart timeline first: in debug/profile its recorder keeps one entry per
                   async event id and the engine sends a new id every frame (release: a no-op)
  --heapprofd A:B  record native allocations by call stack from cycle A to B (Android 10+)
  --classdiff      Dart heap: classes that grew between the first sample (or --classdiff-at N)
                   and the end; --retainers auto|Class@lib,... prints who holds them
  --profile-at N   call getAllocationProfile once at cycle N (it leaves ~15-19 MB native behind)

Runs integration_test/life06_native_heap_test.dart and answers its markers:
  LIFE06 VMSERVICE=<ws url>  adb reverse that port (the test talks to its own VM service for Dart GC)
  LIFE06 MEM <name>          dumpsys meminfo, then files/life06-<name>-done
  LIFE06 JAVAGC <name>       run-as kill -USR1 <pid> (ART: full GC), wait 3 s, dumpsys meminfo, done
Prints Native Heap allocated (mallinfo, what R20/R22 called 已分配) per sample and the least-squares
slope per cycle for each of raw / after Dart GC / after Dart + Java GC, from the first sample after
warm-up (cycle >= --every) on.

Evidence: ../.toolchain/artifacts/life06-<mode>-<debug|profile>-<time>/ (every meminfo, flutter log,
summary.json; with --heapprofd also heapprofd.pftrace and heapprofd-summary.txt).
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
# 512 字节采一次（默认 4096）：要找的是每轮几 KiB，采得太疏会被漏掉。block_client：共享内存满了让 App 等，
# 不丢样本（会慢一些）。duration 给足，靠脚本到点 SIGTERM 停，停的时候 heapprofd 写最后一份。
HEAPPROFD_CONFIG = '''
buffers { size_kb: 131072 fill_policy: DISCARD }
data_sources {
  config {
    name: "android.heapprofd"
    target_buffer: 0
    heapprofd_config {
      sampling_interval_bytes: 512
      process_cmdline: "PROCESS"
      shmem_size_bytes: 33554432
      block_client: true
    }
  }
}
duration_ms: 7200000
'''
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
    # 查 Dart 堆里哪些类在涨（这一轮 Native Heap 不算）。
    parser.add_argument('--classdiff', action='store_true')
    # 和 --classdiff 一起：这几个类打引用链，写法同输出里 grew= 的类名@库，逗号分隔。
    parser.add_argument('--retainers', default='')
    # 类快照基线在第几轮取（默认第一个采样点）；等连接记录、服务器监控历史封顶以后再取更干净。
    parser.add_argument('--classdiff-at', type=int, default=0)
    # profile 包（AOT，没有 JIT）：flutter test 不支持 --profile，改用 flutter drive；包名 top.xdwa.shun.profile。
    parser.add_argument('--profile', action='store_true')
    # 每轮连同一台主机；不加时每轮一个新主机 ID（早先几轮的量法）。
    parser.add_argument('--same-host', action='store_true')
    # 关掉 Dart 时间线再量（它在 debug / profile 包里按帧涨，发布包没有）。
    parser.add_argument('--timeline-off', action='store_true')
    # 按调用栈记原生分配（heapprofd，Android 10+，包要可调试）：第 FROM 轮 GC 后开始记、第 TO 轮 GC 后停，
    # 停时还没释放的就是这几轮留下的；用 tool/heapprofd-summary.py 按库、按调用方汇总。
    parser.add_argument('--heapprofd', metavar='FROM:TO')
    # 没裁符号的 libflutter.so（和包里的 Build ID 一致，哪里下见 tool/heapprofd-summary.py）：给了就按函数名汇总。
    parser.add_argument('--flutter-symbols', metavar='LIBFLUTTER_SO')
    args = parser.parse_args()
    env = r39.environment()
    r39.check_device()
    r39.require(FIXTURE.is_file(), 'Start the fixture environment first (tool/fixture-environment/up.sh)')
    fixture = json.loads(FIXTURE.read_text())
    build = 'profile' if args.profile else 'debug'
    out = r39.CHAIN / 'artifacts' / time.strftime(f'life06-{args.mode}-{build}-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    adb = str(r39.SDK / 'platform-tools/adb')
    pkg = 'top.xdwa.shun.profile' if args.profile else r39.PKG

    def adb_run(*a, check=True, timeout=60):
        return subprocess.run([adb, '-s', r39.SERIAL, *a], check=check, timeout=timeout,
                              capture_output=True, text=True, errors='replace')

    def meminfo(name):
        text = adb_run('shell', 'dumpsys', 'meminfo', pkg).stdout
        (out / f'mem-{name}.txt').write_text(text)
        numbers = meminfo_numbers(text)
        samples[name] = numbers
        print(f'LIFE06HOST {name} {json.dumps(numbers)}', flush=True)

    trace_device = '/data/misc/perfetto-traces/life06-heapprofd.pftrace'
    heap = [int(x) for x in args.heapprofd.split(':')] if args.heapprofd else None
    perfetto = None

    def start_heapprofd():
        nonlocal perfetto
        adb_run('shell', 'rm', '-f', trace_device, check=False)
        config = HEAPPROFD_CONFIG.replace('PROCESS', pkg)
        perfetto = subprocess.Popen(
            [adb, '-s', r39.SERIAL, 'shell', 'perfetto', '--txt', '-c', '-', '-o', trace_device],
            stdin=subprocess.PIPE, stdout=(out / 'perfetto.log').open('w'),
            stderr=subprocess.STDOUT, text=True)
        perfetto.stdin.write(config)
        perfetto.stdin.close()
        time.sleep(5)  # 等 heapprofd 接上进程；接上前的分配不记
        print('LIFE06HOST heapprofd started', flush=True)

    def stop_heapprofd():
        adb_run('shell', 'pkill', '-TERM', '-x', 'perfetto', check=False)
        perfetto.wait(timeout=300)
        adb_run('pull', trace_device, str(out / 'heapprofd.pftrace'), timeout=300)
        adb_run('shell', 'rm', '-f', trace_device, check=False)
        symbols = []
        if args.flutter_symbols:
            symbolizer = sorted(r39.SDK.glob('ndk/*/toolchains/llvm/prebuilt/*/bin/llvm-symbolizer'))
            r39.require(symbolizer, 'llvm-symbolizer not found under the SDK ndk/ directory')
            symbols = ['--symbols', f'base.apk!libflutter.so={args.flutter_symbols}',
                       '--symbolizer', str(symbolizer[-1])]
        summary = subprocess.run(
            [sys.executable, str(ROOT / 'tool/heapprofd-summary.py'), str(out / 'heapprofd.pftrace'),
             *symbols], capture_output=True, text=True)
        (out / 'heapprofd-summary.txt').write_text(summary.stdout + summary.stderr)
        print('LIFE06HOST heapprofd stopped; summary in heapprofd-summary.txt', flush=True)

    def done(name):
        adb_run('shell', 'run-as', pkg, 'touch', f'files/life06-{name}-done')

    edge = str(fixture['sshEdge']['port'])
    (out / 'device.txt').write_text('\n'.join([
        f'avd={r39.AVD}', f'mode={args.mode}', f'cycles={args.cycles}', f'every={args.every}',
        f'profileAt={args.profile_at}', f'classdiff={args.classdiff}', f'build={build}', f'sameHost={args.same_host}', f'timelineOff={args.timeline_off}',
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
                'LIFE06_CLASSDIFF': 'true' if args.classdiff else 'false',
                'LIFE06_RETAINERS': args.retainers,
                'LIFE06_CLASSDIFF_AT': str(args.classdiff_at),
                'LIFE06_SAME_HOST': 'true' if args.same_host else 'false',
                'LIFE06_TIMELINE_OFF': 'true' if args.timeline_off else 'false',
            }, f)
        log = (out / 'flutter-test.log').open('w')
        # --no-dds：不加的话测试拿到的 VM service 地址经电脑上的 DDS 绕一圈，连自己时报 Connection refused。
        command = (['flutter', 'drive', '--no-pub', '--profile', '--no-dds',
                    '--driver=test_driver/integration_test.dart', f'--target={TARGET}']
                   if args.profile else ['flutter', 'test', '--no-pub', TARGET])
        proc = subprocess.Popen(
            [*command, '-d', r39.SERIAL, f'--dart-define-from-file={define}'],
            cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            errors='replace')
        for line in proc.stdout:
            log.write(line)
            log.flush()
            # flutter drive 的输出是 logcat 格式，每行前面有 "I/flutter (<pid>): "；从 LIFE06 开始算。
            start = line.find('LIFE06 ')
            if start < 0:
                continue
            words = line[start:].strip().split()
            print(line.rstrip(), flush=True)
            found = re.search(r'LIFE06 VMSERVICE=ws://127\.0\.0\.1:(\d+)', line)
            if found and found.group(1) not in reverses:
                # 报的是电脑这头 DDS 的端口就接回去；是手机上自己的端口时这里会失败，也不用接。
                adb_run('reverse', f'tcp:{found.group(1)}', f'tcp:{found.group(1)}', check=False)
                reverses.append(found.group(1))
            elif len(words) == 3 and words[1] == 'MEM':
                meminfo(words[2])
                done(words[2])
            elif len(words) == 3 and words[1] == 'JAVAGC':
                pid = adb_run('shell', 'pidof', pkg).stdout.strip()
                adb_run('shell', 'run-as', pkg, 'kill', '-USR1', pid)
                time.sleep(3)
                meminfo(words[2])
                if heap and words[2] == f'c{heap[0]}-allgc':
                    start_heapprofd()
                elif heap and words[2] == f'c{heap[1]}-allgc':
                    stop_heapprofd()
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
        if perfetto and perfetto.poll() is None:
            adb_run('shell', 'pkill', '-TERM', '-x', 'perfetto', check=False)
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
