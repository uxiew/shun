import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/connection_diagnosis.dart';
import 'package:netcatty_mobile/application/mosh_session.dart';
import 'package:netcatty_mobile/application/plugin_sessions.dart';
import 'package:netcatty_mobile/application/session_controller.dart';
import 'package:netcatty_mobile/application/vault_controller.dart';
import 'package:netcatty_mobile/domain/connection_route.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/plugins/mosh_bootstrap.dart';
import 'package:netcatty_mobile/domain/plugins/mosh_route.dart';
import 'package:netcatty_mobile/domain/route_description.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/domain/tmux/tmux_target.dart';
import 'package:netcatty_mobile/infrastructure/terminal/terminal_session_adapter.dart';
import 'package:netcatty_mobile/infrastructure/terminal/xterm_terminal_adapter.dart';
import 'package:plugin_api/plugin_api.dart' show RequestedRoute, SessionPhase;
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures/mosh_plugin_harness.dart';

// X09 Mosh 接入里不用连任何东西就能测的部分：路线判定、端口范围、结束原因的说法、单一输入所有者、
// 会话控制器不自动重连。真实 OpenSSH + mosh-server 上的引导见 mosh_fixture_test.dart，
// 真插件、真 UDP 会话见 integration_test/mosh_session_test.dart。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  HostProfile mosh([Map<String, Object?> extra = const {}]) => HostProfile({
        'id': 'm1',
        'label': 'box',
        'hostname': 'box.example.com',
        'port': 22,
        'username': 'ops',
        'password': 'X09-LOGIN-SECRET',
        'protocol': 'mosh',
        ...extra,
      });
  final jump = HostProfile({
    'id': 'j1',
    'label': 'edge',
    'hostname': 'edge.example.com',
    'port': 22,
    'username': 'ops',
    'protocol': 'ssh',
  });
  RoutePlan plan(HostProfile host) =>
      resolveRoutePlan(host, hosts: [host, jump], proxyProfiles: const []);
  const socks = {
    'type': 'socks5',
    'host': '127.0.0.1',
    'port': 1055,
    'username': 'u',
    'password': 'X09-PROXY-SECRET',
  };

  group('路线：Mosh 只许直连（MOS04）', () {
    test('直连可以；代理、跳板、代理 + 跳板各自报出是哪种', () {
      expect(requestedRouteOf(plan(mosh())), RequestedRoute.systemDefault);
      expect(moshRouteProblem(plan(mosh())), isNull);
      final cases = {
        mosh({'proxyConfig': socks}): (
          RequestedRoute.socks5Connect,
          '经SOCKS5 代理 127.0.0.1:1055'
        ),
        mosh({
          'proxyConfig': {'type': 'http', 'host': '10.0.0.1', 'port': 3128},
        }): (RequestedRoute.socks5Connect, '经HTTP 代理 10.0.0.1:3128'),
        mosh({
          'hostChain': {
            'hostIds': ['j1'],
          },
        }): (RequestedRoute.proxyJump, '经跳板机 “edge”'),
        mosh({
          'proxyConfig': socks,
          'hostChain': {
            'hostIds': ['j1'],
          },
        }): (
          RequestedRoute.socks5ProxyJump,
          '先经SOCKS5 代理 127.0.0.1:1055再走跳板机 “edge”'
        ),
      };
      for (final MapEntry(key: host, value: (route, description))
          in cases.entries) {
        final problem = moshRouteProblem(plan(host))!;
        expect(problem.route, route);
        expect(problem.description, description);
        expect('$problem', isNot(contains('X09-PROXY-SECRET')),
            reason: '报错只写地址，不写代理账号口令');
        expect(connectionHint(problem), contains('改回 SSH'));
      }
    });

    test('路线摘要把两段写清楚：SSH 只用来启动 mosh-server，之后走 UDP', () {
      final legs = describeRoute(plan(mosh()));
      expect(legs.last.detail,
          'SSH ops@box.example.com:22 启动 mosh-server，之后 Mosh 会话走 UDP 直连');
    });
  });

  group('UDP 端口范围', () {
    test('空着用 mosh 默认；单个端口、范围都认；越界、反了、乱写都拒绝', () {
      expect(parseMoshPorts(null), (60001, 60999));
      expect(parseMoshPorts('  '), (60001, 60999));
      expect(parseMoshPorts('60101'), (60101, 60101));
      expect(parseMoshPorts(' 60101:60108 '), (60101, 60108));
      for (final bad in ['0', '60108:60101', '60000:70000', 'abc', '1-2', '60001:', ':60001', '123456']) {
        expect(() => parseMoshPorts(bad), throwsA(isA<RouteConfigException>()),
            reason: bad);
      }
      expect(moshPortRangeOf(mosh({moshPortsKey: '60001:60010'})), (60001, 60010));
      // 拼出来的命令里只有校验过的数字。
      expect(MoshBootstrap.command(portRange: parseMoshPorts('60001:60010')),
          'mosh-server new -s -c 256 -l LANG=en_US.UTF-8 -p 60001:60010');
    });
  });

  group('插件会话 → 终端（MoshTerminalProvider）', () {
    late MoshPluginHarness plugin;
    setUp(() => plugin = MoshPluginHarness());
    tearDown(() => plugin.dispose());

    MoshSessionTarget target() => MoshSessionTarget(
          '10.0.2.2',
          MoshBootstrap.parse(
              utf8.encode('MOSH CONNECT 60101 v450/k6rhyS3hwDL4ejCIQ\n')),
        );

    Future<(ActiveTerminalSession, MoshTerminalProvider, XtermTerminalAdapter)>
        attach() async {
      final session = await plugin.open(await plugin.prepare(),
          cols: 80, rows: 24, target: target());
      final terminal = XtermTerminalAdapter();
      final tab = MoshTerminalProvider.attach(
        sessionId: 't1',
        host: mosh(),
        plan: plan(mosh()),
        terminal: terminal,
        session: session,
        udpAuthority: '10.0.2.2:60101',
        verifyHostKey: (_, __, ___) async => true,
      );
      return (tab, tab.plugin! as MoshTerminalProvider, terminal);
    }

    test('输入只有一个出口：每次终端输入写一次、字节原样；输出原样进终端', () async {
      final (tab, link, terminal) = await attach();
      terminal.sendText('你好');
      terminal.sendText('\x7f');
      terminal.sendText('\r');
      expect(plugin.writes.map((c) => (c.arguments as Map)['bytes'] as List<int>),
          [utf8.encode('你好'), [0x7f], [0x0d]]);
      expect(link.inputEvents, 3);
      expect(link.session.writeCount, 3);
      // 输出：多字节字符被分块切开也拼得回去（分块边界是插件 FD 读的边界）。
      await plugin.state(link.session, 1, 'active');
      final bytes = utf8.encode('中文 ok');
      await plugin.output(link.session, bytes.sublist(0, 2));
      await plugin.output(link.session, bytes.sublist(2));
      await pumpEventQueue();
      expect(terminal.allText(), contains('中文 ok'));
      await tab.close();
    });

    test('改尺寸：打开中先记下，运行起来只发最新的那次', () async {
      final (tab, link, terminal) = await attach();
      terminal.terminal.resize(90, 30);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      terminal.terminal.resize(120, 40);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(plugin.calls.where((c) => c.method == 'resizeSession'), isEmpty);
      await plugin.state(link.session, 1, 'active');
      final resizes = plugin.calls.where((c) => c.method == 'resizeSession');
      expect(resizes.map((c) => ((c.arguments as Map)['cols'], (c.arguments as Map)['rows'])),
          [(120, 40)]);
      await tab.close();
    });

    test('会话结束：输入绑定解除，之后的按键丢掉，不排队', () async {
      final (tab, link, terminal) = await attach();
      await plugin.state(link.session, 1, 'active');
      await plugin.providerDied(link.session);
      expect(link.active, isFalse);
      expect(tab.done, completes);
      terminal.sendText('rm -rf /tmp/x\r');
      expect(plugin.writes, isEmpty);
      expect(link.endNotice, contains('pkill mosh-server'));
    });
  });

  group('结束原因说成人话（X08 留下的 failed:exit-N）', () {
    late MoshPluginHarness plugin;
    setUp(() => plugin = MoshPluginHarness());
    tearDown(() => plugin.dispose());

    Future<PluginTerminalSession> open() async => plugin.open(
          await plugin.prepare(),
          cols: 80,
          rows: 24,
          target: MoshSessionTarget(
            '10.0.2.2',
            MoshBootstrap.parse(
                utf8.encode('MOSH CONNECT 60101 v450/k6rhyS3hwDL4ejCIQ\n')),
          ),
        );

    test('exit-1：UDP 不通最常见；远端可能留着 mosh-server', () async {
      final s = await open();
      await plugin.state(s, 1, 'active');
      await plugin.state(s, 2, 'failed:exit-1');
      expect(s.phase, SessionPhase.interrupted);
      expect(s.failure, 'exit-1');
      final text = describeMoshEnd(s);
      expect(text, contains('退出码 1'));
      expect(text, contains('UDP 到不了服务器'));
      expect(text, contains('远端可能还有旧会话'));
      expect(moshEndNotice(s), contains('不会重发断开前的输入'));
    });

    test('被信号结束：137 说成强制结束（信号 9），其他信号报号', () async {
      final a = await open();
      await plugin.state(a, 1, 'failed:exit-137');
      expect(describeMoshEnd(a), contains('强制结束（信号 9）'));
      final b = await open();
      await plugin.state(b, 1, 'failed:exit-139');
      expect(describeMoshEnd(b), contains('信号 11'));
    });

    test('远端 shell 正常退出：只说会话结束、不会自动重连', () async {
      final s = await open();
      await plugin.state(s, 1, 'active');
      await plugin.state(s, 2, 'closed');
      expect(describeMoshEnd(s), '远端 shell 已退出，Mosh 会话结束。');
      expect(moshEndNotice(s), isNot(contains('无法确认')));
    });

    test('插件死了、被撤销：各说各的，都提醒远端可能有旧会话', () async {
      final a = await open();
      await plugin.providerDied(a);
      expect(a.phase, SessionPhase.providerDied);
      expect(describeMoshEnd(a), contains('插件进程没了'));
      final b = await open();
      plugin.registry.revoke('xwshun.mosh');
      await pumpEventQueue();
      await plugin.state(b, 1, 'closed');
      expect(b.stopConfirmed, isTrue);
      expect(describeMoshEnd(b), contains('本 App 关掉了这个 Mosh 会话'));
    });
  });

  group('会话控制器：Mosh 主机走插件，不走 SSH 终端', () {
    const secureStorage =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    late MoshPluginHarness plugin;
    late _FakeBootstrapSsh ssh;
    late ProviderContainer container;
    late SessionController controller;

    setUp(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorage, (call) async => null);
      SharedPreferences.setMockInitialValues({});
      plugin = MoshPluginHarness();
      ssh = _FakeBootstrapSsh();
      final repository = await VaultRepository.open();
      container = ProviderContainer(overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
        sshServiceProvider.overrideWithValue(ssh),
        moshRuntimeProvider.overrideWithValue(plugin),
      ]);
      controller = container.read(sessionControllerProvider.notifier);
      await container.read(vaultControllerProvider.notifier).ready();
    });

    tearDown(() {
      container.dispose();
      plugin.dispose();
    });

    Future<bool> accept(HostProfile _, String __, String ___) async => true;

    test('选了代理：在任何网络动作之前失败，失败页有原因和下一步', () async {
      await expectLater(
        controller.connect(mosh({'proxyConfig': socks}), accept),
        throwsA(isA<MoshRouteUnsupported>()),
      );
      expect(ssh.bootstraps, 0);
      expect(ssh.shells, 0);
      expect(plugin.prepareCount, 0);
      final pending = controller.state.pendingConnections.single;
      expect(pending.phase, PendingConnectionPhase.failed);
      expect(connectionHint(pending.error!), contains('改回 SSH'));
    });

    test('插件不能用：停在本机这一步，不去服务器上启动任何东西', () async {
      plugin.unavailable = const MoshPluginUnavailable('Mosh 插件还没批准');
      await expectLater(controller.connect(mosh(), accept),
          throwsA(isA<MoshPluginUnavailable>()));
      expect(ssh.bootstraps, 0);
      expect(plugin.opens, isEmpty);
    });

    test('连上、插件死了：标签留着说明原因，不自动重连、不再引导；关标签只关一次', () async {
      expect(await controller.connect(mosh(), accept), isTrue);
      expect(ssh.bootstraps, 1);
      expect(ssh.shells, 0, reason: 'Mosh 主机不开 SSH 终端');
      final tab = controller.state.sessions.single;
      final link = tab.plugin! as MoshTerminalProvider;
      await plugin.state(link.session, 1, 'active');
      await plugin.providerDied(link.session);
      await pumpEventQueue();
      expect(tab.connected, isFalse);
      expect(tab.autoRestoreBlocked, isTrue);
      expect(tab.terminal.allText().replaceAll('\n', ''), contains('远端可能还有旧会话'));
      await controller.reconnectDisconnected();
      controller.setBackgrounded(true);
      controller.setBackgrounded(false);
      await pumpEventQueue();
      expect(ssh.bootstraps, 1);
      expect(ssh.shells, 0);
      await controller.close(0);
      expect(controller.state.sessions, isEmpty);
    });

    test('引导途中终止：插件一次都不调用', () async {
      ssh.gate = Completer<void>();
      final result = controller.connect(mosh(), accept);
      await pumpEventQueue();
      controller.cancelPendingConnection(
          controller.state.pendingConnections.single.id);
      ssh.gate!.complete();
      expect(await result, isFalse);
      expect(plugin.opens, isEmpty);
    });
  });
}

