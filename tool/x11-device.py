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

  SHUN_R39_AVD=shun-r39-a30 python3 tool/x11-device.py intents <包名>

别的 App 能做的：显式启动 MainActivity，带 FlutterActivity 会读的 extras（cached_engine_id、route……）和 data。
先冷启动、再对已在运行的各发一次，看进程还在不在、crash 缓冲区里有没有它。要先装好那个包（release 包是
 top.xdwa.shun）。修之前 release 包冷启动会崩：The requested cached FlutterEngine did not exist。
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
    # 只数个数分不出「会话 socket 没关」和「多了一个别的」：按指向的类型分组。
    listing = r39.shell('run-as', package, 'sh', '-c',
                        f'for f in /proc/{pid}/fd/*; do readlink $f; done', check=False)
    kinds = {}
    for target in listing.split():
        kind = target.split(':', 1)[0] if ':' in target else target.rsplit('/', 1)[0]
        kinds[kind] = kinds.get(kind, 0) + 1
    return f'{sum(kinds.values())} {dict(sorted(kinds.items()))}'


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


def run_marked(target, actions, out, env, *, keep_host=False):
    """跑一个打「X11 ACTION <名字>」的设备测试，照 actions 做完就放确认文件。返回 (退出码, 失败的动作)。"""
    log = (out / 'flutter-test.log').open('w')
    args = ['flutter', 'test', '--no-pub', target, '-d', r39.SERIAL]
    if keep_host:
        args.insert(3, '--no-uninstall')
    proc = subprocess.Popen(args, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)
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
                actions[name]()
                ack(name)
                log.write(f'[x11-device] action {name} done\n')
            except Exception as error:  # noqa: BLE001 — 记下来，让测试等超时失败
                failed_action = f'{name}: {error}'
                log.write(f'[x11-device] action {name} FAILED: {error}\n')
    code = proc.wait()
    log.close()
    return code, failed_action


UU = 'com.netease.uuremote'
HIJACKER = 'example.shun.fixture.fakeuu'


def uu_mode(mode):
    # 不带 -W：设模式的页面存完就 finish，am 等不到「启动完成」，会一直等到 adb 超时。
    r39.shell('am', 'start', '-n', f'{UU}/{HIJACKER}.ModeActivity', '--es', 'mode', mode)
    time.sleep(2)


def forge(uri):
    # 和任何一个 App 能发的一样：隐式 VIEW，系统按 scheme 交给声明了它的 Activity。
    r39.shell('am', 'start', '-W', '-a', 'android.intent.action.VIEW', '-d', uri)
    time.sleep(1.5)


UU_ACTIONS = {
    'forge-nopending': lambda: forge(
        'shun-uuremote://callback/bind?state=AAAAAAAAAAAAAAAAAAAAAA&anonymous_device_id=x&nonce=y'),
    'forge-malformed': lambda: forge(
        'shun-uuremote://callback/../bind?state=%00%0a&state=B&nonce=' + 'z' * 4000),
    'mode-bind_twice': lambda: uu_mode('bind_twice'),
    'mode-bind_wrong_nonce': lambda: uu_mode('bind_wrong_nonce'),
    'install-hijack': lambda: r39.adb('install', apk('fakeuu-hijack')),
    'uninstall-hijack': lambda: r39.adb('uninstall', HIJACKER),
}


