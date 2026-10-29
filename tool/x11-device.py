#!/usr/bin/env python3
"""X11 插件信任与撤销对抗回归，只在项目专用模拟器上跑。

怎么跑（先按 docs/dev/README.md 第 3 节拿锁、开好 emulator-5580；先 plugins/build-fixtures.sh 和编好 Mosh 插件）：

  SHUN_R39_AVD=shun-r39-a30 python3 tool/x11-device.py

和 tool/r39-device.py 拒绝同样的设备（别的 AVD、真机）。会先卸掉模拟器上的 shun 调试包和全部测试插件，
再装 echo-author、echo-debugkey、echo-fakemosh、rogue 和 Mosh 插件，跑 integration_test/plugins/x11_trust_test.dart，
按它打的「X11 ACTION <名字>」装/换/卸包或让 rogue 去打插件，做完用 run-as 在它的私有目录放确认文件。
结束后从 logcat 里挑 rogue 的探测结果：出现 ACCEPTED 就是鉴权有洞，脚本退出码非 0。
证据在 ../.toolchain/artifacts/x11-device-<时间>/：flutter-test.log、logcat-*.txt、host-package.txt、summary.txt。
跑完卸掉调试包和测试插件，模拟器和锁不动。

  SHUN_R39_AVD=shun-r39-a30 python3 tool/x11-device.py x03 <场景>

重跑 X03 的会话场景（integration_test/plugin_session_test.dart）：stream、slowopen、misbehave、stubborn、
version、hostkill。前置插件自动装；hostkill 看到 READY 就强杀宿主，前后各数一次 echo 的 fd。
证据在 ../.toolchain/artifacts/x11-x03-<场景>-<时间>/。kill 场景要 SSH 测试环境，不在这里。
"""
import importlib.util
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('r39_device', ROOT / 'tool/r39-device.py')
r39 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r39)

TARGET = 'integration_test/plugins/x11_trust_test.dart'
HOST = 'top.xdwa.shun.debug'
OUT = ROOT / 'plugins/out'
MOSH_APK = ROOT / 'plugins/mosh/build/outputs/apk/release/mosh-release.apk'
ECHO = 'example.shun.fixture.echo'
FIXTURES = [ECHO, 'example.shun.fixture.echo.debugkey', 'example.shun.fixture.fakemosh',
            'example.shun.fixture.rogue', 'top.xdwa.shun.mosh']
PROBE = 'example.shun.fixture.rogue/.ProbeActivity'


def apk(name):
    path = OUT / f'{name}.apk'
    r39.require(path.is_file(), f'{path} 不在：先跑 plugins/build-fixtures.sh')
    return str(path)


def probe(target, service):
    r39.shell('am', 'start', '-W', '-n', PROBE, '--es', 'target', target, '--es', 'service', service)
    # rogue 探完六个方法自己 finish；等它写完日志。
    time.sleep(6)


# 测试里每个 ACTION 名字对应的 adb 操作。只认这几个，别的名字直接失败。
ACTIONS = {
    'probe-echo': lambda: probe(ECHO, f'{ECHO}.EchoProviderService'),
    'probe-mosh': lambda: probe('top.xdwa.shun.mosh', 'top.xdwa.shun.mosh.MoshProviderService'),
    'install-leaky': lambda: r39.adb('install', '-r', apk('echo-leaky')),
    'install-author': lambda: r39.adb('install', '-r', apk('echo-author')),
    'install-moreperms': lambda: r39.adb('install', '-r', apk('echo-moreperms')),
    'install-morecaps': lambda: r39.adb('install', '-r', apk('echo-morecaps')),
    'install-apimajor2': lambda: r39.adb('install', '-r', apk('echo-apimajor2')),
    'downgrade-author': lambda: r39.adb('install', '-r', '-d', apk('echo-author')),
    'swap-impostor': lambda: (r39.adb('uninstall', ECHO), r39.adb('install', apk('echo-impostor'))),
    'swap-author': lambda: (r39.adb('uninstall', ECHO), r39.adb('install', apk('echo-author'))),
    'uninstall-echo': lambda: r39.adb('uninstall', ECHO),
}


def ack(name):
    r39.shell('run-as', HOST, 'sh', '-c', f'mkdir -p files && touch files/x11-ack-{name}')


X03_TARGET = 'integration_test/plugin_session_test.dart'
X03_SETUP = {
    'stream': ['echo-author'],
    'slowopen': ['echo-slowopen'],
    'misbehave': ['echo-misbehave'],
    'stubborn': ['echo-stubborn', 'echo-debugkey'],
    'version': ['echo-major2'],
    'hostkill': ['echo-author'],
}


def fds(package):
    pid = r39.shell('pidof', package, check=False).strip()
    if not pid:
        return 'no process'
    return r39.shell('run-as', package, 'sh', '-c', f'ls /proc/{pid}/fd | wc -l', check=False).strip()


