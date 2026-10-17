// X09 设备验证：真实 App 页面里连 Mosh 主机——受控 SSH 引导 → 真实 Mosh 插件（独立 APK）经 UDP 连 mosh-server，
// 画面进 Ghostty。和 X08 的 mosh_runtime_test.dart 不同，这里不自己接线：走的就是用户点「连接」时的那条路
// （SessionController → MoshBootstrapCoordinator → SshService.bootstrapMosh → 插件）。
//
// 这不是 CI 测试。要先（详见 docs/dev/README.md 第 2 节「Mosh」）：
//   (cd tool/mosh-fixture && ./up.sh)
//   adb -s emulator-5580 install -r plugins/mosh/build/outputs/apk/release/mosh-release.apk
//   flutter test integration_test/mosh_session_test.dart -d emulator-5580 \
//     --dart-define=X09_MOSH="$(python3 tool/mosh-fixture/x08_config.py)" --dart-define=X09_SCENARIO=all
// 模拟器里 SSH 和 UDP 都直接发往 10.0.2.2（这台 Mac），不用 adb reverse：UDP 必须跟着 SSH 实际连上的 IP 走，
// SSH 若走 adb reverse 到 127.0.0.1，UDP 就会发到模拟器自己身上。
// 输出以 "X09 " 开头的行作为证据。场景：
//   all     MOS01 回归 + MOS03（两段、输入、中文、vim、旋转改尺寸、大量彩色输出）、MOS04（五种路线）、MOS02（指纹、密码、缺 mosh-server）、
//           运行时退出码 1 的说法
//   kill    打出 "X09 kill.READY" 后在电脑上强杀插件：adb shell run-as top.xdwa.shun.mosh kill -9 <插件 pid>
//   ime     MOS05 输入法回放，只能经 tool/ime-replay.sh 跑（它替测试发广播给回放输入法）
//   panel   R25 按键面板、大输入框经 Mosh 发：远端逐字节核对，终端输入次数 = 宿主写入次数
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shun/app.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/host_trust.dart';
import 'package:shun/application/mosh_session.dart';
import 'package:shun/application/plugin_discovery.dart';
import 'package:shun/application/plugin_registry.dart';
import 'package:shun/application/plugin_sessions.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/plugins/mosh_bootstrap.dart';
import 'package:shun/domain/plugins/mosh_route.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/terminal/terminal_session_adapter.dart';

import 'r18_ime_replay_test.dart' show imeReplayExpectations;
import 'r18_remote_capture.dart' as r18;

const scenario = String.fromEnvironment('X09_SCENARIO', defaultValue: 'all');
final config =
    jsonDecode(const String.fromEnvironment('X09_MOSH', defaultValue: '{}'))
        as Map<String, dynamic>;
const moshPackage = 'top.xdwa.shun.mosh';

/// Mosh 标签和 SSH 标签用同一个终端引擎。R20 起只有 Ghostty（原来 X09_ENGINE=xterm2 能换旧引擎对照）。
const engine = 'Ghostty';

void report(String key, Object? value) => debugPrint('X09 $key=$value');

Future<void> waitFor(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 30),
  String what = '条件',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待$what超时');
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> settle(WidgetTester tester, [int ms = 800]) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 不跟随链接：跟随的话要 stat 每个 fd 的目标，列到一半有 fd 被关就抛 PathNotFoundException（X09 撞上过）。
int fdCount() =>
    Directory('/proc/self/fd').listSync(followLinks: false).length;

/// 独立于被测代码的检查通道：直接用 dartssh2 登录测试环境（算一次登录，证据里扣掉）。
class Monitor {
  Monitor._(this._client);

  static Future<Monitor> open() async => Monitor._(SSHClient(
        await SSHSocket.connect(
            config['sshHost'] as String, config['sshPort'] as int),
        username: config['user'] as String,
        onPasswordRequest: () => config['password'] as String,
        onVerifyHostKey: (_, fp) => utf8.decode(fp) == config['fingerprint'],
      ));

  final SSHClient _client;

  Future<String> run(String command) async =>
      utf8.decode(await _client.run(command)).trim();

  /// 记账脚本记下的 mosh-server 启动次数（tool/mosh-fixture/shims/mosh-server）。
  Future<int> starts() async =>
      int.parse(await run('cat /var/log/shun/mosh-server-starts.log 2>/dev/null | wc -l'));

