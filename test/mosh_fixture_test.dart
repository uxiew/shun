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
import 'package:shun/domain/tmux/tmux_target.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/tmux/tmux_protocol.dart';
import 'package:shun/infrastructure/tmux/tmux_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:shun/presentation/widgets/connection_probe_sheet.dart';
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

  // R41：moshalt 是 Debian，mosh-server 只在 /opt/mosh-alt/bin（不在 PATH、不在自动探测的位置），
  // 只有 glibc 自带的 C.UTF-8。主机上的覆盖项要经协调器、真 SSH、真 mosh-server 生效。
  group('R41 mosh-server 路径与 locale 覆盖（moshalt）', () {
    final altSkip = skip != false
        ? skip
        : fixture!.moshaltPort == null
            ? '这份 fixture 没有 moshalt：重跑 tool/mosh-fixture/up.sh（结果按 NOT_RUN 记录）'
            : false;

    HostProfile alt([Map<String, Object?> extra = const {}]) =>
        fixture!.host(port: fixture.moshaltPort, extra: extra);

    Future<String> onAlt(String command) =>
        fixture!.exec(command, service: 'moshalt');

    /// 此刻 moshalt 上在跑的 mosh-server 的完整命令行（去重：没被客户端连过的 mosh-server
    /// 会先 fork 一个等着起 shell 的子进程，参数一样）。
    Future<List<String>> running() async =>
        (await onAlt('ps -eo args= | grep -E "^[^ ]*mosh-server new" || true'))
            .split('\n')
            .where((line) => line.isNotEmpty)
            .toSet()
            .toList();

    tearDown(() async {
      if (fixture?.moshaltPort == null) return;
      await onAlt(
          'pkill -x mosh-server; rm -rf /home/mosh/bin /home/mosh/.local; true');
    });

    Future<Object?> failure(HostProfile host) =>
        connect(host).then<Object?>((_) => null, onError: (Object e) => e);

    Matcher failsWith(MoshBootstrapFailure f) =>
        isA<MoshBootstrapException>().having((e) => e.failure, 'failure', f);

    test('自动：PATH 和常见位置都没有，如实报「没找到」；没碰插件', () async {
      expect(
          await failure(alt()), failsWith(MoshBootstrapFailure.serverMissing));
      expect(plugin.opens, isEmpty);
      expect(await running(), isEmpty);
    }, skip: altSkip);

    test('只填路径：mosh-server 真的被起了，但没有 en_US.UTF-8 拒绝启动', () async {
      final error =
          await failure(alt({moshServerPathKey: fixture!.moshaltServerPath}));
      // 走到了 mosh-server 自己的报错，说明路径生效了；是 locale 问题，不是「没找到」。
      expect(error, failsWith(MoshBootstrapFailure.localeUnsupported));
      expect(plugin.opens, isEmpty);
    }, skip: altSkip);

    test('路径 + C.UTF-8：起来了，远端参数就是主机上填的值，插件拿到范围内端口', () async {
      final f = fixture!;
      await connect(alt({
        moshServerPathKey: f.moshaltServerPath,
        moshLocaleKey: f.moshaltLocale,
        moshPortsKey: '60111:60118',
      }));
      expect(plugin.opens, hasLength(1));
      final args =
          (plugin.opens.single.arguments as Map).cast<String, Object?>();
      expect(args['udpPort'] as int, inInclusiveRange(60111, 60118));
      final lines = await running();
      expect(lines, hasLength(1));
      expect(lines.single,
          '/opt/mosh-alt/bin/mosh-server new -s -c 256 -l LANG=C.UTF-8 -p 60111:60118');
    }, skip: altSkip);

    test('路径写错：报「指定的路径不对」，不回退到自动探测', () async {
      expect(
        await failure(alt({
          moshServerPathKey: '/opt/nope/mosh-server',
          moshLocaleKey: 'C.UTF-8',
        })),
        failsWith(MoshBootstrapFailure.serverPathMissing),
      );
      expect(plugin.opens, isEmpty);
      expect(await running(), isEmpty);
    }, skip: altSkip);

    test('~/ 路径按服务器上这个用户的 HOME 展开', () async {
      await onAlt('install -d -o mosh -g mosh /home/mosh/bin && '
          'ln -s /opt/mosh-alt/bin/mosh-server /home/mosh/bin/mosh-server');
      await connect(alt({
        moshServerPathKey: '~/bin/mosh-server',
        moshLocaleKey: 'C.UTF-8',
      }));
      expect(plugin.opens, hasLength(1));
      expect(
          (await running()).single,
          startsWith(
              '/home/mosh/bin/mosh-server new -s -c 256 -l LANG=C.UTF-8'));
    }, skip: altSkip);

    test('自动探测在真实服务器上找到 ~/.local/bin', () async {
      await onAlt(
          'install -d -o mosh -g mosh /home/mosh/.local /home/mosh/.local/bin && '
          'ln -s /opt/mosh-alt/bin/mosh-server /home/mosh/.local/bin/mosh-server');
      await connect(alt({moshLocaleKey: 'C.UTF-8'}));
      expect(plugin.opens, hasLength(1));
      expect(
          (await running()).single,
          startsWith(
              '/home/mosh/.local/bin/mosh-server new -s -c 256 -l LANG=C.UTF-8'));
    }, skip: altSkip);
  });

  // R41 / UX07：测试连接顺带只读查 tmux。只看 mosh 用户默认 socket 上的 tmux：
  // 查询前后会话一样多、没起 server、没执行启动命令；没有 tmux 的机器（moshalt）如实说没有。
  group('R41 测试连接只读查 tmux，不建会话', () {
    Future<ProbeOutcome> probe(HostProfile host) => ssh.probe(
          host: host,
          routePlan:
              resolveRoutePlan(host, hosts: [host], proxyProfiles: const []),
          verifyHostKey: fixture!.verify,
          attempt: ConnectionAttempt(),
        );

    HostProfile sshHost({int? port}) => fixture!.host(port: port, extra: {
          'protocol': 'ssh',
          // 测试连接不该执行它：执行了就会留下这个文件。
          'startupCommand': 'touch /tmp/r41-probe-startup-ran',
        });

    // 以登录用户身份执行：测试连接查的是这个用户默认 socket 上的 tmux。
    Future<String> asUser(String command) =>
        fixture!.exec(command, user: fixture.user);

    Future<String> sessions() =>
        asUser('tmux list-sessions -F "#{session_id}" 2>/dev/null || true');
    Future<String> servers() =>
        fixture!.exec('pgrep -u ${fixture.user} -x tmux | wc -l');

    tearDown(() async {
      if (fixture == null) return;
      await asUser('tmux kill-server 2>/dev/null; true');
      await fixture.exec('rm -f /tmp/r41-probe-startup-ran');
    });

    test('有 tmux、没有 server：说还没有会话；查完仍没有 server、socket 目录也没被建出来', () async {
      final f = fixture!;
      await asUser(
          'tmux kill-server 2>/dev/null; rm -rf /tmp/tmux-\$(id -u); true');
      final outcome = await probe(sshHost());
      expect(outcome.tty, startsWith('/dev/pts/'));
      expect(outcome.tmux?.availability, TmuxAvailability.noServer,
          reason: '${outcome.tmux?.problem ?? outcome.tmuxProblem}');
      expect(describeProbeTmux(outcome), contains('默认 socket 上还没有会话'));
      expect(await servers(), '0', reason: '查询不该起 tmux server');
      expect(
          await asUser('test -e /tmp/tmux-\$(id -u) && echo made || echo none'),
          'none');
      expect(
          await f.exec(
              'test -e /tmp/r41-probe-startup-ran && echo ran || echo no'),
          'no');
    }, skip: skip);

    test('已有一个会话：报 1 个、去哪里选；查完还是那一个会话，没新建、没附着', () async {
      await asUser('tmux new-session -d -s r41keep');
      final before = await sessions();
      expect(before.split('\n'), hasLength(1));
      final outcome = await probe(sshHost());
      expect(outcome.tmux?.availability, TmuxAvailability.ready);
      expect(outcome.tmux!.sessions, hasLength(1));
      expect(describeProbeTmux(outcome), contains('有 1 个会话'));
      expect(describeProbeTmux(outcome), contains('「系统管理 → tmux」'));
      expect(await sessions(), before);
      expect(await asUser('tmux list-clients 2>/dev/null | wc -l'), '0',
          reason: '测试连接不附着');
    }, skip: skip);

    test('没有 tmux 的机器（moshalt）：如实说没有、不会替你装；测试连接本身仍算成功', () async {
      final f = fixture!;
      if (f.moshaltPort == null) {
        markTestSkipped('这份 fixture 没有 moshalt：重跑 tool/mosh-fixture/up.sh');
        return;
      }
      expect(await f.exec('command -v tmux || echo none', service: 'moshalt'),
          'none');
      final outcome = await probe(sshHost(port: f.moshaltPort));
      expect(outcome.tty, startsWith('/dev/pts/'));
      expect(outcome.tmux?.availability, TmuxAvailability.missing);
      expect(describeProbeTmux(outcome), contains('远端没有 tmux'));
      expect(
          await f.exec(
              'test -e /tmp/r41-probe-startup-ran && echo ran || echo no',
              service: 'moshalt'),
          'no');
    }, skip: skip);
  });

  // R42：tmux 标签在 SSH 和 Mosh 之间原地切换。会话控制器、OpenSSH、mosh-server、tmux 都是真的；
  // 插件通道是假的，UDP 那一头换成容器里一个真的 mosh-client（拿插件收到的端口和 key 去连）。
  // mosh-server 用 -s 绑在容器自己的 IP 上，所以 mosh-client 连的是容器 IP，不是插件拿到的 127.0.0.1。
  // tmux 会话里跑的是一个记账程序：终端开成 raw，收到的每个字节都落进 /tmp/r42-input，
  // 「切换不重发任何输入」就看这个文件是不是一直是 0 字节。
  group('R42 tmux 标签在 SSH / Mosh 之间原地切换（真实引导 + 容器里的真 mosh-client）', () {
    late ProviderContainer container;
    late SessionController controller;

    HostProfile sshHost() => fixture!.host(extra: {'id': 'r42', 'protocol': 'ssh'});
    Future<String> asUser(String command) =>
        fixture!.exec(command, user: fixture.user);

    setUp(() async {
      if (fixture == null) return;
      await asUser('tmux kill-server 2>/dev/null; true');
      await fixture.exec('rm -f /tmp/r42-input');
      await asUser('tmux new-session -d -s r42 -x 80 -y 24 '
          "'stty raw -echo; exec cat > /tmp/r42-input'");
      SharedPreferences.setMockInitialValues({});
      final repository = await VaultRepository.open();
      container = ProviderContainer(overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
        sshServiceProvider.overrideWithValue(ssh),
        moshRuntimeProvider.overrideWithValue(plugin),
      ]);
      controller = container.read(sessionControllerProvider.notifier);
      final vault = container.read(vaultControllerProvider.notifier);
      await vault.ready();
      await vault.upsertHost(sshHost());
    });

    tearDown(() async {
      if (fixture == null) return;
      container.dispose();
      await fixture.exec('tmux -L r42client kill-server 2>/dev/null; '
          'pkill -x mosh-client; pkill -x mosh-server; true');
      await asUser('tmux kill-server 2>/dev/null; true');
    });

    /// 会话 r42 上现在的客户端：「pid 终端 会话 id」一行一个。
    Future<List<String>> clients() async {
      final out = await asUser(
          "tmux list-clients -t r42 -F '#{client_pid} #{client_tty} #{session_id}' 2>/dev/null; true");
      return out.isEmpty ? const [] : out.split('\n');
    }

    Future<String> inputBytes() => fixture!.exec('wc -c < /tmp/r42-input');

    Future<String> sessionIdentity() => asUser(
        "tmux display-message -p -t r42 '#{session_id} #{session_created}'");

    Future<void> eventually(Future<bool> Function() check, String what) async {
      for (var i = 0; i < 100; i++) {
        if (await check()) return;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      fail('10 秒内没等到：$what');
    }

    /// 插件一拿到会话材料，就在容器里用它起一个真 mosh-client（放在另一个 tmux server 里，给它一个终端）。
    Future<void> playMoshClient(int opensBefore) async {
      await eventually(
          () async => plugin.opens.length > opensBefore, '插件收到 openSession');
      final args =
          (plugin.opens.last.arguments as Map).cast<String, Object?>();
      final key = ascii.decode(args['key']! as Uint8List);
      await fixture!.exec('tmux -L r42client kill-server 2>/dev/null; '
          'tmux -L r42client new-session -d -x 80 -y 24 '
          '"env MOSH_KEY=$key LANG=C.UTF-8 mosh-client \$(hostname -i) ${args['udpPort']}"');
    }

    Future<ActiveTerminalSession> sshTmuxTab() async {
      final f = fixture!;
      expect(await controller.connect(sshHost(), f.verify), isTrue);
      final shell = controller.state.sessions.single;
      final probe = await const TmuxService()
          .probe(shell.sshClient!, const TmuxSocketSpec.standard());
      final row = probe.sessions.singleWhere((value) => value.name == 'r42');
      final target = targetOf(row,
          hostKey: tmuxHostKeyOf(shell),
          unixUser: probe.unixUser,
          uid: probe.uid!,
          socket: const TmuxSocketSpec.standard());
      expect(await controller.openTmuxTerminal(shell, target), isTrue);
      final tab = controller.state.sessions[1];
      await eventually(() async => (await clients()).length == 1, 'SSH 的 tmux 客户端附着上');
      return tab;
    }

    test('SSH → Mosh → SSH：同一个标签、同一个 tmux 会话（id 和创建时间不变），每次只留新的客户端；一个字节都没发进会话', () async {
      final f = fixture!;
      final identity = await sessionIdentity();
      final tab = await sshTmuxTab();
      final target = tab.tmux!.target;
      expect(identity, startsWith('${target.sessionId} '));
      final sshClientLine = (await clients()).single;
      expect(sshClientLine, startsWith('${tab.tmux!.clientPid} '));

      // SSH → Mosh：走这个标签自己的 SSH，不再登录。
      final before = await f.counts();
      final switching = controller.switchTransport(tab.id, verifyHostKey: f.verify);
      await playMoshClient(0);
      expect(await switching, isTrue);
      final mosh = controller.state.sessions[1];
      expect(mosh.id, tab.id);
      expect(mosh.plugin, isA<MoshTerminalProvider>());
      expect(mosh.tmux!.target.sameAs(target), isTrue);
      final moved = await delta(before, await f.counts());
      expect(moved['moshServerStarts'], 1);
      expect(moved['loginsMosh'], 0, reason: '在标签已登录的 SSH 上起 mosh-server，没有再登录');
      expect(moved['installAttempts'], 0);
      // 会话上只剩 Mosh 那一侧的客户端，它的父进程就是这次的 mosh-server。
      await eventually(() async => (await clients()).length == 1, '旧的 SSH 客户端被分离');
      final moshClientLine = (await clients()).single;
      expect(moshClientLine, startsWith('${mosh.tmux!.clientPid} ${mosh.tmux!.clientTty} '));
      expect(moshClientLine, endsWith(' ${target.sessionId}'));
      final parent = await f.exec(
          "awk '/^PPid:/ {print \$2}' /proc/${mosh.tmux!.clientPid}/status");
      expect(await f.exec('cat /proc/$parent/comm'), 'mosh-server');
      expect(await sessionIdentity(), identity);
      expect(await inputBytes(), '0');
      expect(tab.connected, isFalse);
      expect(tab.closedByUser, isTrue, reason: '旧的 SSH 关掉了');

      // Mosh → SSH：重新登录一次，按 R21 附着同一个目标，然后分离 Mosh 那一侧。
      final back0 = await f.counts();
      expect(await controller.switchTransport(mosh.id, verifyHostKey: f.verify),
          isTrue);
      final back = controller.state.sessions[1];
      expect(back.id, tab.id);
      expect(back.isSsh, isTrue);
      expect(back.tmux!.target.sameAs(target), isTrue);
      expect((await delta(back0, await f.counts()))['loginsMosh'], 1);
      await eventually(() async => (await clients()).length == 1, 'Mosh 那一侧的客户端被分离');
      expect((await clients()).single, startsWith('${back.tmux!.clientPid} '));
      // 它的 tmux 客户端一退，这次的 mosh-server 也跟着退了，不留在服务器上等 UDP。
      await eventually(
          () async => await f.exec('pgrep -x mosh-server | wc -l') == '0',
          'mosh-server 退出');
      expect(await sessionIdentity(), identity);
      expect(await inputBytes(), '0');
    }, skip: skip, timeout: const Timeout(Duration(seconds: 90)));

    test('Mosh-tmux 标签结束后「重新连接」：新起 mosh-server、核对后附着回同一个会话，顶替原位置；不重发输入', () async {
      final f = fixture!;
      final identity = await sessionIdentity();
      final tab = await sshTmuxTab();
      final target = tab.tmux!.target;
      final switching = controller.switchTransport(tab.id, verifyHostKey: f.verify);
      await playMoshClient(0);
      expect(await switching, isTrue);
      final mosh = controller.state.sessions[1];

      // Mosh 这一头没了：服务器上的 mosh-server 和它里面的 tmux 客户端一起退出，会话还在。
      await f.exec('tmux -L r42client kill-server 2>/dev/null; pkill -x mosh-server; true');
      await plugin.providerDied((mosh.plugin! as MoshTerminalProvider).session);
      await Future<void>.delayed(Duration.zero);
      expect(mosh.connected, isFalse);
      expect(mosh.restoreHold!.message, contains('核对还是不是原来那个'));
      await eventually(() async => (await clients()).isEmpty, 'Mosh 那一侧的 tmux 客户端退出');
      expect(await sessionIdentity(), identity, reason: 'Mosh 结束不带走 tmux 会话');
      mosh.terminal.sendText('typed-after-end\r');

      final opens = plugin.opens.length;
      final reconnecting = controller.reconnect(mosh.id, verifyHostKey: f.verify);
      await playMoshClient(opens);
      await reconnecting;
      final next = controller.state.sessions[1];
      expect(identical(next, mosh), isFalse);
      expect(next.plugin, isA<MoshTerminalProvider>());
      expect(next.tmux!.target.sameAs(target), isTrue);
      expect(controller.state.sessions, hasLength(2), reason: '顶替原来的位置，不多一个标签');
      await eventually(() async => (await clients()).length == 1, 'Mosh 客户端附着上');
      expect((await clients()).single, endsWith(' ${target.sessionId}'));
      expect(await sessionIdentity(), identity);
      expect(await inputBytes(), '0', reason: '断开后打的字没有发进会话');
    }, skip: skip, timeout: const Timeout(Duration(seconds: 90)));

    test('同名重建、tmux server 重启：引导在远端核对不过就停，mosh-server 不起、不新建、不附着', () async {
      final f = fixture!;
      expect(await controller.connect(sshHost(), f.verify), isTrue);
      final shell = controller.state.sessions.single;
      final client = shell.sshClient!;
      Future<TmuxTarget> current() async {
        final probe = await const TmuxService()
            .probe(client, const TmuxSocketSpec.standard());
        final row = probe.sessions.singleWhere((value) => value.name == 'r42');
        return targetOf(row,
            hostKey: tmuxHostKeyOf(shell),
            unixUser: probe.unixUser,
            uid: probe.uid!,
            socket: const TmuxSocketSpec.standard());
      }

      Future<void> refused(TmuxTarget stale, String why) async {
        final before = await f.counts();
        final sessionsBefore = await asUser("tmux list-sessions -F '#{session_id}'");
        await expectLater(
          ssh.startMoshServer(client,
              peer: shell.directPeer!, portRange: (60101, 60108), tmux: stale),
          throwsA(isA<TmuxCommandException>()),
          reason: why,
        );
        expect((await delta(before, await f.counts()))['moshServerStarts'], 0,
            reason: '$why：核对在 mosh-server 之前');
        expect(await asUser("tmux list-sessions -F '#{session_id}'"), sessionsBefore,
            reason: '$why：没有新建会话');
        expect(await clients(), isEmpty, reason: '$why：没有附着');
      }

      final original = await current();
      await asUser('tmux kill-session -t r42; tmux new-session -d -s r42; true');
      final rebuilt = await current();
      expect(rebuilt.displayName, original.displayName);
      expect(rebuilt.sameAs(original), isFalse);
      await refused(original, '同名重建');

      await asUser('tmux kill-server; sleep 0.2; tmux new-session -d -s r42; true');
      await refused(rebuilt, 'tmux server 重启');
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));
  });
}