/// 只替换 SSH 引导：返回一份固定的材料，记次数。普通 SSH 终端一旦被调用就记下来（Mosh 主机不该走它）。
class _FakeBootstrapSsh extends SshService {
  var bootstraps = 0;
  var shells = 0;
  Completer<void>? gate;

  @override
  Future<MoshBootstrapOutcome> bootstrapMosh({
    required RoutePlan plan,
    required HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
    required ConnectionAttempt attempt,
    (int, int) portRange = MoshBootstrap.defaultPortRange,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    bootstraps++;
    await gate?.future;
    return MoshBootstrapOutcome(
      '10.0.2.2',
      MoshBootstrap.parse(
          utf8.encode('MOSH CONNECT 60101 v450/k6rhyS3hwDL4ejCIQ\n')),
    );
  }

  @override
  Future<ActiveTerminalSession> connect({
    required String sessionId,
    required HostProfile host,
    List<HostProfile> hosts = const [],
    List<SshKeyProfile> keys = const [],
    List<ProxyProfile> proxyProfiles = const [],
    RoutePlan? routePlan,
    required HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
    required TerminalSessionAdapter terminal,
    ConnectionPurpose purpose = ConnectionPurpose.fresh,
    ConnectionAttempt? attempt,
    TmuxTarget? tmuxAttach,
  }) {
    shells++;
    throw StateError('Mosh 主机走到了 SSH 终端');
  }
}
