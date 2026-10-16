import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/host_trust.dart';
import 'package:shun/application/mosh_session.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/plugins/mosh_bootstrap.dart';
import 'package:shun/domain/plugins/mosh_route.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures/mosh_fixture.dart';
import 'fixtures/mosh_plugin_harness.dart';
import 'fixtures/net/trap_server.dart';

import 'support/test_terminal.dart';

// X09：受控 bootstrap 连真实 OpenSSH + 官方 mosh-server（tool/mosh-fixture）。插件这一侧是假的平台通道
// （fixtures/mosh_plugin_harness.dart），所以这里测的是「宿主做了什么、交出了什么」：
// 真插件、真 UDP 会话在模拟器上测（integration_test/mosh_session_test.dart）。
// 计数来自测试环境的记账脚本（tool/mosh-fixture/counts.sh）：mosh-server 启动次数、安装/sudo 调用次数、sshd 登录次数。
// 没起环境时整组 skip，证据记 NOT_RUN。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = MoshFixture.load();
  final skip = fixture == null ? MoshFixture.skipReason : false;

  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late MoshPluginHarness plugin;
  late RecordingDialer dialer;
  late SshService ssh;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async => null);
    plugin = MoshPluginHarness();
    dialer = RecordingDialer();
    ssh = SshService(dialer: dialer.call);
  });

  tearDown(() async {
    plugin.dispose();
    // 引导成功但没有真客户端连上的 mosh-server 会等 60 秒才自己退出，别让它们串到下一条测试的计数里。
    if (fixture != null) await fixture.exec('pkill -x mosh-server; true');
  });

  Future<Map<String, int>> delta(
    Map<String, dynamic> before,
    Map<String, dynamic> after,
  ) async {
    int d(String key) => (after[key] as int) - (before[key] as int);
    int logins(String host) =>
        ((after['sshLogins'] as Map)[host] as int) -
        ((before['sshLogins'] as Map)[host] as int);
    return {
      'moshServerStarts': d('moshServerStarts'),
      'installAttempts': d('installAttempts'),
      'loginsMosh': logins('mosh'),
      'loginsNomosh': logins('nomosh'),
    };
  }

  Future<ActiveTerminalSession> connect(
    HostProfile host, {
    HostKeyVerifier? verify,
    List<HostProfile> hosts = const [],
    List<ProxyProfile> proxies = const [],
    List<ConnectionStage>? stages,
  }) {
    final attempt = ConnectionAttempt(onStage: stages?.add);
    return MoshBootstrapCoordinator(ssh, plugin).connect(
      sessionId: 'x09',
      host: host,
      plan: resolveRoutePlan(host, hosts: [host, ...hosts], proxyProfiles: proxies),
      verifyHostKey: verify ?? fixture!.verify,
      terminal: GhosttyTerminalAdapter(),
      attempt: attempt,
    );
  }

  /// 服务器上这台的 sshd 每条连接一个 sshd-session 进程；SSH 关了它就没了。
  /// 方括号是为了不数到执行这条 pgrep 的 sh 自己（它的命令行里也有这串字）。
  Future<int> sshSessions() async => int.parse(
      await fixture!.exec("pgrep -f '[s]shd-session: mosh' | wc -l"));

  group('MOS03 直连：SSH 引导，然后只把这次会话的材料交给插件', () {
    test('引导完 SSH 立刻断开、mosh-server 留着等 UDP；插件只拿到数字 IP、范围内端口、22 字节 key', () async {
      final f = fixture!;
      final before = await f.counts();
      final stages = <ConnectionStage>[];
      final session = await connect(f.host(), stages: stages);

      expect(plugin.opens, hasLength(1));
      final args = (plugin.opens.single.arguments as Map).cast<String, Object?>();
      expect(args.keys.toSet(), {
        'package', 'handle', 'generation', 'cols', 'rows', //
        'udpHost', 'udpPort', 'key',
      });
      expect(args['udpHost'], '127.0.0.1', reason: 'UDP 发往 SSH 实际连上的那个 IP');
      expect(args['udpPort'] as int, inInclusiveRange(60101, 60108));
      final key = args['key']! as Uint8List;
      expect(key, hasLength(22));
      expect(RegExp(r'^[A-Za-z0-9+/]{22}$').hasMatch(ascii.decode(key)), isTrue);

      // 两段：先 SSH（拨号、握手登录、启动 mosh-server），再交给插件走 UDP。
      expect(
        stages.map((s) => s.step).toSet().toList(),
        [
          ConnectionStep.plugin,
          ConnectionStep.dial,
          ConnectionStep.handshake,
          ConnectionStep.moshServer,
          ConnectionStep.moshUdp,
        ],
      );
      expect(stages.last.describe(), contains('UDP'));
      expect(stages.last.describe(), contains('127.0.0.1:${args['udpPort']}'));

      expect(session.isSsh, isFalse, reason: 'Mosh 标签不持有 SSH 连接');
      expect(session.sshClients, isEmpty);
      expect(session.plugin!.detail, 'UDP 127.0.0.1:${args['udpPort']}');

      final after = await f.counts();
      final d = await delta(before, after);
      expect(d['moshServerStarts'], 1);
      expect(d['loginsMosh'], 1);
      expect(d['installAttempts'], 0);
      expect(after['moshServerRunning'], greaterThanOrEqualTo(1));
      // SSH 那条连接已关：服务器上没有这个用户的 sshd-session 了，mosh-server 自己留着。
      var left = await sshSessions();
      for (var i = 0; i < 20 && left > 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        left = await sshSessions();
      }
      expect(left, 0);
      expect(dialer.dials, ['127.0.0.1:${f.sshPort}'], reason: '手机只拨了一次 TCP：SSH 那段');

      await session.close();
      expect(plugin.calls.where((c) => c.method == 'closeSession'), hasLength(1));
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

    test('取消发生在 mosh-server 已启动、还没交给插件时：插件一次都没被调用', () async {
      final f = fixture!;
      final attempt = ConnectionAttempt();
      attempt.onStage = (stage) {
        if (stage.step == ConnectionStep.moshServer) {
          // 远端命令已经发出去了，这时用户点了终止。
          scheduleMicrotask(attempt.cancel);
        }
      };
      final host = f.host();
      await expectLater(
        MoshBootstrapCoordinator(ssh, plugin).connect(
          sessionId: 'x09-cancel',
          host: host,
          plan: resolveRoutePlan(host, hosts: [host], proxyProfiles: const []),
          verifyHostKey: f.verify,
          terminal: GhosttyTerminalAdapter(),
          attempt: attempt,
        ),
        throwsA(isA<ConnectionCancelledException>()),
      );
      expect(plugin.opens, isEmpty);
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('MOS02 先核验主机，失败就停：不发临时 key、不安装、不 sudo', () {
    Future<void> expectNothingReachedPlugin() async {
      expect(plugin.opens, isEmpty);
      expect(plugin.writes, isEmpty);
    }

    test('第一次见的指纹：先问用户；拒绝 → 没登录、没启动 mosh-server', () async {
      final f = fixture!;
      final before = await f.counts();
      var asked = 0;
      Future<bool> verify(HostProfile host, String type, String fp) =>
          verifyHostKeyWithKnownHosts(
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
          );
      final error = await connect(f.host(), verify: verify)
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(asked, 1);
      expect(error, isA<RouteHopException>());
      expect((error! as RouteHopException).message, contains('指纹'));
      final d = await delta(before, await f.counts());
      expect(d, {
        'moshServerStarts': 0,
        'installAttempts': 0,
        'loginsMosh': 0,
        'loginsNomosh': 0,
      });
      await expectNothingReachedPlugin();
    }, skip: skip);

    test('指纹变了：直接拦下，不给「确认更新」，没登录、没启动', () async {
      final f = fixture!;
      final before = await f.counts();
      var askedNew = 0;
      String? reportedOld;
      Future<bool> verify(HostProfile host, String type, String fp) =>
          verifyHostKeyWithKnownHosts(
            knownHosts: [
              {
                'hostname': '127.0.0.1',
                'port': f.sshPort,
                'keyType': type,
                'fingerprint': 'SHA256:old-fingerprint-of-another-machine',
              },
            ],
            hostname: host.hostname,
            port: host.port,
            keyType: type,
            fingerprint: fp,
            confirmNew: () async {
              askedNew++;
              return true;
            },
            // 用户在「指纹变了」的提示里点了删除旧指纹：这次照样断开。
            onChanged: (old) async {
              reportedOld = old;
              return true;
            },
            save: (_) async {},
          );
      await expectLater(
        connect(f.host(), verify: verify),
        throwsA(isA<RouteHopException>()),
      );
      expect(askedNew, 0);
      expect(reportedOld, 'SHA256:old-fingerprint-of-another-machine');
      final d = await delta(before, await f.counts());
      expect(d['moshServerStarts'], 0);
      expect(d['loginsMosh'], 0);
      await expectNothingReachedPlugin();
    }, skip: skip);

    test('密码错：登录被拒，没启动 mosh-server', () async {
      final f = fixture!;
      final before = await f.counts();
      final error = await connect(f.host(extra: {'password': 'not-the-password'}))
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<RouteHopException>());
      expect((error! as RouteHopException).cause, isA<SSHAuthFailError>());
      final d = await delta(before, await f.counts());
      expect(d['moshServerStarts'], 0);
      expect(d['loginsMosh'], 0);
      await expectNothingReachedPlugin();
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

    test('服务器上没装 mosh：如实报出来；没有安装、没有 sudo、没碰插件', () async {
      final f = fixture!;
      final before = await f.counts();
      final error = await connect(f.host(port: f.nomoshPort))
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<MoshBootstrapException>());
      expect((error! as MoshBootstrapException).failure,
          MoshBootstrapFailure.serverMissing);
      expect('$error', MoshBootstrapFailure.serverMissing.message);
      final d = await delta(before, await f.counts());
      expect(d['loginsNomosh'], 1, reason: 'SSH 这一段是通的');
      expect(d['installAttempts'], 0, reason: '记账的 sudo/apk/apt-get 一次都没被调用');
      await expectNothingReachedPlugin();
    }, skip: skip);
  });

  group('MOS04 代理、TailSocks、跳板及组合：bootstrap 之前就拒绝', () {
    final routes = <String, Map<String, Object?>>{
      'SOCKS5 代理': {
        'proxyConfig': {'type': 'socks5', 'host': '127.0.0.1', 'port': 1080},
      },
      // TailSocks 在手机上就是一个本机 SOCKS5 端口（这里随便填一个）。App 眼里它和上一条一样。
      'TailSocks（本机 SOCKS5）': {
        'proxyConfig': {'type': 'socks5', 'host': '127.0.0.1', 'port': 1055},
      },
      'HTTP 代理': {
        'proxyConfig': {'type': 'http', 'host': '127.0.0.1', 'port': 3128},
      },
      '跳板机': {
        'hostChain': {
          'hostIds': ['jump'],
        },
      },
      'SOCKS5 + 跳板机': {
        'proxyConfig': {'type': 'socks5', 'host': '127.0.0.1', 'port': 1080},
        'hostChain': {
          'hostIds': ['jump'],
        },
      },
    };
    for (final MapEntry(key: name, value: extra) in routes.entries) {
      test('$name：一个连接都不拨，远端不启动，插件不碰', () async {
        final f = fixture!;
        final before = await f.counts();
        final jump = HostProfile({
          'id': 'jump',
          'label': 'jump',
          'hostname': '127.0.0.1',
          'port': f.nomoshPort,
          'username': f.user,
          'password': f.password,
          'protocol': 'ssh',
        });
        final error = await connect(f.host(extra: extra), hosts: [jump])
            .then<Object?>((_) => null, onError: (Object e) => e);
        expect(error, isA<MoshRouteUnsupported>());
        expect('$error', contains('没有连接服务器、没有启动 mosh-server'));
        expect(dialer.dials, isEmpty, reason: '拨号次数（含绕路直连）必须为 0');
        expect(plugin.prepareCount, 0, reason: '连本机插件都没去碰');
        expect(plugin.calls, isEmpty);
        final d = await delta(before, await f.counts());
        expect(d, {
          'moshServerStarts': 0,
          'installAttempts': 0,
          'loginsMosh': 0,
          'loginsNomosh': 0,
        });
      }, skip: skip);
    }
  });

  group('PLG14 交给插件的只有这次会话的临时材料', () {
    test('登录密码、私钥、代理口令、Tailscale token 都不在任何平台通道参数、阶段说明里', () async {
      final f = fixture!;
      final privateKey = File(f.json['privateKeyPath'] as String).readAsStringSync();
      const proxyPassword = 'X09-PROXY-SECRET-5c1e';
      const tailscaleToken = 'tskey-api-X09SECRET-77aa';
      final host = f.host(extra: {
        // 密码和私钥都配上：哪个被用来登录都一样，两样都不该出现在交给插件的东西里。
        'authMethod': 'auto',
        'identityFileId': 'k1',
        'note': 'tailscale token $tailscaleToken',
      });
      final stages = <ConnectionStage>[];
      final attempt = ConnectionAttempt(onStage: stages.add);
      final session = await MoshBootstrapCoordinator(ssh, plugin).connect(
        sessionId: 'x09-plg14',
        host: host,
        plan: resolveRoutePlan(
          host,
          hosts: [host],
          proxyProfiles: [
            ProxyProfile({
              'id': 'p1',
              'label': 'unused proxy',
              'config': {
                'type': 'socks5',
                'host': '127.0.0.1',
                'port': 1080,
                'username': 'u',
                'password': proxyPassword,
              },
            }),
          ],
          keys: [
            SshKeyProfile({'id': 'k1', 'label': 'k', 'privateKey': privateKey}),
          ],
        ),
        verifyHostKey: f.verify,
        terminal: GhosttyTerminalAdapter(),
        attempt: attempt,
      );
      final secrets = {
        'SSH 密码': f.password,
        '私钥': privateKey.split('\n')[1],
        '代理口令': proxyPassword,
        'Tailscale token': tailscaleToken,
      };
      final everything = [
        for (final call in plugin.calls) ...[
          call.method,
          for (final value in (call.arguments as Map).values)
            value is Uint8List ? latin1.decode(value) : '$value',
        ],
        for (final stage in stages) stage.describe(),
      ].join('\n');
      for (final MapEntry(key: what, value: secret) in secrets.entries) {
        expect(everything.contains(secret), isFalse, reason: '$what 出现在交给插件的参数或阶段说明里');
      }
      await session.close();
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('经会话控制器：Mosh 标签的输入、尺寸、结束（真实引导 + 假插件通道）', () {
    late ProviderContainer container;
    late SessionController controller;

    setUp(() async {
      if (fixture == null) return;
      SharedPreferences.setMockInitialValues({});
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
      if (fixture == null) return;
      container.dispose();
    });

    test('输入只经终端绑定写一次；尺寸等运行起来再发；运行时异常退出后不自动重连、不重发输入', () async {
      final f = fixture!;
      expect(await controller.connect(f.host(), f.verify), isTrue);
      final tab = controller.state.sessions.single;
      final link = tab.plugin! as MoshTerminalProvider;
      final terminal = tab.terminal;

      // 还在 opening：尺寸先记着，不发（插件只在运行时接受改尺寸）。
      resizeTestTerminal(terminal, 100, 30);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(plugin.calls.where((c) => c.method == 'resizeSession'), isEmpty);
      await plugin.state(link.session, 1, 'active');
      final resize = plugin.calls.singleWhere((c) => c.method == 'resizeSession');
      expect((resize.arguments as Map)['cols'], 100);
      expect((resize.arguments as Map)['rows'], 30);

      controller.typeInto(tab.id, 'echo 你好');
      controller.typeInto(tab.id, '\r');
      expect(plugin.writes, hasLength(2), reason: '每次输入只写一次');
      expect(link.inputEvents, link.session.writeCount);
      expect(
        utf8.decode((plugin.writes.first.arguments as Map)['bytes'] as List<int>),
        'echo 你好',
        reason: '原样转交，没有再编码一遍',
      );

      // 插件报运行时退出码 1（UDP 不通时 mosh-client 就这样退出）。
      await plugin.state(link.session, 2, 'failed:exit-1');
      await Future<void>.delayed(Duration.zero);
      expect(tab.connected, isFalse);
      expect(tab.autoRestoreBlocked, isTrue);
      // 提示可能折行，去掉换行再找。
      final shown = terminal.allText().replaceAll('\n', '');
      expect(shown, contains('UDP 到不了服务器'));
      expect(shown, contains('不会重发断开前的输入'));

      // 结束之后的按键直接丢掉，不排队。
      final writesBefore = plugin.writes.length;
      controller.typeInto(tab.id, 'ls\r');
      expect(plugin.writes, hasLength(writesBefore));

      final starts = (await f.counts())['moshServerStarts'];
      await controller.reconnectDisconnected();
      controller.setBackgrounded(true);
      controller.setBackgrounded(false);
      await Future<void>.delayed(const Duration(seconds: 1));
      expect((await f.counts())['moshServerStarts'], starts,
          reason: '不能自动再起一个 mosh-server 冒充原来的会话');
      expect(plugin.opens, hasLength(1));
      expect(controller.state.sessions.single, same(tab));
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));
  });
}
