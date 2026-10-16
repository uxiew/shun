import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/connection_lifecycle.dart';
import 'package:shun/application/connection_switch.dart';
import 'package:shun/application/mosh_session.dart';
import 'package:shun/application/port_forward_controller.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/plugins/mosh_bootstrap.dart';
import 'package:shun/domain/plugins/mosh_install_hint.dart';
import 'package:shun/domain/tmux/tmux_target.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/terminal/terminal_session_adapter.dart';
import 'package:shun/infrastructure/tmux/tmux_protocol.dart';
import 'package:shun/infrastructure/tmux/tmux_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures/mosh_plugin_harness.dart';

// R42：终端里切换 SSH / Mosh、设为默认、Mosh 重新连接。控制器和插件会话管理是真的（平台通道是假的），
// SSH、tmux 查询、端口转发是替身：这里只验编排的规矩。真 mosh-server + 真 tmux 上「会话 id 不变」
// 见 mosh_fixture_test.dart 的 R42 组，真插件见 integration_test/r42_switch_test.dart。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late MoshPluginHarness plugin;
  late _Ssh ssh;
  late _Tmux tmux;
  late _Forwards forwards;
  late ProviderContainer container;
  late SessionController controller;
  late VaultController vault;

  HostProfile box([Map<String, Object?> extra = const {}]) => HostProfile({
        'id': 'h1',
        'label': 'box',
        'hostname': 'box.example.com',
        'port': 22,
        'username': 'ops',
        'password': 'R42-LOGIN-SECRET',
        'protocol': 'ssh',
        ...extra,
      });

  const target = TmuxTarget(
    hostKey: 'box.example.com:22',
    unixUser: 'ops',
    uid: 1000,
    socket: TmuxSocketSpec.standard(),
    server: TmuxServerIdentity(
        socketPath: '/tmp/tmux-1000/default', pid: 70, startTime: 1700000000),
    sessionId: r'$3',
    sessionCreated: 1700000100,
    displayName: 'work',
  );

  Future<bool> accept(HostProfile _, String __, String ___) async => true;

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// 起一套新的控制器（存储不清）：第二次调用就是「App 被结束后重新打开」。
  Future<void> launch() async {
    final repository = await VaultRepository.open();
    container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      sshServiceProvider.overrideWithValue(ssh),
      moshRuntimeProvider.overrideWithValue(plugin),
      tmuxServiceProvider.overrideWithValue(tmux),
      portForwardControllerProvider.overrideWith((ref) => forwards),
    ]);
    vault = container.read(vaultControllerProvider.notifier);
    await vault.ready();
    controller = container.read(sessionControllerProvider.notifier);
  }

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async => null);
    SharedPreferences.setMockInitialValues({});
    plugin = MoshPluginHarness();
    ssh = _Ssh();
    tmux = _Tmux();
    forwards = _Forwards();
    await launch();
    await vault.upsertHost(box());
  });

  tearDown(() {
    container.dispose();
    plugin.dispose();
  });

  ActiveTerminalSession tab([int index = 0]) =>
      controller.state.sessions[index];

  /// 一个附着 tmux 的 SSH 标签（和「系统管理 → tmux」附着出来的一样：临时主机、冻结的路线）。
  Future<ActiveTerminalSession> sshTmuxTab() async {
    expect(await controller.connect(box(), accept), isTrue);
    expect(await controller.openTmuxTerminal(tab(0), target), isTrue);
    await settle();
    return tab(1);
  }

  group('菜单：能不能切、为什么不能', () {
    test('直连、插件能用：普通标签另开，tmux 标签原地；主机默认就是 SSH 时没有「设为默认」', () async {
      final tmuxTab = await sshTmuxTab();
      final plain = await controller.transportMenu(tab(0).id);
      expect(plain!.current, TabTransport.ssh);
      expect(plain.switchTo.to, TabTransport.mosh);
      expect(plain.switchTo.inPlace, isFalse);
      expect(plain.switchTo.blocked, isNull);
      expect(plain.setDefault, isNull);
      final inPlace = await controller.transportMenu(tmuxTab.id);
      expect(inPlace!.switchTo.inPlace, isTrue);
      expect(inPlace.switchTo.blocked, isNull);
      expect(plugin.prepareCount, 0, reason: '菜单只查本机状态，不连插件');
      expect(ssh.starts + ssh.bootstraps, 0, reason: '菜单不碰服务器');
    });

    test('经代理、插件没批准、已断开：Mosh 项变灰，写原因', () async {
      await vault.upsertHost(box({
        'proxyConfig': {'type': 'socks5', 'host': '127.0.0.1', 'port': 1055},
      }));
      expect(await controller.connect(box(), accept), isTrue);
      var menu = await controller.transportMenu(tab().id);
      expect(menu!.switchTo.blocked, contains('Mosh 只能直连'));
      expect(menu.switchTo.blocked, contains('SOCKS5 代理 127.0.0.1:1055'));
      await vault.upsertHost(box());
      plugin.unavailable = const MoshPluginUnavailable('Mosh 插件还没批准');
      menu = await controller.transportMenu(tab().id);
      expect(menu!.switchTo.blocked, 'Mosh 插件还没批准');
      plugin.unavailable = null;
      // SSH 标签断了会自动恢复；用结束了的 Mosh 标签看「已断开」。
      await vault.upsertHost(box({'protocol': 'mosh'}));
      expect(await controller.connect(box(), accept), isTrue);
      await plugin.providerDied((tab(1).plugin! as MoshTerminalProvider).session);
      await settle();
      menu = await controller.transportMenu(tab(1).id);
      expect(menu!.switchTo.blocked, contains('已经断开'));
    });

    test('Telnet、AI 标签、系统管理的一次性命令：没有徽标或不让切', () async {
      expect(await controller.connect(box(), accept), isTrue);
      expect(
          await controller.openManagedTerminal(tab(0),
              label: '重启 nginx', command: 'systemctl restart nginx'),
          isTrue);
      final managed = await controller.transportMenu(tab(1).id);
      expect(managed!.switchTo.blocked, contains('一次性命令'));
      await vault.upsertHost(box({'id': 't1', 'protocol': 'telnet', 'port': 23}));
      expect(
          await controller.connect(
              box({'id': 't1', 'protocol': 'telnet', 'port': 23}), accept),
          isTrue);
      expect(await controller.transportMenu(tab(2).id), isNull);
    });
  });

  group('普通标签：另开一个，原标签不动', () {
    test('SSH → Mosh：新开 Mosh 标签，原 SSH 标签还是那一个、还连着；不跑启动命令', () async {
      await vault.upsertHost(box({'startupCommand': 'echo R42-STARTUP'}));
      expect(await controller.connect(box(), accept), isTrue);
      final original = tab(0);
      expect(
          await controller.switchTransport(original.id, verifyHostKey: accept),
          isTrue);
      expect(controller.state.sessions, hasLength(2));
      expect(identical(tab(0), original), isTrue);
      expect(original.connected, isTrue);
      expect(original.closedByUser, isFalse);
      final mosh = tab(1);
      expect(mosh.plugin, isA<MoshTerminalProvider>());
      expect(transportOf(mosh), TabTransport.mosh);
      expect(mosh.host.startupCommand, isNull);
      expect(ssh.bootstraps, 1);
      expect(plugin.writes, isEmpty);
      expect(ssh.writes, isEmpty, reason: '原 SSH 标签没收到任何字节');
      // 保险库里的主机不变。
      expect((await vault.ready()).hosts.single.protocol, HostProtocol.ssh);
    });

    test('Mosh → SSH：新开 SSH 标签，Mosh 会话不关', () async {
      await vault.upsertHost(box({'protocol': 'mosh'}));
      expect(await controller.connect(box({'protocol': 'mosh'}), accept), isTrue);
      final mosh = tab(0);
      final link = mosh.plugin! as MoshTerminalProvider;
      expect(
          await controller.switchTransport(mosh.id, verifyHostKey: accept),
          isTrue);
      expect(controller.state.sessions, hasLength(2));
      expect(identical(tab(0), mosh), isTrue);
      expect(link.active, isTrue);
      expect(plugin.calls.where((c) => c.method == 'closeSession'), isEmpty);
      expect(transportOf(tab(1)), TabTransport.ssh);
      expect(ssh.shells, 1);
    });
  });

  group('tmux 标签原地切到 Mosh', () {
    test('同一个标签、同一个 tmux 会话；核对到 Mosh 的客户端才换，然后只分离旧的 SSH 客户端、关 SSH；不发任何输入', () async {
      final old = await sshTmuxTab();
      final oldClient = old.sshClient!;
      final result = await controller.switchTransport(old.id, verifyHostKey: accept);
      expect(result, isTrue);
      final now = tab(1);
      expect(now.id, old.id, reason: '原地：标签 id、位置不变');
      expect(controller.state.sessions, hasLength(2));
      expect(now.plugin, isA<MoshTerminalProvider>());
      expect(now.tmux!.target.sameAs(target), isTrue);
      expect(now.tmux!.clientTty, '/dev/pts/9', reason: '记下的是 Mosh 那一侧的客户端');
      // 引导跑在这个标签已登录的 SSH 上，带着完整的 tmux 目标；没有新登录。
      expect(ssh.starts, 1);
      expect(identical(ssh.lastStartClient, oldClient), isTrue);
      expect(ssh.lastStartTmux!.sameAs(target), isTrue);
      expect(ssh.lastStartPeer!.address, '10.0.2.2');
      expect(ssh.shells, 2, reason: '只有最开始的两次 SSH，切换没有再登录');
      expect(tmux.lastParentPid, 4321, reason: '按 mosh-server 报的 pid 找它的子进程');
      expect(tmux.detached.single.clientTty, old.tmux!.clientTty);
      expect(tmux.detached.single.clientPid, old.tmux!.clientPid);
      expect(old.closedByUser, isTrue);
      expect(old.connected, isFalse);
      expect(ssh.writes, isEmpty);
      expect(plugin.writes, isEmpty);
      final open = (plugin.opens.single.arguments as Map).cast<String, Object?>();
      expect(open['udpHost'], '10.0.2.2');
      expect(controller.state.switching, isEmpty);
    });

    test('核对不过（目标不在了、Mosh 提前结束）：不切，原标签一点不动，刚开的 Mosh 关掉', () async {
      final old = await sshTmuxTab();
      tmux.clientUnderError = const TmuxTargetGoneException('原来的 tmux 会话已经不在了');
      await expectLater(
        controller.switchTransport(old.id, verifyHostKey: accept),
        throwsA(isA<TmuxTargetGoneException>()),
      );
      expect(identical(tab(1), old), isTrue);
      expect(old.connected, isTrue);
      expect(tmux.detached, isEmpty);
      expect(plugin.calls.where((c) => c.method == 'closeSession'), hasLength(1));

      tmux.clientUnderError = null;
      tmux.attachAfterPolls = 1000;
      final pending = controller.switchTransport(old.id, verifyHostKey: accept);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = plugin.manager.sessions.single;
      await plugin.providerDied(session);
      await expectLater(pending, throwsA(isA<MoshTmuxAttachException>()));
      expect(identical(tab(1), old), isTrue);
      expect(old.connected, isTrue);
      expect(tmux.detached, isEmpty);
    });

    test('缺 mosh-server：带着这台服务器的安装提示失败，插件一次都不开', () async {
      final old = await sshTmuxTab();
      ssh.startError = MoshServerMissing(moshInstallHint(
          parseOsRelease('ID=debian\nPRETTY_NAME="Debian 13"\n')));
      await expectLater(
        controller.switchTransport(old.id, verifyHostKey: accept),
        throwsA(isA<MoshServerMissing>().having(
            (e) => e.hint.command, 'command', 'sudo apt-get install mosh')),
      );
      expect(plugin.opens, isEmpty);
      expect(identical(tab(1), old), isTrue);
    });

    test('这条 SSH 上挂着端口转发：只停用户看过的那几条；多出来的就不切', () async {
      final old = await sshTmuxTab();
      final a = ActivePortForward(
          id: 'a', kind: ForwardKind.dynamic, localPort: 1080, client: old.sshClient);
      final b = ActivePortForward(
          id: 'b',
          kind: ForwardKind.local,
          localPort: 8080,
          remoteHost: '127.0.0.1',
          remotePort: 80,
          client: old.sshClient);
      final elsewhere = ActivePortForward(
          id: 'c', kind: ForwardKind.dynamic, localPort: 1081, client: tab(0).sshClient);
      forwards.items.addAll([a, b, elsewhere]);
      expect(forwards.forwardsOn(old).map((f) => f.id), ['a', 'b']);
      await expectLater(
        controller.switchTransport(old.id,
            verifyHostKey: accept, stoppingForwards: {'a'}),
        throwsA(isA<ForwardsChangedException>()),
      );
      expect(forwards.stopped, isEmpty);
      expect(identical(tab(1), old), isTrue);
      expect(
          await controller.switchTransport(old.id,
              verifyHostKey: accept, stoppingForwards: {'a', 'b'}),
          isTrue);
      expect(forwards.stopped, ['a', 'b']);
      expect(forwards.items.map((f) => f.id), ['c'], reason: '别的标签的转发不动');
    });

    test('切换中取消、关标签：新的一边全关，不分离任何客户端', () async {
      final old = await sshTmuxTab();
      tmux.attachAfterPolls = 1000;
      final pending = controller.switchTransport(old.id, verifyHostKey: accept);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(controller.state.switching[old.id]!.describe(), contains('核对 tmux 会话'));
      controller.cancelSwitch(old.id);
      expect(await pending, isFalse);
      expect(identical(tab(1), old), isTrue);
      expect(old.connected, isTrue);
      expect(tmux.detached, isEmpty);
      await settle();
      expect(plugin.calls.where((c) => c.method == 'closeSession'), hasLength(1));
      expect(controller.state.switching, isEmpty);
    });
  });

  group('Mosh 的 tmux 标签原地切回 SSH', () {
    test('新 SSH 按 R21 附着同一个目标、确认在了才换；然后分离 Mosh 那一侧、关 Mosh', () async {
      final first = await sshTmuxTab();
      expect(await controller.switchTransport(first.id, verifyHostKey: accept),
          isTrue);
      final mosh = tab(1);
      final moshSide = mosh.tmux!;
      tmux.detached.clear();
      expect(await controller.switchTransport(mosh.id, verifyHostKey: accept),
          isTrue);
      final back = tab(1);
      expect(back.id, mosh.id);
      expect(back.isSsh, isTrue);
      expect(back.tmux!.target.sameAs(target), isTrue);
      expect(ssh.lastTmuxAttach!.sameAs(target), isTrue);
      expect(tmux.presentChecks, greaterThan(0));
      expect(tmux.detached.single.clientTty, moshSide.clientTty);
      expect(mosh.closedByUser, isTrue);
      expect(plugin.writes, isEmpty);
      expect(ssh.writes, isEmpty);
    });

    test('新 SSH 没附着上：不切，Mosh 标签不动，新 SSH 关掉', () async {
      final first = await sshTmuxTab();
      expect(await controller.switchTransport(first.id, verifyHostKey: accept),
          isTrue);
      final mosh = tab(1);
      tmux.present = false;
      await expectLater(
        controller.switchTransport(mosh.id, verifyHostKey: accept),
        throwsA(isA<TmuxCommandException>()),
      );
      expect(identical(tab(1), mosh), isTrue);
      expect(mosh.connected, isTrue);
      expect(ssh.lastSession!.closedByUser, isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('Mosh 重新连接', () {
    test('普通 Mosh 标签：新会话顶替原来的位置，旧的画面留到新的连上；不重发输入', () async {
      // connect 按 id 取保险库里的最新版本：先连 SSH，再把主机改成 Mosh 连第二个。
      expect(await controller.connect(box(), accept), isTrue);
      await vault.upsertHost(box({'protocol': 'mosh'}));
      expect(await controller.connect(box(), accept), isTrue);
      final old = tab(1);
      await plugin.providerDied((old.plugin! as MoshTerminalProvider).session);
      await settle();
      expect(old.connected, isFalse);
      expect(old.restoreHold!.message, contains('新开一个会话'));
      old.terminal.sendText('typed-after-end\r');
      await controller.reconnect(old.id, verifyHostKey: accept);
      expect(controller.state.sessions, hasLength(2));
      final next = tab(1);
      expect(identical(next, old), isFalse);
      expect(next.connected, isTrue);
      expect(ssh.bootstraps, 2);
      expect(old.terminal.isDisposed, isTrue);
      expect(plugin.writes, isEmpty, reason: '断开后打的字不重发给新会话');
    });

    test('Mosh-tmux 标签：新会话只附着原来那个目标；目标不在了就停、旧标签留着', () async {
      final first = await sshTmuxTab();
      expect(await controller.switchTransport(first.id, verifyHostKey: accept),
          isTrue);
      final mosh = tab(1);
      await plugin.providerDied((mosh.plugin! as MoshTerminalProvider).session);
      await settle();
      expect(mosh.restoreHold!.message, contains('核对还是不是原来那个'));
      expect(mosh.terminal.allText().replaceAll('\n', ''), contains('会话和里面的程序留在服务器上'));

      ssh.tmuxBootstrapError = const TmuxTargetGoneException('原来的 tmux 会话已经不在了');
      await expectLater(
        controller.reconnect(mosh.id, verifyHostKey: accept),
        throwsA(isA<TmuxTargetGoneException>()),
      );
      expect(identical(tab(1), mosh), isTrue);
      expect(controller.state.pendingConnections.single.phase,
          PendingConnectionPhase.failed);
      controller.dismissPending(controller.state.pendingConnections.single.id);

      ssh.tmuxBootstrapError = null;
      await controller.reconnect(mosh.id, verifyHostKey: accept);
      final next = tab(1);
      expect(identical(next, mosh), isFalse);
      expect(next.plugin, isA<MoshTerminalProvider>());
      expect(next.tmux!.target.sameAs(target), isTrue);
      expect(ssh.lastTmuxBootstrap!.sameAs(target), isTrue);
    });
  });

  group('设为默认', () {
    test('只在和主机默认不同时出现；改的只是保险库里的协议，Mosh 选项留着', () async {
      await vault.upsertHost(box({'shunMoshPorts': '60001:60010'}));
      expect(await controller.connect(box(), accept), isTrue);
      expect(await controller.switchTransport(tab(0).id, verifyHostKey: accept),
          isTrue);
      final moshMenu = await controller.transportMenu(tab(1).id);
      expect(moshMenu!.setDefault!.transport, TabTransport.mosh);
      expect(moshMenu.setDefault!.blocked, isNull);
      await controller.setDefaultTransport(tab(1).id);
      final stored = (await vault.ready()).hosts.single;
      expect(stored.protocol, HostProtocol.mosh);
      expect(stored.data['shunMoshPorts'], '60001:60010');
      expect(stored.password, 'R42-LOGIN-SECRET');
      expect(transportOf(tab(0)), TabTransport.ssh, reason: '开着的标签不变');
      final sshMenu = await controller.transportMenu(tab(0).id);
      expect(sshMenu!.setDefault!.transport, TabTransport.ssh);
      expect((await controller.transportMenu(tab(1).id))!.setDefault, isNull);
    });

    test('经代理的主机不能把 Mosh 设为默认', () async {
      await vault.upsertHost(box({'protocol': 'mosh'}));
      expect(await controller.connect(box({'protocol': 'mosh'}), accept), isTrue);
      expect(await controller.switchTransport(tab(0).id, verifyHostKey: accept),
          isTrue);
      await controller.setDefaultTransport(tab(1).id);
      await vault.upsertHost(box({
        'proxyConfig': {'type': 'socks5', 'host': '127.0.0.1', 'port': 1055},
      }));
      final menu = await controller.transportMenu(tab(0).id);
      expect(menu!.setDefault!.blocked, contains('Mosh 只能直连'));
      await expectLater(controller.setDefaultTransport(tab(0).id),
          throwsA(isA<TransportSwitchBlocked>()));
      expect((await vault.ready()).hosts.single.protocol, HostProtocol.ssh);
    });
  });

  group('App 被结束后放回来、凭据副本清掉后', () {
    test('切到 Mosh 的 tmux 标签：放回来还是 Mosh，点重新连接走 Mosh 附着同一个目标，不变成 SSH', () async {
      final first = await sshTmuxTab();
      expect(await controller.switchTransport(first.id, verifyHostKey: accept),
          isTrue);
      await settle();
      final saved = (await SharedPreferences.getInstance())
          .getString('shun.r22.restorableTabs')!;
      expect(saved, contains('"protocol":"mosh"'));
      expect(saved, isNot(contains('R42-LOGIN-SECRET')));

      container.dispose();
      final shellsBefore = ssh.shells;
      final bootstrapsBefore = ssh.bootstraps;
      await launch();
      await settle();
      final back = controller.state.sessions.firstWhere((s) => s.id == first.id);
      expect(back.restored, isTrue);
      expect(back.connected, isFalse);
      expect(transportOf(back), TabTransport.mosh);
      expect(ssh.shells, shellsBefore, reason: '不自动连');

      await controller.reconnect(back.id, verifyHostKey: accept);
      expect(ssh.shells, shellsBefore, reason: '没有悄悄改成 SSH 附着');
      expect(ssh.bootstraps, bootstrapsBefore + 1);
      expect(ssh.lastTmuxBootstrap!.sameAs(target), isTrue);
      final now = controller.state.sessions
          .firstWhere((s) => s.plugin is MoshTerminalProvider);
      expect(now.tmux!.target.sameAs(target), isTrue);
      expect(controller.state.sessions.where((s) => identical(s, back)), isEmpty);
    });

    test('标签记住自己的 SSH / Mosh；读到别的协议就不放回', () {
      final tab = RestorableTab(
          id: 'x', hostId: 'h1', label: 'tmux: work', tmux: target, protocol: HostProtocol.mosh);
      final back = RestorableTab.fromJson(jsonDecode(jsonEncode(tab.toJson())))!;
      expect(back.protocol, HostProtocol.mosh);
      expect(back.tmux!.sameAs(target), isTrue);
      expect(
          RestorableTab.fromJson({'id': 'x', 'hostId': 'h1', 'label': 'l'})!.protocol,
          isNull);
      expect(
          RestorableTab.fromJson(
              {'id': 'x', 'hostId': 'h1', 'label': 'l', 'protocol': 'telnet'}),
          isNull);
    });

    test('保险库默认 Mosh、标签是 SSH：补回凭据按标签自己的方式算，不当成路线变了', () {
      final sshPlan = resolveRoutePlan(box(), hosts: [box()], proxyProfiles: const []);
      final hosts = [box({'protocol': 'mosh'})];
      final back = rehydrateRoutePlan(sshPlan.withoutSecrets(),
          sourceHostId: 'h1', hosts: hosts, proxyProfiles: const [], keys: const []);
      expect(back.protocol, HostProtocol.ssh);
      expect(back.target.host.password, 'R42-LOGIN-SECRET');
      // 地址变了照样拒绝。
      expect(
        () => rehydrateRoutePlan(sshPlan.withoutSecrets(),
            sourceHostId: 'h1',
            hosts: [box({'protocol': 'mosh', 'hostname': 'other.example.com'})],
            proxyProfiles: const [],
            keys: const []),
        throwsA(isA<RouteChangedException>()),
      );
    });
  });
}

/// 一直不说话的 socket：让替身会话有一个真的 SSHClient 对象（端口转发、切换都按它的身份认），但不联网。
class _QuietSocket implements SSHSocket {
  final _in = StreamController<Uint8List>();
  final _out = StreamController<List<int>>();
  _QuietSocket() {
    _out.stream.listen((_) {});
  }

  @override
  Stream<Uint8List> get stream => _in.stream;
  @override
  StreamSink<List<int>> get sink => _out.sink;
  @override
  Future<void> get done => _in.done;
  @override
  Future<void> close() async => destroy();
  @override
  Future<void> flush() async {}
  @override
  void destroy() {
    unawaited(_in.close());
    unawaited(_out.close());
  }
}

class _TestSession extends ActiveTerminalSession {
  _TestSession({
    required super.id,
    required super.host,
    required super.terminal,
    required super.verifyHostKey,
    super.keyboardInteractive,
    super.sshClients,
    super.routePlan,
    super.tmux,
    super.directPeer,
    super.binding,
  });

  final _done = Completer<void>();

  void drop() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;

  @override
  void abort() {
    super.abort();
    drop();
  }
}

class _Ssh extends SshService {
  var shells = 0;
  var bootstraps = 0;
  var starts = 0;
  var tty = 0;
  final writes = <List<int>>[];
  SSHClient? lastStartClient;
  TmuxTarget? lastStartTmux;
  InternetAddress? lastStartPeer;
  TmuxTarget? lastTmuxAttach;
  TmuxTarget? lastTmuxBootstrap;
  _TestSession? lastSession;
  Object? startError;
  Object? tmuxBootstrapError;

  static MoshBootstrapOutcome outcome() => MoshBootstrapOutcome(
        '10.0.2.2',
        MoshBootstrap.parse(utf8.encode('MOSH CONNECT 60101 v450/k6rhyS3hwDL4ejCIQ\n'
            '[mosh-server detached, pid = 4321]\n')),
      );

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
  }) async {
    shells++;
    lastTmuxAttach = tmuxAttach;
    final plan = routePlan ??
        resolveRoutePlan(host,
            hosts: hosts, proxyProfiles: proxyProfiles, keys: keys);
    final client = SSHClient(_QuietSocket(), username: 'ops');
    final binding = terminal.bind(writes.add);
    attempt?.handOver();
    tty++;
    return lastSession = _TestSession(
      id: sessionId,
      host: host,
      terminal: terminal,
      verifyHostKey: verifyHostKey,
      keyboardInteractive: keyboardInteractive,
      sshClients: [client],
      routePlan: plan,
      directPeer: InternetAddress('10.0.2.2'),
      tmux: tmuxAttach == null
          ? null
          : TmuxClientBinding(
              target: tmuxAttach, clientTty: '/dev/pts/$tty', clientPid: 100 + tty),
      binding: binding,
    );
  }

  @override
  Future<MoshBootstrapOutcome> bootstrapMosh({
    required RoutePlan plan,
    required HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
    required ConnectionAttempt attempt,
    (int, int) portRange = MoshBootstrap.defaultPortRange,
    String? serverPath,
    String? locale,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    bootstraps++;
    return outcome();
  }

  @override
  Future<T> bootstrapMoshTmux<T>({
    required RoutePlan plan,
    required HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
    required ConnectionAttempt attempt,
    (int, int) portRange = MoshBootstrap.defaultPortRange,
    String? serverPath,
    String? locale,
    required TmuxTarget tmux,
    required Future<T> Function(SSHClient client, MoshBootstrapOutcome outcome)
        then,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    bootstraps++;
    lastTmuxBootstrap = tmux;
    if (tmuxBootstrapError case final error?) throw error;
    final client = SSHClient(_QuietSocket(), username: 'ops');
    try {
      return await then(client, outcome());
    } finally {
      client.close();
    }
  }

  @override
  Future<MoshBootstrapOutcome> startMoshServer(
    SSHClient client, {
    required InternetAddress peer,
    (int, int) portRange = MoshBootstrap.defaultPortRange,
    String? serverPath,
    String? locale,
    TmuxTarget? tmux,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    starts++;
    lastStartClient = client;
    lastStartTmux = tmux;
    lastStartPeer = peer;
    if (startError case final error?) throw error;
    return outcome();
  }
}

class _Tmux extends TmuxService {
  _Tmux() : super(probeTimeout: Duration.zero);

  var attachAfterPolls = 1;
  var polls = 0;
  int? lastParentPid;
  Object? clientUnderError;
  final detached = <TmuxClientBinding>[];
  var present = true;
  var presentChecks = 0;

  @override
  Future<TmuxClientBinding?> clientUnder(
    SSHClient client,
    TmuxTarget target,
    int parentPid,
  ) async {
    lastParentPid = parentPid;
    if (clientUnderError case final error?) throw error;
    polls++;
    if (polls < attachAfterPolls) return null;
    polls = 0;
    return TmuxClientBinding(
        target: target, clientTty: '/dev/pts/9', clientPid: 999);
  }

  @override
  Future<void> detach(SSHClient client, TmuxClientBinding binding) async =>
      detached.add(binding);

  @override
  Future<bool> clientPresent(SSHClient client, TmuxClientBinding binding) async {
    presentChecks++;
    return present;
  }
}

class _Forwards extends PortForwardController {
  final items = <ActivePortForward>[];
  final stopped = <String>[];

  @override
  List<ActivePortForward> forwardsOn(ActiveTerminalSession session) => [
        for (final item in items)
          if (identical(item.client, session.sshClient)) item,
      ];

  @override
  Future<void> stop(String id) async {
    stopped.add(id);
    items.removeWhere((item) => item.id == id);
  }
}