def uu():
    env = r39.environment()
    r39.check_device()
    out = r39.CHAIN / 'artifacts' / time.strftime('x11-uu-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    for package in [HOST, UU, HIJACKER]:
        r39.adb('uninstall', package, check=False)
    r39.adb('install', apk('fakeuu'))
    r39.adb('logcat', '-c')
    code, failed_action = run_marked('integration_test/plugins/x11_uu_test.dart', UU_ACTIONS, out, env)
    (out / 'logcat-fakeuu.txt').write_text(r39.adb('logcat', '-d', '-s', 'ShunFakeUu', check=False) + '\n')
    summary = [f'flutter test exit={code}', f'failed action={failed_action}']
    (out / 'summary.txt').write_text('\n'.join(summary) + '\n')
    print('\n'.join(summary), flush=True)
    for package in [HOST, UU, HIJACKER]:
        r39.adb('uninstall', package, check=False)
    print(f'evidence in {out}', flush=True)
    return 0 if code == 0 and failed_action is None else 1


PAYLOAD = ['--es', 'route', '/settings/plugins', '--es', 'cached_engine_id', 'evil',
           '--es', 'background_mode', 'transparent', '--es', 'dart_entrypoint_args', 'x',
           '--ez', 'enable_state_restoration', 'false', '-d', 'https://evil.example/plugins?approve=1']


def intents(package):
    r39.check_device()
    out = r39.CHAIN / 'artifacts' / time.strftime('x11-intents-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    r39.require(r39.shell('pm', 'path', package, check=False).startswith('package:'), f'{package} 没装')
    r39.shell('am', 'force-stop', package)
    r39.adb('logcat', '-b', 'crash', '-c', check=False)
    lines = []
    for round_ in ['cold', 'warm']:
        r39.shell('am', 'start', '-W', '-n', f'{package}/top.xdwa.shun.MainActivity', *PAYLOAD, check=False)
        time.sleep(4)
        lines.append(f'{round_}: pid={r39.shell("pidof", package, check=False).strip() or "gone"}')
    crashes = [l for l in r39.adb('logcat', '-d', '-b', 'crash', check=False).splitlines() if package in l]
    lines.append(f'crash lines mentioning {package}: {len(crashes)}')
    lines += crashes[:6]
    (out / 'summary.txt').write_text('\n'.join(lines) + '\n')
    print('\n'.join(lines), f'\nevidence in {out}', flush=True)
    return 0 if not crashes and 'gone' not in ''.join(lines) else 1


MOSH_PKG = 'top.xdwa.shun.mosh'


def mosh_client_facts():
    """mosh-client 的命令行和环境变量名（只记名字，不记值）。key 该走 fd 3，不该出现在这两处。"""
    ps = r39.shell('ps', '-A', '-o', 'PID,NAME', check=False)
    pids = [l.split()[0] for l in ps.splitlines() if 'mosh' in l and 'top.xdwa.shun.mosh' not in l]
    facts = []
    for pid in pids:
        cmd = r39.shell('run-as', MOSH_PKG, 'sh', '-c', f"tr '\\0' ' ' < /proc/{pid}/cmdline", check=False)
        env = r39.shell('run-as', MOSH_PKG, 'sh', '-c', f"tr '\\0' '\\n' < /proc/{pid}/environ | cut -d= -f1", check=False)
        facts.append((pid, cmd.strip(), sorted(set(env.split()))))
    return facts


def mosh():
    """PLG09/PLG14：真 Mosh 会话开着时看 mosh-client 拿到了什么，强杀插件，再到处搜测试秘密。"""
    env = r39.environment()
    r39.check_device()
    out = r39.CHAIN / 'artifacts' / time.strftime('x11-mosh-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    fixture = ROOT / 'tool/mosh-fixture/.run/fixture.json'
    r39.require(fixture.is_file(), '先 (cd tool/mosh-fixture && ./up.sh)')
    import json
    password = json.loads(fixture.read_text())['password']
    define = subprocess.run([sys.executable, 'tool/mosh-fixture/x08_config.py'], cwd=ROOT,
                            capture_output=True, text=True, check=True).stdout.strip()
    r39.adb('uninstall', HOST, check=False)
    r39.adb('install', '-r', str(MOSH_APK))
    # 模拟器经 10.0.2.2 的 TCP 只在蜂窝上通（本机手册第 3 节）。
    r39.shell('svc', 'wifi', 'disable')
    r39.adb('logcat', '-b', 'all', '-c', check=False)
    notes = []
    log = (out / 'flutter-test.log').open('w')
    proc = subprocess.Popen(
        ['flutter', 'test', '--no-pub', '--no-uninstall', 'integration_test/mosh_session_test.dart',
         '-d', r39.SERIAL, f'--dart-define=X09_MOSH={define}', '--dart-define=X09_SCENARIO=kill'],
        cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in proc.stdout:
        # 测试自己不打密码；万一打了，证据里也不留原文。
        log.write(line.replace(password, '<FIXTURE-PASSWORD>'))
        log.flush()
        if 'X09 ' in line:
            print(line.strip().replace(password, '<FIXTURE-PASSWORD>')[:200], flush=True)
        if 'X09 kill.READY' in line:
            for pid, cmd, names in mosh_client_facts():
                notes.append(f'mosh-client pid={pid} argv=[{cmd}] env names={names}')
                notes.append(f'  MOSH_KEY in env: {"MOSH_KEY" in names}; password in argv: {password in cmd}')
            # SELinux 不让 run-as 发 SIGKILL，用 am crash 让插件进程真崩一次（X10 同样做法）。
            r39.shell('am', 'crash', MOSH_PKG)
    code = proc.wait()
    log.close()
    r39.shell('svc', 'wifi', 'enable')

    def hits(text):
        return {k: text.count(k) for k in [password, 'MOSH CONNECT', 'MOSH_KEY']}
    places = {
        'logcat (all buffers)': r39.adb('logcat', '-d', '-b', 'all', check=False),
        'dropbox': r39.shell('dumpsys', 'dropbox', '--print', check=False),
    }
    for package in [HOST, MOSH_PKG]:
        # 调试包的 flutter_assets/kernel_blob.bin 是测试代码本身，--dart-define 的密码编在里面（R25 说过），不搜。
        places[f'{package} private files'] = r39.shell(
            'run-as', package, 'sh', '-c',
            "find . -type f ! -path '*/flutter_assets/*' -exec cat {} + 2>/dev/null", check=False)
    summary = [f'flutter test exit={code}', *notes]
    for where, text in places.items():
        found = hits(text)
        summary.append(f'{where}: password={found[password]} "MOSH CONNECT"={found["MOSH CONNECT"]} '
                       f'MOSH_KEY={found["MOSH_KEY"]} ({len(text)} chars searched)')
    # 对照：往 logcat 写一个标记再搜，搜不到说明搜法本身不灵，上面的 0 不算数。
    marker = f'x11-control-{time.time_ns()}'
    r39.shell('log', '-t', 'X11', marker)
    summary.append('control marker found in logcat: ' + str(marker in r39.adb('logcat', '-d', '-b', 'all', check=False)))
    (out / 'summary.txt').write_text('\n'.join(summary) + '\n')
    print('\n'.join(summary), f'\nevidence in {out}', flush=True)
    r39.adb('uninstall', HOST, check=False)
    return code


def main():
    if sys.argv[1:2] == ['mosh']:
        return mosh()
    if sys.argv[1:2] == ['intents']:
        r39.require(len(sys.argv) == 3, '用法：tool/x11-device.py intents <包名>')
        return intents(sys.argv[2])
    if sys.argv[1:2] == ['x03']:
        r39.require(len(sys.argv) == 3, '用法：tool/x11-device.py x03 <场景>')
        return x03(sys.argv[2])
    if sys.argv[1:2] == ['uu']:
        return uu()
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
    # keep_host：跑完还要看宿主申请了哪些权限，脚本最后自己卸。
    code, failed_action = run_marked(TARGET, ACTIONS, out, env, keep_host=True)

    tags = {'rogue': 'ShunRogue', 'echo': 'ShunEcho', 'host': 'ShunPlugins', 'mosh': 'ShunMosh'}
    for name, tag in tags.items():
        (out / f'logcat-{name}.txt').write_text(r39.adb('logcat', '-d', '-s', tag, check=False) + '\n')
    rogue_log = (out / 'logcat-rogue.txt').read_text()
    probes = [l for l in rogue_log.splitlines() if 'PROBE ' in l]
    accepted = [l for l in probes if 'ACCEPTED' in l]
    package_dump = r39.shell('dumpsys', 'package', HOST, check=False)
    (out / 'host-package.txt').write_text(package_dump + '\n')
    # PLG13 运行时那一半：跑完一整套插件流程，宿主私有目录里不该出现任何能执行的代码文件。
    # 调试包自己的 Dart 代码在 app_flutter/flutter_assets/kernel_blob.bin（flutter test 推进来的），不在这个名单里。
    code_files = r39.shell('run-as', HOST, 'sh', '-c',
                           "find . -type f \\( -name '*.so' -o -name '*.dex' -o -name '*.jar' -o -name '*.apk'"
                           " -o -name '*.odex' -o -name '*.vdex' -o -name '*.oat' -o -name '*.zip' \\) 2>/dev/null",
                           check=False).split()
    (out / 'host-code-files.txt').write_text('\n'.join(code_files) + '\n')
    summary = [
        f'host private code files={len(code_files)} {code_files[:5]}',
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