def x03(scenario):
    r39.require(scenario in X03_SETUP, f'场景只能是 {sorted(X03_SETUP)}')
    env = r39.environment()
    r39.check_device()
    out = r39.CHAIN / 'artifacts' / time.strftime(f'x11-x03-{scenario}-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    for package in [HOST, *FIXTURES]:
        r39.adb('uninstall', package, check=False)
    for name in X03_SETUP[scenario]:
        r39.adb('install', apk(name))
    r39.adb('logcat', '-c')
    notes = []
    log = (out / 'flutter-test.log').open('w')
    proc = subprocess.Popen(
        ['flutter', 'test', '--no-pub', X03_TARGET, '-d', r39.SERIAL,
         f'--dart-define=X03_SCENARIO={scenario}'],
        cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in proc.stdout:
        log.write(line)
        log.flush()
        if 'X03 ' in line:
            print(line.strip(), flush=True)
        if 'X03 hostkill.READY' in line:
            notes.append(f'echo fds before host kill: {fds(ECHO)}')
            # shun-r39-a30 是带 Play 的镜像，SELinux 不让 run-as 发 SIGKILL（X10 查实）；
            # am crash 让宿主真报一次未捕获异常、被系统收掉，对插件来说就是宿主死了。
            r39.shell('am', 'crash', HOST)
            time.sleep(4)
            notes.append(f'host pid after kill: {r39.shell("pidof", HOST, check=False).strip() or "gone"}')
            notes.append(f'echo fds after host kill: {fds(ECHO)}')
    code = proc.wait()
    log.close()
    echo_log = r39.adb('logcat', '-d', '-s', 'ShunEcho', check=False)
    (out / 'logcat-echo.txt').write_text(echo_log + '\n')
    (out / 'logcat-host.txt').write_text(r39.adb('logcat', '-d', '-s', 'ShunPlugins', check=False) + '\n')
    summary = [f'scenario={scenario}', f'flutter test exit={code}', *notes]
    if scenario == 'hostkill':
        summary.append('echo saw host exit=' + str('宿主已退出' in echo_log))
    (out / 'summary.txt').write_text('\n'.join(summary) + '\n')
    print('\n'.join(summary), flush=True)
    for package in [HOST, *FIXTURES]:
        r39.adb('uninstall', package, check=False)
    print(f'evidence in {out}', flush=True)
    # hostkill 的测试本来就是被杀掉的，只看 echo 有没有收尾。
    if scenario == 'hostkill':
        return 0 if '宿主已退出' in echo_log else 1
    return code


def main():
    if sys.argv[1:2] == ['x03']:
        r39.require(len(sys.argv) == 3, '用法：tool/x11-device.py x03 <场景>')
        return x03(sys.argv[2])
    env = r39.environment()
    r39.check_device()
    out = r39.CHAIN / 'artifacts' / time.strftime('x11-device-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    r39.require(MOSH_APK.is_file(), f'{MOSH_APK} 不在：按 plugins/mosh/README.md 编')
    for package in [HOST, *FIXTURES]:
        r39.adb('uninstall', package, check=False)
    for name in ['echo-author', 'echo-debugkey', 'echo-fakemosh', 'rogue']:
        r39.adb('install', apk(name))
    r39.adb('install', str(MOSH_APK))
    (out / 'device.txt').write_text('\n'.join([
        f'avd={r39.AVD}',
        'sdk=' + r39.shell('getprop', 'ro.build.version.sdk'),
        'fingerprint=' + r39.shell('getprop', 'ro.build.fingerprint'),
    ]) + '\n')
    r39.adb('logcat', '-c')
    log = (out / 'flutter-test.log').open('w')
    # --no-uninstall：跑完还要看宿主申请了哪些权限，脚本最后自己卸。
    proc = subprocess.Popen(
        ['flutter', 'test', '--no-pub', '--no-uninstall', TARGET, '-d', r39.SERIAL],
        cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    failed_action = None
    for line in proc.stdout:
        log.write(line)
        log.flush()
        text = line.strip()
        if 'X11 ' not in text:
            continue
        print(text, flush=True)
        marker = text[text.index('X11 '):].split()
        if len(marker) == 3 and marker[1] == 'ACTION':
            name = marker[2]
            try:
                ACTIONS[name]()
                ack(name)
                log.write(f'[x11-device] action {name} done\n')
            except Exception as error:  # noqa: BLE001 — 记下来，让测试等超时失败
                failed_action = f'{name}: {error}'
                log.write(f'[x11-device] action {name} FAILED: {error}\n')
    code = proc.wait()
    log.close()

    tags = {'rogue': 'ShunRogue', 'echo': 'ShunEcho', 'host': 'ShunPlugins', 'mosh': 'ShunMosh'}
    for name, tag in tags.items():
        (out / f'logcat-{name}.txt').write_text(r39.adb('logcat', '-d', '-s', tag, check=False) + '\n')
    rogue_log = (out / 'logcat-rogue.txt').read_text()
    probes = [l for l in rogue_log.splitlines() if 'PROBE ' in l]
    accepted = [l for l in probes if 'ACCEPTED' in l]
    package_dump = r39.shell('dumpsys', 'package', HOST, check=False)
    (out / 'host-package.txt').write_text(package_dump + '\n')
    summary = [
        f'flutter test exit={code}',
        f'failed action={failed_action}',
        f'rogue probes={len(probes)} accepted={len(accepted)}',
        *[f'  {l.split("PROBE ", 1)[1]}' for l in probes],
        'host requests QUERY_ALL_PACKAGES=' + str('android.permission.QUERY_ALL_PACKAGES' in package_dump),
        'host sharedUserId=' + str('sharedUser=' in package_dump and 'sharedUser=null' not in package_dump),
    ]
    (out / 'summary.txt').write_text('\n'.join(summary) + '\n')
    print('\n'.join(summary), flush=True)

    for package in [HOST, *FIXTURES]:
        r39.adb('uninstall', package, check=False)
    print(f'evidence in {out}', flush=True)
    # rogue 应该一共探 12 次（两个插件各 6 个方法），少了说明没探到，不算过。
    ok = code == 0 and failed_action is None and len(probes) == 12 and not accepted
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