  /// 此刻还在跑的 mosh-server（脱离出来、父进程是 1 的那个）。
  Future<int> running() async => int.parse(await run(
      "ps -o ppid,comm | awk '\$1 == 1 && \$2 == \"mosh-server\"' | wc -l"));

  void close() => _client.close();
}

HostProfile moshHost(String id, {Map<String, Object?> extra = const {}}) =>
    HostProfile({
      'id': id,
      'label': id,
      'hostname': config['sshHost'],
      'port': config['sshPort'],
      'username': config['user'],
      'password': config['password'],
      'authMethod': 'password',
      'protocol': 'mosh',
      moshPortsKey: (config['udpPorts'] as List).join(':'),
      ...extra,
    });

Future<bool> verifyFixture(HostProfile host, String type, String fp) async =>
    fp ==
    (host.port == config['nomoshPort']
        ? config['nomoshFingerprint']
        : config['fingerprint']);

/// 起真 App 页面（终端标签）；把 Mosh 插件批准好（证书是系统读出的那张）。
Future<(ProviderContainer, SessionController)> startApp(
    WidgetTester tester) async {
  final repository = await VaultRepository.open();
  final container = ProviderContainer(overrides: [
    vaultRepositoryProvider.overrideWithValue(repository),
  ]);
  addTearDown(container.dispose);
  final controller = container.read(sessionControllerProvider.notifier);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const ShunApp(),
  ));
  container.read(homeTabProvider.notifier).state = 1;
  final discovery = await container.read(pluginDiscoveryProvider.future);
  await discovery.start();
  final entry = container
      .read(pluginRegistryProvider)
      .singleWhere((e) => e.packageName == moshPackage);
  if (entry.status == PluginStatus.needsApproval) await discovery.approve(entry);
  report('plugin.status',
      container.read(pluginRegistryProvider).singleWhere((e) => e.packageName == moshPackage).status);
  return (container, controller);
}

