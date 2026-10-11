// X08 设备验证：真实 Mosh 运行时插件（独立 APK、独立 UID）经真实插件桥连真实 mosh-server，输出进 Ghostty。
//
// 这不是 CI 测试。要先：
//   (cd tool/mosh-fixture && ./up.sh)                                   # mosh-server 容器
//   adb -s emulator-5580 reverse tcp:22301 tcp:22301                     # SSH bootstrap 走 adb reverse
//   adb -s emulator-5580 install -r plugins/mosh/build/outputs/apk/release/mosh-release.apk
//   flutter test integration_test/mosh_runtime_test.dart -d emulator-5580 \
//     --dart-define=X08_MOSH="$(python3 tool/mosh-fixture/x08_config.py)" --dart-define=X08_SCENARIO=interop
// UDP 不走 adb reverse（它只管 TCP），模拟器直接发到 x08_config.py 里的 udpHost，见 plugins/mosh/README.md。
// 场景和要在电脑上配合做的动作见 plugins/mosh/README.md。输出以 "X08 " 开头的行作为证据。
//
// 宿主这边的 bootstrap 是测试自己做的最小接线（X08 只证明运行时可行）：经 App 的 SshService 连上、
// 核对主机指纹，执行 MoshBootstrap.command()，用 MoshBootstrap.parse() 解析，再把材料交给插件。
// 产品里的受控 bootstrap、路由判定、界面是 X09。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shun/application/plugin_discovery.dart';
import 'package:shun/application/plugin_registry.dart';
import 'package:shun/application/plugin_sessions.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/plugins/builtin_plugins.dart';
import 'package:shun/domain/plugins/mosh_bootstrap.dart';
import 'package:shun/infrastructure/plugins/android_plugin_bridge.dart';
import 'package:shun/infrastructure/plugins/plugin_approval_store.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:plugin_api/plugin_api.dart' hide Platform;
import 'package:shared_preferences/shared_preferences.dart';

const scenario =
    String.fromEnvironment('X08_SCENARIO', defaultValue: 'interop');
const mosh = 'top.xdwa.shun.mosh';
const echo = 'example.shun.fixture.echo';
final config =
    jsonDecode(const String.fromEnvironment('X08_MOSH', defaultValue: '{}'))
        as Map<String, dynamic>;

void report(String key, Object? value) => debugPrint('X08 $key=$value');