/// 记下等待卡片上出现过的每一句阶段说明（按出现顺序，去重）。
List<String> recordStages(SessionController controller) {
  final seen = <String>[];
  controller.addListener((state) {
    for (final pending in state.pendingConnections) {
      final text = pending.stage?.describe();
      if (text != null && (seen.isEmpty || seen.last != text)) seen.add(text);
    }
  }, fireImmediately: false);
  return seen;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final skip = config.isEmpty ? '没给 X09_MOSH，见文件头' : false;

  testWidgets('X09 场景：$scenario', (tester) async {
    addTearDown(() => SystemChrome.setPreferredOrientations(const []));
    final monitor = await Monitor.open();
    addTearDown(monitor.close);
    await monitor.run('pkill -x mosh-server; true');
    final (container, controller) = await startApp(tester);
    report('platform', Platform.operatingSystemVersion);
    final manager = container.read(pluginSessionManagerProvider);

    Future<ActiveTerminalSession> open(HostProfile host) async {
      final result = controller.connect(host, verifyFixture);
      await waitFor(tester, () => controller.state.sessions.any((s) => s.host.id == host.id),
          timeout: const Duration(seconds: 40), what: 'Mosh 标签');
      expect(await result, isTrue);
      final tab = controller.state.sessions.lastWhere((s) => s.host.id == host.id);
      await waitFor(tester, () => tab.terminal.allText().contains(r'$'),
          what: '远端提示符');
      return tab;
    }

    /// 连接应当失败：返回错误，等待卡片上的失败说明和提示一起报告。
    Future<Object> refused(String name, HostProfile host,
        {HostKeyVerifier? verify}) async {
      Object? error;
      try {
        await controller.connect(host, verify ?? verifyFixture);
      } catch (e) {
        error = e;
      }
      await settle(tester, 300);
      final pane = find.byKey(const ValueKey('terminal-connection-status-dialog'));
      final texts = tester
          .widgetList<Text>(find.descendant(of: pane, matching: find.byType(Text)))
          .map((t) => t.data ?? '')
          .where((t) => t.isNotEmpty)
          .join(' | ');
      report('$name.error', '${error.runtimeType}: $error');
      report('$name.pane', texts);
      for (final pending in [...controller.state.pendingConnections]) {
        controller.dismissPending(pending.id);
      }
      expect(error, isNotNull, reason: '$name 应当失败');
      return error!;
    }

    switch (scenario) {
      case 'all':
        // ---- MOS03 / MOS01 回归：直连，两段，输入、中文、vim、改尺寸、大量输出 ----
        final starts0 = await monitor.starts();
        final fd0 = fdCount();
        final stages = recordStages(controller);
        final sw = Stopwatch()..start();
        final tab = await open(moshHost('x09-direct'));
        report('direct.firstPrompt.ms', sw.elapsedMilliseconds);
        report('direct.stages', '\n  ${stages.join('\n  ')}');
        final link = tab.plugin! as MoshTerminalProvider;
        final terminal = tab.terminal;
        report('direct.link', '${link.protocol} ${link.detail} engine=${terminal.engine} isSsh=${tab.isSsh} sshClients=${tab.sshClients.length}');
        expect(tab.isSsh, isFalse);
        expect(link.detail, startsWith('UDP 10.0.2.2:'));
        expect(await monitor.starts(), starts0 + 1);
        await settle(tester);

        Future<void> type(String text) async {
          controller.typeInto(tab.id, text);
          await tester.pump();
        }

        Future<void> screenHas(String needle,
            {Duration timeout = const Duration(seconds: 20)}) async {
          try {
            await waitFor(tester, () => terminal.allText().contains(needle),
                timeout: timeout, what: '屏幕出现「$needle」');
          } on TestFailure {
            report('screen.onTimeout', '\n${terminal.allText()}');
            rethrow;
          }
        }

        await type('echo mosh-\$((6*7))\r');
        await screenHas('mosh-42');
        // 中文：一次提交「你好」，远端逐字节看到的应当就是它的 UTF-8，没有被再编码一遍。
        await type('printf %s 你好 | od -An -tx1; echo zh-\$((1+1))\r');
        await screenHas('zh-2');
        expect(terminal.allText(), contains('e4 bd a0 e5 a5 bd'));
        await type("printf '\\344\\270\\255\\346\\226\\207 ok\\n'\r");
        await screenHas('中文 ok');
        await type(
            "clear; printf 'a1\\nb2\\nc3\\n' > /tmp/x09.txt; vim -u NONE -N -n /tmp/x09.txt\r");
        await screenHas('b2');
        await type('jdd');
        await settle(tester);
        await type(':wq\r');
        await screenHas('written');
        await settle(tester);
        await type('clear; tr "\\n" , < /tmp/x09.txt; echo\r');
        await screenHas('a1,c3,');

        // 改尺寸：旋转后终端视图重新量，尺寸只经终端绑定 → 插件 → mosh-client → 服务器。远端 stty size 要等于引擎的行列。
        var probe = 0;
        Future<(int, int)> remoteSize() async {
          final tag = 'S${probe++}';
          await type('clear; stty size; echo $tag-\$((40+2))\r');
          await screenHas('$tag-42');
          final lines = terminal.allText().split('\n');
          final i = lines.lastIndexWhere((l) => l.startsWith('$tag-42'));
          final parts = lines[i - 1].trim().split(' ');
          return (int.parse(parts[0]), int.parse(parts[1]));
        }

        Future<void> checkSize(String name) async {
          await settle(tester, 1500);
          final sent = (terminal as TerminalSessionAdapterBase).sentSize;
          final remote = await remoteSize();
          report('size.$name', 'engine(cols,rows)=$sent remote(rows,cols)=$remote viewRows=${terminal.viewRows} resized=${link.session.lastResize}');
          expect(sent, isNotNull);
          expect(remote, (sent!.$2, sent.$1), reason: '$name：远端尺寸和引擎不一致');
        }

        FocusManager.instance.primaryFocus?.unfocus();
        await settle(tester);
        await checkSize('portrait');
        await SystemChrome.setPreferredOrientations(const [DeviceOrientation.landscapeLeft]);
        await waitFor(tester, () {
          final s = tester.view.physicalSize;
          return s.width > s.height;
        }, what: '转横屏');
        await checkSize('landscape');
        await SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
        await waitFor(tester, () {
          final s = tester.view.physicalSize;
          return s.width < s.height;
        }, what: '转竖屏');
        await checkSize('portrait-again');

        // 大量带颜色、中文的输出：插件 FD 每次读 16 KiB、宿主按块转给 Ghostty，块边界落在哪里不由我们定。
        await type('clear; for i in \$(seq 1 400); do printf "\\033[3%dm行%03d 中文ok\\033[0m\\n" \$((i%7+1)) \$i; done; echo vt-\$((6*7))\r');
        await screenHas('vt-42', timeout: const Duration(seconds: 40));
        final lines = terminal.recentLines(terminal.viewRows).map((l) => l.text).toList();
        final at = lines.lastIndexWhere((l) => l.startsWith('vt-42'));
        report('vt.tail', lines.sublist((at - 3).clamp(0, at), at + 1).join(' / '));
        expect(lines[at - 1].trim(), '行400 中文ok');
        expect(lines[at - 2].trim(), '行399 中文ok');

        report('writes', 'terminalInputs=${link.inputEvents} hostWrites=${link.session.writeCount} bytes=${link.session.bytesWritten} dropped=${link.droppedInputBytes}');
        expect(link.inputEvents, link.session.writeCount, reason: '每次输入只写一次');

        // 关标签：插件让 mosh-client 按协议通知服务器，远端这个 mosh-server 退出。
        final closeSw = Stopwatch()..start();
        await controller.close(controller.state.sessions.indexOf(tab));
        var left = await monitor.running();
        while (left > 0 && closeSw.elapsed < const Duration(seconds: 20)) {
          await settle(tester, 200);
          left = await monitor.running();
        }
        report('direct.close', 'serverLeft=$left after ${closeSw.elapsedMilliseconds} ms stopConfirmed=${link.session.stopConfirmed}');
        expect(left, 0);
        await settle(tester, 1000);
        report('direct.fds', '$fd0 -> ${fdCount()}');

        // ---- MOS04：五种路线都在任何网络动作之前拒绝 ----
        final vault = container.read(vaultControllerProvider.notifier);
        await vault.upsertHost(HostProfile({
          'id': 'x09-jump',
          'label': 'x09-jump',
          'hostname': config['sshHost'],
          'port': config['nomoshPort'],
          'username': config['user'],
          'password': config['password'],
          'protocol': 'ssh',
        }));
        const socks = {'type': 'socks5', 'host': '127.0.0.1', 'port': 1080};
        final routes = <String, Map<String, Object?>>{
          'socks': {'proxyConfig': socks},
          // TailSocks 在手机上就是本机的一个 SOCKS5 端口。
          'tailsocks': {
            'proxyConfig': {'type': 'socks5', 'host': '127.0.0.1', 'port': 1055},
          },
          'http': {
            'proxyConfig': {'type': 'http', 'host': '127.0.0.1', 'port': 3128},
          },
          'jump': {
            'hostChain': {
              'hostIds': ['x09-jump'],
            },
          },
          'socks+jump': {
            'proxyConfig': socks,
            'hostChain': {
              'hostIds': ['x09-jump'],
            },
          },
        };
        final startsBeforeRoutes = await monitor.starts();
        final opensBefore = manager.sessions.length;
        for (final MapEntry(key: name, value: extra) in routes.entries) {
          final host = moshHost('x09-route-$name', extra: extra);
          await vault.upsertHost(host);
          final error = await refused('route.$name', host);
          expect(error, isA<MoshRouteUnsupported>());
        }
        report('route.counts', 'moshServerStartsDelta=${await monitor.starts() - startsBeforeRoutes} pluginSessions=${manager.sessions.length - opensBefore}');
        expect(await monitor.starts(), startsBeforeRoutes);

        // ---- MOS02：指纹、密码、缺 mosh-server ----
        final startsBeforeTrust = await monitor.starts();
        var asked = 0;
        final firstSeen = await refused(
          'trust.firstSeenRejected',
          moshHost('x09-trust-new'),
          verify: (host, type, fp) => verifyHostKeyWithKnownHosts(
            knownHosts: const [],
            hostname: host.hostname,
            port: host.port,
            keyType: type,
            fingerprint: fp,
            confirmNew: () async {
              asked++;
              return false;
            },
            onChanged: (_) async => false,
            save: (_) async {},
          ),
        );
        expect(asked, 1);
        expect(firstSeen, isA<RouteHopException>());
        final changed = await refused(
          'trust.changed',
          moshHost('x09-trust-changed'),
          verify: (host, type, fp) => verifyHostKeyWithKnownHosts(
            knownHosts: [
              {
                'hostname': host.hostname,
                'port': host.port,
                'keyType': type,
                'fingerprint': 'SHA256:not-this-server',
              },
            ],
            hostname: host.hostname,
            port: host.port,
            keyType: type,
            fingerprint: fp,
            confirmNew: () async => fail('指纹变了不该再问「要不要信任」'),
            onChanged: (_) async => true,
            save: (_) async {},
          ),
        );
        expect(changed, isA<RouteHopException>());
        final badPassword = await refused('trust.badPassword',
            moshHost('x09-badpw', extra: {'password': 'not-the-password'}));
        expect(badPassword, isA<RouteHopException>());
        final missing = await refused('trust.noMoshServer',
            moshHost('x09-nomosh', extra: {'port': config['nomoshPort']}));
        expect(missing, isA<MoshBootstrapException>());
        report('trust.counts', 'moshServerStartsDelta=${await monitor.starts() - startsBeforeTrust} pluginSessions=${manager.sessions.length - opensBefore}');
        expect(await monitor.starts(), startsBeforeTrust);

        // ---- 运行时退出码 1：UDP 端口没映射出来（60201），mosh-client 收不到服务器，自己超时退出 ----
        final udpTab = await () async {
          final host = moshHost('x09-noudp', extra: {moshPortsKey: '60201'});
          final result = controller.connect(host, verifyFixture);
          await waitFor(tester, () => controller.state.sessions.any((s) => s.host.id == host.id),
              timeout: const Duration(seconds: 40), what: 'Mosh 标签');
          expect(await result, isTrue);
          return controller.state.sessions.lastWhere((s) => s.host.id == host.id);
        }();
        final udpSw = Stopwatch()..start();
        await waitFor(tester, () => !udpTab.connected,
            timeout: const Duration(seconds: 120), what: 'mosh-client 自己退出');
        await settle(tester, 1000);
        final udpLink = udpTab.plugin! as MoshTerminalProvider;
        report('noudp', 'ended after ${udpSw.elapsedMilliseconds} ms phase=${udpLink.session.phase} failure=${udpLink.session.failure} autoRestoreBlocked=${udpTab.autoRestoreBlocked}');
        report('noudp.screen', '\n${udpTab.terminal.allText()}');
        expect(udpLink.session.failure, 'exit-1');
        expect(udpTab.terminal.allText().replaceAll('\n', ''), contains('UDP 到不了服务器'));
        await controller.close(controller.state.sessions.indexOf(udpTab));
        await monitor.run('pkill -x mosh-server; true');

      case 'cycles':
        // 「all」里 fd 从 153 涨到 186，那段还转了屏、开了别的页面。这里只连开连关 Mosh 标签：先热身一次再量。
        Future<void> cycle(int i) async {
          final tab = await open(moshHost('x09-cycle'));
          controller.typeInto(tab.id, 'echo cycle-$i\r');
          await waitFor(tester, () => tab.terminal.allText().contains('cycle-$i'),
              what: 'cycle-$i');
          await controller.close(controller.state.sessions.indexOf(tab));
          await settle(tester, 500);
        }

        await cycle(0);
        await settle(tester, 2000);
        final fd0 = fdCount();
        for (var i = 1; i <= 10; i++) {
          await cycle(i);
        }
        await settle(tester, 3000);
        report('cycles', 'fds $fd0 -> ${fdCount()} serverLeft=${await monitor.running()} pluginSessions=${manager.sessions.length}');
        report('cycles.READY', 'count plugin processes now');
        await settle(tester, 10000);

      case 'kill':
        final tab = await open(moshHost('x09-kill'));
        final link = tab.plugin! as MoshTerminalProvider;
        final starts = await monitor.starts();
        report('kill.READY', 'kill $moshPackage now');
        await waitFor(tester, () => !tab.connected,
            timeout: const Duration(seconds: 180), what: '插件被强杀');
        await settle(tester, 1000);
        report('kill.phase', '${link.session.phase} autoRestoreBlocked=${tab.autoRestoreBlocked}');
        report('kill.screen', '\n${tab.terminal.allText()}');
        expect(link.session.phase.name, 'providerDied');
        // 回前台、自动恢复都不能悄悄再起一个 mosh-server。
        controller.setBackgrounded(true);
        controller.setBackgrounded(false);
        await controller.reconnectDisconnected();
        await settle(tester, 3000);
        report('kill.afterRestore', 'startsDelta=${await monitor.starts() - starts} serverLeft=${await monitor.running()} tabs=${controller.state.sessions.length}');
        expect(await monitor.starts(), starts);
        await controller.close(0);
        await monitor.run('pkill -x mosh-server; true');

      case 'ime':
        // MOS05：回放输入法按真实输入法的调用顺序操作输入连接，经 Ghostty → 终端绑定 → 插件 FD → mosh-client → UDP → 远端 dd。
        final tab = await open(moshHost('x09-ime'));
        final link = tab.plugin! as MoshTerminalProvider;
        await waitFor(tester, () => tester.view.viewInsets.bottom > 0, what: '输入法弹出');
        final failures = <String>[];
        for (final MapEntry(key: script, value: check)
            in imeReplayExpectations.entries) {
          final inputs = link.inputEvents;
          final writes = link.session.writeCount;
          final bytes = await r18.captureRemote(
            tester,
            tab.terminal,
            () async => r18.report('READY', script),
          );
          final result = r18.replay(bytes);
          report('ime.$script',
              'bytes=[${r18.hex(bytes)}] lines=${result.lines} deletes=${result.deletes} '
              'terminalInputs=${link.inputEvents - inputs} hostWrites=${link.session.writeCount - writes}');
          if (link.inputEvents - inputs != link.session.writeCount - writes) {
            failures.add('$script: 终端输入次数和宿主写入次数不一致');
          }
          try {
            check(bytes);
          } on TestFailure catch (error) {
            failures.add('$script: $error');
          }
        }
        await controller.close(0);
        await settle(tester, 300);
        expect(failures, isEmpty, reason: failures.join('\n'));
      case 'panel':
        // R25：按键面板和大输入框经 Mosh 发出去，走的还是终端绑定这一个出口（终端输入次数 = 宿主写入次数）。
        final tab = await open(moshHost('x09-panel'));
        final link = tab.plugin! as MoshTerminalProvider;
        final panel = find.byKey(const ValueKey('terminal-input-panel'));
        Future<void> tap(Finder finder) async {
          await tester.tap(finder);
          await settle(tester, 400);
        }

        await tap(find.byKey(const ValueKey('terminal-action-input-panel')));
        final inputs = link.inputEvents;
        final writes = link.session.writeCount;
        final bytes = await r18.captureRemote(tester, tab.terminal, () async {
          for (final label in ['Esc', 'Tab', '↑', 'PgUp']) {
            await tap(find.descendant(of: panel, matching: find.text(label)));
          }
          await tap(find.byKey(const ValueKey('terminal-input-tab-compose')));
          tester
              .widget<TextField>(find.byKey(const ValueKey('terminal-compose-editor')))
              .controller!
              .text = '你好 mosh';
          await settle(tester, 300);
          await tap(find.byKey(const ValueKey('terminal-compose-send')));
        }, end: r18.CaptureEnd.timeout, seconds: 15);
        final expected = [
          0x1b, 0x09, 0x1b, 0x5b, 0x41, 0x1b, 0x5b, 0x35, 0x7e, //
          ...utf8.encode('你好 mosh'), 0x0d,
        ];
        report('panel',
            'bytes=[${r18.hex(bytes)}] expected=[${r18.hex(expected)}] '
            'terminalInputs=${link.inputEvents - inputs} hostWrites=${link.session.writeCount - writes}');
        await controller.close(0);
        await settle(tester, 300);
        expect(r18.hex(bytes), r18.hex(expected));
        expect(link.inputEvents - inputs, link.session.writeCount - writes);
      default:
        fail('未知场景 $scenario');
    }
    await monitor.run('pkill -x mosh-server; true');
  }, skip: skip != false, timeout: const Timeout(Duration(minutes: 10)));
}