Future<void> until(bool Function() done,
    {Duration timeout = const Duration(seconds: 30),
    String what = '条件'}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('等待$what超时');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

int fdCount() => Directory('/proc/self/fd').listSync().length;

int rssKb() {
  final line = File('/proc/self/status')
      .readAsLinesSync()
      .firstWhere((l) => l.startsWith('VmRSS:'));
  return int.parse(line.split(RegExp(r'\s+'))[1]);
}

/// 终端屏幕：插件输出喂进 Ghostty（和产品终端页用的是同一个适配器）。
class Screen {
  // 没挂视图时 Ghostty 的行列只能在建的时候定（挂了视图由视图量）。
  Screen(this.session, {int cols = 80, int rows = 24})
      : terminal = GhosttyTerminalAdapter(
            config: ghosttyTerminalConfig.copyWith(cols: cols, rows: rows)) {
    _sub = session.output.listen((chunk) {
      bytes += chunk.length;
      terminal.feed(chunk);
    });
  }

  final PluginTerminalSession session;
  final GhosttyTerminalAdapter terminal;
  late final StreamSubscription<Uint8List> _sub;
  var bytes = 0;

  String text([int rows = 60]) =>
      terminal.recentLines(rows).map((l) => l.text).join('\n');

  Future<void> type(String s) =>
      session.write(Uint8List.fromList(utf8.encode(s)));

  Future<void> waitText(String needle,
          {Duration timeout = const Duration(seconds: 20)}) =>
      until(() => text().contains(needle),
              timeout: timeout, what: '屏幕出现「$needle」')
          .catchError((Object e) {
        report('screen.onTimeout', '\n${text()}');
        throw e;
      });

  Future<void> dispose() async {
    await _sub.cancel();
    terminal.dispose();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late AndroidPluginBridge bridge;
  late PluginRegistry registry;
  late PluginDiscovery discovery;
  late PluginSessionManager manager;
  late ActiveTerminalSession ssh;

  Future<void> setUpPlugins() async {
    bridge = AndroidPluginBridge();
    registry = PluginRegistry(
      policy: AdmissionPolicy(
          builtinIds: BuiltinPlugins.ids, allowDebugSigners: kDebugMode),
    );
    discovery = PluginDiscovery(bridge,
        PluginApprovalStore(await SharedPreferences.getInstance()), registry);
    manager = PluginSessionManager(bridge, registry);
    await discovery.refresh();
  }

  PluginEntry entry(String package) =>
      registry.entries.singleWhere((e) => e.packageName == package);

  Future<PluginEntry> connected(String package) async {
    var e = entry(package);
    if (e.status == PluginStatus.needsApproval) {
      await discovery.approve(e);
      e = entry(package);
    }
    expect(e.status, PluginStatus.ready, reason: e.reason);
    final check = await discovery.check(e);
    report('check.$package', check);
    expect(check, contains('握手成功'));
    return e;
  }

  Future<String> run(String command) =>
      ssh.sshClient!.run(command).then((o) => utf8.decode(o).trim());

  Future<int> serverCount() async =>
      int.parse(await run('pgrep -x mosh-server | wc -l'));

  /// 经 App 的 SSH 连接 bootstrap 一个 mosh-server，交给插件开会话。
  Future<(PluginTerminalSession, Screen)> openMosh(
      {int cols = 80, int rows = 24}) async {
    final ports = (config['udpPorts'] as List).cast<int>();
    final range = (ports[0], ports[1]);
    final out =
        await ssh.sshClient!.run(MoshBootstrap.command(portRange: range));
    final material = MoshBootstrap.parse(out, portRange: range);
    out.fillRange(0, out.length, 0);
    final keyHash = await Sha256().hash(material.printableKey);
    // 只打 key 的 SHA-256 前缀：电脑上拿 logcat 里所有像 key 的串算哈希来比，看 key 有没有漏进日志。
    report(
        'keyhash',
        keyHash.bytes
            .take(8)
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join());
    report('udpPort', material.port);
    final key = material.printableKey;
    final s = await manager.open(
      entry(mosh),
      cols: cols,
      rows: rows,
      mosh: MoshSessionTarget(config['udpHost'] as String, material),
    );
    expect(key.every((b) => b == 0), isTrue, reason: '交给插件后宿主这边的 key 要清零');
    final screen = Screen(s, cols: cols, rows: rows);
    if (s.phase != SessionPhase.active) {
      await s.phases
          .firstWhere((p) => p == SessionPhase.active)
          .timeout(const Duration(seconds: 10));
    }
    return (s, screen);
  }

  testWidgets('X08 场景：$scenario', (tester) async {
    expect(config, isNotEmpty, reason: '没给 X08_MOSH，见文件头');
    await setUpPlugins();
    final host = HostProfile({
      'id': 'x08-mosh',
      'label': 'mosh',
      'hostname': '127.0.0.1',
      'port': config['sshPort'],
      'username': config['user'],
      'password': config['password'],
      'authMethod': 'password',
      'protocol': 'ssh',
    });
    ssh = await SshService().connect(
      terminal: GhosttyTerminalAdapter(),
      sessionId: 'x08',
      host: host,
      hosts: [host],
      keys: const [],
      proxyProfiles: const [],
      verifyHostKey: (_, __, fp) async => fp == config['fingerprint'],
    );
    await run('pkill -x mosh-server; true');
    report('platform', Platform.operatingSystemVersion);
    await connected(mosh);

    switch (scenario) {
      case 'interop':
        final fd0 = fdCount();
        final rss0 = rssKb();
        final sw = Stopwatch()..start();
        final (s, screen) = await openMosh();
        await screen.waitText(r'$');
        report('interop.firstPrompt.ms', sw.elapsedMilliseconds);
        await screen.type('echo mosh-\$((6*7))\r');
        await screen.waitText('mosh-42');
        // 中文：远端 printf 八进制转义，屏幕上应该是这两个字（宽字符经 mosh 的帧差分 + Ghostty 显示）
        await screen.type(r"printf '\344\270\255\346\226\207 ok\n'" '\r');
        await screen.waitText('中文 ok');
        // 全屏程序：vim 开文件、删一行、保存退出
        await screen.type(
            "printf 'a1\\nb2\\nc3\\n' > /tmp/x08.txt; vim -u NONE -N -n /tmp/x08.txt\r");
        await screen.waitText('b2');
        await screen.type('jdd');
        await Future<void>.delayed(const Duration(milliseconds: 800));
        await screen.type(':wq\r');
        // 等 vim 写完退回 shell 再敲下一条；连着敲会被还没退出的 vim 吃掉（测试时序，不是协议问题）。
        await screen.waitText('written');
        await Future<void>.delayed(const Duration(milliseconds: 800));
        await screen.type('clear; cat /tmp/x08.txt | tr "\\n" ,\r');
        await screen.waitText('a1,c3,');
        // 改尺寸：插件改 PTY 窗口，mosh-client 收到 SIGWINCH 告诉服务器，远端 shell 看到新尺寸。
        // （本地这个无视图的 Ghostty 还是 80x24，所以只看文字，不比画面。）
        await s.resize(100, 30);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await screen.type('clear; stty size\r');
        await screen.waitText('30 100');
        report('interop.screen', '\n${screen.text(30)}');
        report('interop.bytes', screen.bytes);
        // 用户关标签：插件给 mosh-client 发 SIGHUP，它按协议通知服务器关闭，服务器和远端 shell 一起退出
        final closeSw = Stopwatch()..start();
        await s.close();
        report('interop.close.stopConfirmed', s.stopConfirmed);
        var left = await serverCount();
        while (left > 0 && closeSw.elapsed < const Duration(seconds: 20)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          left = await serverCount();
        }
        report('interop.close.serverLeft',
            '$left after ${closeSw.elapsedMilliseconds} ms');
        expect(left, 0);
        await screen.dispose();
        await Future<void>.delayed(const Duration(seconds: 1));
        report('interop.fds', '$fd0 -> ${fdCount()}');
        report('interop.rssKb', '$rss0 -> ${rssKb()}');
      case 'exit':
        final (s, screen) = await openMosh();
        await screen.waitText(r'$');
        await screen.type('exit\r');
        await s.phases
            .firstWhere((p) => p.isTerminal)
            .timeout(const Duration(seconds: 30));
        report('exit.phase', s.phase);
        expect(s.phase, SessionPhase.closed);
        report('exit.serverLeft', await serverCount());
        await screen.dispose();
      case 'multi':
        final (a, sa) = await openMosh();
        final (b, sb) = await openMosh();
        await sa.waitText(r'$');
        await sb.waitText(r'$');
        await sa.type('echo only-a\r');
        await sb.type('echo only-b\r');
        await sa.waitText('only-a');
        await sb.waitText('only-b');
        expect(sa.text(), isNot(contains('only-b')));
        expect(sb.text(), isNot(contains('only-a')));
        report('multi.servers', await serverCount());
        await a.close();
        await sb.type('echo b-still-\$((6*7))\r');
        await sb.waitText('b-still-42');
        report('multi.afterCloseA', 'b ok');
        await b.close();
        await sa.dispose();
        await sb.dispose();
      case 'cycles':
        final fd0 = fdCount();
        for (var i = 0; i < 10; i++) {
          final (s, screen) = await openMosh();
          await screen.waitText(r'$');
          await screen.type('echo cycle-$i\r');
          await screen.waitText('cycle-$i');
          await s.close();
          await screen.dispose();
        }
        await Future<void>.delayed(const Duration(seconds: 10));
        report('cycles.fds', '$fd0 -> ${fdCount()}');
        report('cycles.serverLeft', await serverCount());
        report('cycles.READY', 'check plugin processes now');
        await Future<void>.delayed(const Duration(seconds: 15));
      case 'kill':
        // 电脑上看到 kill.READY 后：adb shell run-as top.xdwa.shun.mosh kill -9 <插件 pid>
        final (s, screen) = await openMosh();
        await screen.waitText(r'$');
        report('kill.sshBefore', await run('echo before'));
        report('kill.READY', 'kill $mosh now');
        await s.phases
            .firstWhere((p) => p.isTerminal)
            .timeout(const Duration(seconds: 120));
        report('kill.phase', s.phase);
        expect(s.phase, SessionPhase.providerDied);
        report('kill.sshAfter', await run('echo after'));
        await Future<void>.delayed(const Duration(seconds: 3));
        report('kill.serverLeft', await serverCount());
        await screen.dispose();
      case 'hostkill':
        // 电脑上看到 hostkill.READY 后：adb shell run-as top.xdwa.shun kill -9 <宿主 pid>，再在电脑上数 mosh-server
        final (_, screen) = await openMosh();
        await screen.waitText(r'$');
        await screen.type('echo before-host-dies\r');
        await screen.waitText('before-host-dies');
        report('hostkill.READY', 'kill host now');
        await Future<void>.delayed(const Duration(seconds: 120));
      case 'echo-mosh':
        // 不经 Dart 的权限判断，直接让桥把 Mosh 材料发给 echo（它不支持）：宿主不能崩，要如实报错。
        await connected(echo);
        Object? error;
        try {
          await bridge.openSession(
            packageName: echo,
            handle: 'x08-echo-0001',
            generation: 1,
            cols: 80,
            rows: 24,
            moshHost: '127.0.0.1',
            moshPort: 60001,
            moshKey: Uint8List.fromList(utf8.encode('AAAAAAAAAAAAAAAAAAAAAA')),
          );
        } on PluginBridgeException catch (e) {
          error = e;
        }
        report('echo-mosh.error', error);
        expect(error, isA<PluginBridgeException>());
        // 走 Dart 这一层：echo 没申请临时密钥权限，根本不发。
        final material = MoshBootstrap.parse(
            utf8.encode('MOSH CONNECT 60001 AAAAAAAAAAAAAAAAAAAAAA\n'));
        await expectLater(
          manager.open(entry(echo),
              mosh: MoshSessionTarget('127.0.0.1', material)),
          throwsA(isA<PluginUnavailable>()),
        );
        report('echo-mosh.dartGate', 'refused');
      default:
        fail('未知场景 $scenario');
    }
    await ssh.close();
  });
}
