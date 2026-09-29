import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/session_controller.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/infrastructure/transport/proxy_transport.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm2/xterm.dart';

import 'fixtures/docker_fixture.dart';
import 'fixtures/net/socks5_fixture.dart';
import 'fixtures/net/trap_server.dart';

// 依赖 tool/fixture-environment 的真实 OpenSSH / dante。没起 fixture 时整组 skip，
// 证据里记 NOT_RUN，不算通过。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = DockerFixture.load();
  final skip = fixture == null ? DockerFixture.skipReason : false;

  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async => null);
  });

  final seenFingerprints = <String, String>{};
  Future<bool> verifyByLogicalName(
      HostProfile host, String algorithm, String fingerprint) async {
    seenFingerprints[host.hostname] = fingerprint;
    final f = fixture!;
    final expected = {
      '127.0.0.1': f.edgeFingerprint,
      f.hop2Name: f.hop2Fingerprint,
      f.hop3Name: f.hop3Fingerprint,
      f.targetName: f.targetFingerprint,
    }[host.hostname];
    return fingerprint == expected;
  }

  HostProfile edgeHost(Map<String, Object?> extra) => HostProfile({
        'id': 'edge-${extra.hashCode}',
        'label': 'edge',
        'hostname': fixture!.edgeHost,
        'port': fixture.edgePort,
        'username': fixture.user,
        'password': fixture.password,
        'authMethod': 'password',
        'protocol': 'ssh',
        ...extra,
      });

  HostProfile targetViaProxy(Map<String, Object?> proxyConfig) => HostProfile({
        'id': 'target',
        'label': 'target',
        'hostname': fixture!.targetName,
        'port': fixture.targetPort,
        'username': fixture.user,
        'password': fixture.password,
        'authMethod': 'password',
        'protocol': 'ssh',
        'proxyConfig': proxyConfig,
      });

  /// 独立于被测代码的检查通道：直接用 dartssh2 登录 ssh-edge 执行命令。
  Future<String> remote(String command) async {
    final f = fixture!;
    final client = SSHClient(
      await SSHSocket.connect(f.edgeHost, f.edgePort),
      username: f.user,
      onPasswordRequest: () => f.password,
      onVerifyHostKey: (_, fp) => utf8.decode(fp) == f.edgeFingerprint,
    );
    try {
      return utf8.decode(await client.run(command)).trim();
    } finally {
      client.close();
    }
  }

  Future<void> killEdgeSessions() async {
    final result = await Process.run('docker', [
      'compose',
      '-f',
      'tool/fixture-environment/compose.yaml',
      'exec',
      '-T',
      'ssh-edge',
      'pkill',
      '-KILL',
      '-f',
      'sshd-session',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  }

  Future<void> waitUntil(bool Function() condition,
      {Duration timeout = const Duration(seconds: 10)}) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('等待条件超时');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<String> runInSession(ActiveTerminalSession session, String command) =>
      session.sshClient!.run(command).then((out) => utf8.decode(out).trim());

  Future<ActiveTerminalSession> connect(
    HostProfile host, {
    TcpDialer? dialer,
    Terminal? terminal,
  }) =>
      SshService(dialer: dialer).connect(
        sessionId: 'it',
        host: host,
        hosts: [host],
        keys: const [],
        proxyProfiles: const [],
        verifyHostKey: verifyByLogicalName,
        terminal: terminal,
      );

  group('NET01 经 SOCKS5 建立真实 SSH', () {
    test('dante 无认证 → 仅代理可解析的目标', () async {
      final session = await connect(targetViaProxy({
        'type': 'socks5',
        'host': fixture!.socksAuthHost,
        'port': fixture.socksNoAuthPort,
      }));
      addTearDown(session.close);
      expect(await runInSession(session, 'hostname'), 'target');
    }, skip: skip);

    test('dante 用户名密码 → 仅代理可解析的目标', () async {
      final session = await connect(targetViaProxy({
        'type': 'socks5',
        'host': fixture!.socksAuthHost,
        'port': fixture.socksAuthPort,
        'username': fixture.socksUser,
        'password': fixture.socksPassword,
      }));
      addTearDown(session.close);
      expect(await runInSession(session, 'hostname'), 'target');
    }, skip: skip);

    for (final auth in [false, true]) {
      test('握手逐字节分片（${auth ? '用户名密码' : '无认证'}）', () async {
        final proxy = await Socks5Fixture.start(
          username: auth ? 'u' : null,
          password: auth ? 'p' : null,
          fragmentDelay: const Duration(milliseconds: 5),
          names: {
            'edge.fixture.invalid': (
              host: fixture!.edgeHost,
              port: fixture.edgePort
            ),
          },
        );
        addTearDown(proxy.close);
        final host = edgeHost({
          'hostname': 'edge.fixture.invalid',
          'proxyConfig': {
            'type': 'socks5',
            'host': proxy.host,
            'port': proxy.port,
            if (auth) 'username': 'u',
            if (auth) 'password': 'p',
          },
        });
        final session = await SshService().connect(
          sessionId: 'it',
          host: host,
          hosts: [host],
          keys: const [],
          proxyProfiles: const [],
          verifyHostKey: (_, __, fp) async => fp == fixture.edgeFingerprint,
        );
        addTearDown(session.close);
        expect(await runInSession(session, 'hostname'), 'ssh-edge');
        final attempt = proxy.attempts.single;
        expect(attempt.selectedMethod, auth ? 2 : 0);
        expect((attempt.username, attempt.password),
            auth ? ('u', 'p') : (null, null));
        expect(attempt.addressType, 3, reason: '目标名以域名形式交给代理');
      }, skip: skip);
    }

    test('配置了代理密码时，代理选"无认证"必须拒绝（A02）', () async {
      final proxy = await Socks5Fixture.start(
        username: 'u',
        password: 'p',
        fault: Socks5Fault.forceNoAuth,
        names: {
          'edge.fixture.invalid': (
            host: fixture!.edgeHost,
            port: fixture.edgePort
          ),
        },
      );
      addTearDown(proxy.close);
      final host = edgeHost({
        'hostname': 'edge.fixture.invalid',
        'proxyConfig': {
          'type': 'socks5',
          'host': proxy.host,
          'port': proxy.port,
          'username': 'u',
          'password': 'p',
        },
      });
      await expectLater(
        SshService().connect(
          sessionId: 'it',
          host: host,
          hosts: [host],
          keys: const [],
          proxyProfiles: const [],
          verifyHostKey: (_, __, fp) async => fp == fixture.edgeFingerprint,
        ),
        throwsA(isA<RouteHopException>()
            .having((e) => e.cause, 'cause', isA<ProxyHandshakeException>())
            .having((e) => e.message, 'message', contains('防止降级'))),
      );
      expect(proxy.attempts.single.offeredMethods, [2],
          reason: '有凭据时只应提供用户名密码方法');
    }, skip: skip);

    test('配置了代理密码，却连到只允许无认证的 dante：拒绝，不降级', () async {
      final f = fixture!;
      final host = targetViaProxy({
        'type': 'socks5',
        'host': f.socksAuthHost,
        'port': f.socksNoAuthPort,
        'username': f.socksUser,
        'password': f.socksPassword,
      });
      await expectLater(
        connect(host),
        throwsA(isA<RouteHopException>()
            .having((e) => e.cause, 'cause', isA<ProxyHandshakeException>())),
      );
    }, skip: skip);
  });

  test('NET02 目标名只交给代理：本机只拨代理端点，指纹按逻辑名校验', () async {
    final dialer = RecordingDialer();
    seenFingerprints.clear();
    final session = await connect(
      targetViaProxy({
        'type': 'socks5',
        'host': fixture!.socksAuthHost,
        'port': fixture.socksAuthPort,
        'username': fixture.socksUser,
        'password': fixture.socksPassword,
      }),
      dialer: dialer.call,
    );
    addTearDown(session.close);
    expect(await runInSession(session, 'hostname'), 'target');
    expect(dialer.dials, ['${fixture.socksAuthHost}:${fixture.socksAuthPort}']);
    expect(seenFingerprints, {fixture.targetName: fixture.targetFingerprint},
        reason: '主机信任的键是目标逻辑名，不是 127.0.0.1 代理地址');
  }, skip: skip);

  group('JMP 真实 ProxyJump：按 RoutePlan 逐跳建立（R05）', () {
    HostProfile node(String id, String hostname, int port,
            [Map<String, Object?> extra = const {}]) =>
        HostProfile({
          'id': id,
          'label': id,
          'hostname': hostname,
          'port': port,
          'username': fixture!.user,
          'password': fixture.password,
          'authMethod': 'password',
          'protocol': 'ssh',
          ...extra,
        });

    Future<void> expectReachesTarget(
      List<HostProfile> jumps,
      List<String> expectedVerifyOrder,
    ) async {
      final f = fixture!;
      final dialer = RecordingDialer();
      final verified = <String>[];
      final target = node('target', f.targetName, f.targetPort, {
        'hostChain': {
          'hostIds': [for (final jump in jumps) jump.id],
        },
      });
      final session = await SshService(dialer: dialer.call).connect(
        sessionId: 'jmp',
        host: target,
        hosts: [...jumps, target],
        keys: const [],
        proxyProfiles: const [],
        verifyHostKey: (host, algorithm, fingerprint) {
          verified.add(host.hostname);
          return verifyByLogicalName(host, algorithm, fingerprint);
        },
      );
      addTearDown(session.close);
      expect(await runInSession(session, 'hostname'), 'target');
      expect(dialer.dials, ['${f.edgeHost}:${f.edgePort}'],
          reason: '手机只拨第一跳，后面每一跳都经上一跳转发');
      expect(verified, expectedVerifyOrder, reason: '每一跳都先验主机指纹，再往下一跳走');
      expect(session.sshClients, hasLength(jumps.length + 1));
    }

    test('一跳：边缘 → 目标', () {
      final f = fixture!;
      return expectReachesTarget(
        [node('edge', f.edgeHost, f.edgePort)],
        [f.edgeHost, f.targetName],
      );
    });

    test('两跳：边缘 → hop2 → 目标', () {
      final f = fixture!;
      return expectReachesTarget(
        [
          node('edge', f.edgeHost, f.edgePort),
          node('hop2', f.hop2Name, f.hop2Port)
        ],
        [f.edgeHost, f.hop2Name, f.targetName],
      );
    });

    // ---- R07 ----

    List<HostProfile> threeJumps() {
      final f = fixture!;
      return [
        node('edge', f.edgeHost, f.edgePort),
        node('hop2', f.hop2Name, f.hop2Port),
        node('hop3', f.hop3Name, f.hop3Port),
      ];
    }

    HostProfile targetVia(List<HostProfile> jumps,
            [Map<String, Object?> extra = const {}]) =>
        node('target', fixture!.targetName, fixture.targetPort, {
          'hostChain': {
            'hostIds': [for (final jump in jumps) jump.id],
          },
          ...extra,
        });

    /// 某台 sshd 容器到目前为止的日志行。按"前后新增的行"看，不依赖宿主机和容器的时钟对齐。
    Future<List<String>> sshdLog(String service) async {
      final result = await Process.run('docker', [
        'compose',
        '-f',
        'tool/fixture-environment/compose.yaml',
        'logs',
        '--no-color',
        service,
      ]);
      return '${result.stdout}'.split('\n');
    }

    Future<List<String>> newLines(String service, List<String> before) async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final after = await sshdLog(service);
      return after.sublist(before.length - 1);
    }

    Future<RouteHopException> hopFailure(
      HostProfile target,
      List<HostProfile> jumps, {
      HostKeyVerifier? verify,
      TcpDialer? dialer,
    }) async {
      try {
        final session = await SshService(dialer: dialer).connect(
          sessionId: 'jmp',
          host: target,
          hosts: [...jumps, target],
          keys: const [],
          proxyProfiles: const [],
          verifyHostKey: verify ?? verifyByLogicalName,
        );
        await session.close();
      } on RouteHopException catch (error) {
        return error;
      }
      fail('应当在某一跳失败');
    }

    test('JMP01 三跳：边缘 → hop2 → hop3 → 目标', () {
      final f = fixture!;
      return expectReachesTarget(
        threeJumps(),
        [f.edgeHost, f.hop2Name, f.hop3Name, f.targetName],
      );
    });

    test('JMP01 跳板只转发：日志里跳板只有登录、没开 shell 或执行命令，目标才开 shell', () async {
      final f = fixture!;
      const jumpServices = ['ssh-edge', 'ssh-hop2', 'ssh-hop3'];
      final before = {
        for (final s in [...jumpServices, 'target']) s: await sshdLog(s),
      };
      await expectReachesTarget(
        threeJumps(),
        [f.edgeHost, f.hop2Name, f.hop3Name, f.targetName],
      );
      for (final service in jumpServices) {
        final lines = await newLines(service, before[service]!);
        expect(lines.join('\n'), contains('Accepted password for fixture'),
            reason: '$service 应当被登录过（每跳独立认证）');
        expect(lines.join('\n'), isNot(contains('Starting session')),
            reason: '$service 上不该开 shell 或执行任何命令（不靠远端 ssh 命令转发）');
      }
      expect((await newLines('target', before['target']!)).join('\n'),
          contains('Starting session: shell'));
    });

    test('JMP01 关掉后按同一条路线重连（恢复）', () async {
      final f = fixture!;
      final jumps = threeJumps().take(2).toList();
      final target = targetVia(jumps);
      for (final purpose in ConnectionPurpose.values) {
        final dialer = RecordingDialer();
        final session = await SshService(dialer: dialer.call).connect(
          sessionId: 'jmp-$purpose',
          host: target,
          hosts: [...jumps, target],
          keys: const [],
          proxyProfiles: const [],
          verifyHostKey: verifyByLogicalName,
          purpose: purpose,
        );
        expect(await runInSession(session, 'hostname'), 'target');
        expect(dialer.dials, ['${f.edgeHost}:${f.edgePort}']);
        await session.close();
      }
    });

    const hopNames = ['edge', 'hop2', 'hop3', 'target'];
    const hopServices = ['ssh-edge', 'ssh-hop2', 'ssh-hop3', 'target'];
    for (var bad = 0; bad < hopNames.length; bad++) {
      test('JMP02 / SEC02 ${hopNames[bad]} 的指纹对不上：在这一跳阻断，这台一次登录都没收到', () async {
        final f = fixture!;
        final logical = [f.edgeHost, f.hop2Name, f.hop3Name, f.targetName];
        final before = await sshdLog(hopServices[bad]);
        final error = await hopFailure(
          targetVia(threeJumps()),
          threeJumps(),
          verify: (host, algorithm, fingerprint) async =>
              host.hostname != logical[bad] &&
              await verifyByLogicalName(host, algorithm, fingerprint),
        );
        expect(error.hop, bad);
        expect(error.message, contains('“${hopNames[bad]}”'));
        expect(error.message, contains('主机指纹没有通过校验'));
        final lines = (await newLines(hopServices[bad], before)).join('\n');
        expect(lines, contains('[preauth]'), reason: '连接在认证前就断了');
        for (final authEvent in ['Accepted', 'Failed', 'Postponed']) {
          expect(lines, isNot(contains(authEvent)),
              reason: '指纹没通过时不能发出任何登录数据（$authEvent）');
        }
      });
    }

    group('JMP04 代理入口 + 跳板', () {
      late Socks5Fixture proxy;
      late RecordingDialer dialer;
      setUp(() async {
        final f = fixture!;
        proxy = await Socks5Fixture.start(names: {
          'edge.fixture.invalid': (host: f.edgeHost, port: f.edgePort),
        });
        dialer = RecordingDialer();
      });
      tearDown(() => proxy.close());

      Map<String, Object?> viaProxy() => {
            'proxyConfig': {
              'type': 'socks5',
              'host': proxy.host,
              'port': proxy.port,
            },
          };
      Future<bool> verify(HostProfile host, String algorithm, String fp) =>
          host.hostname == 'edge.fixture.invalid'
              ? Future.value(fp == fixture!.edgeFingerprint)
              : verifyByLogicalName(host, algorithm, fp);
      List<HostProfile> jumps({String edge = 'edge.fixture.invalid'}) => [
            node('edge', edge, 22),
            node('hop2', fixture!.hop2Name, fixture.hop2Port),
          ];

      test('走通：手机只拨代理一次，代理只 CONNECT 第一跳，后面经跳板转发', () async {
        final path = jumps();
        final target = targetVia(path, viaProxy());
        final session = await SshService(dialer: dialer.call).connect(
          sessionId: 'jmp4',
          host: target,
          hosts: [...path, target],
          keys: const [],
          proxyProfiles: const [],
          verifyHostKey: verify,
        );
        addTearDown(session.close);
        expect(await runInSession(session, 'hostname'), 'target');
        expect(dialer.dials, ['${proxy.host}:${proxy.port}']);
        expect(proxy.attempts.map((a) => a.requestedHost),
            ['edge.fixture.invalid']);
      });

      test('代理连不到第一跳：报第一跳、经代理阶段，不绕过代理', () async {
        final path = jumps(edge: 'nosuch.fixture.invalid');
        final error = await hopFailure(targetVia(path, viaProxy()), path,
            verify: verify, dialer: dialer.call);
        expect(error.hop, 0);
        expect(error.message, contains('经代理连接失败'));
        expect(error.message, contains('主机不可达'));
        expect(dialer.dials, ['${proxy.host}:${proxy.port}']);
      });

      // 用"存在的主机 + 关着的端口"而不是不存在的域名：本机 DNS 是 fake-ip，
      // 跳板机在容器里查任何名字都会拿到 198.18.x.x，转发通道会先被确认、再断开，
      // 失败就落到了下一跳的握手阶段，测不到"转发被拒"。
      test('第一跳转发不到第二跳：报第一跳的转发阶段和去向', () async {
        final path = [
          node('edge', 'edge.fixture.invalid', 22),
          node('hop2', fixture!.hop2Name, 2222),
        ];
        final error = await hopFailure(targetVia(path, viaProxy()), path,
            verify: verify, dialer: dialer.call);
        expect(error.hop, 0);
        expect(error.message, contains('“edge”'));
        expect(error.message, contains('转发失败（到 ${fixture.hop2Name}:2222）'));
        expect(dialer.dials, ['${proxy.host}:${proxy.port}']);
      });

      test('最后一跳转发不到目标端口：报第二跳的转发阶段', () async {
        final path = jumps();
        final target = HostProfile({
          ...targetVia(path, viaProxy()).data,
          'port': 2222,
        });
        final error =
            await hopFailure(target, path, verify: verify, dialer: dialer.call);
        expect(error.hop, 1);
        expect(error.message, contains('“hop2”'));
        expect(error.message, contains('转发失败（到 ${fixture!.targetName}:2222）'));
        expect(dialer.dials, ['${proxy.host}:${proxy.port}']);
      });
    });

    test('SEC01 信任记录按逻辑目标：换一个本地 SOCKS 端口连同一目标，记录的仍是 target:22', () async {
      final f = fixture!;
      final trusted = <String, String>{};
      Future<bool> knownHosts(
          HostProfile host, String algorithm, String fp) async {
        final key = '${host.hostname}:${host.port}';
        final known = trusted[key];
        if (known == null) {
          // 模拟"用户核对后接受"。首次必须经过这一步，不自动信任。
          if (fp != f.targetFingerprint) return false;
          trusted[key] = fp;
          return true;
        }
        return known == fp;
      }

      for (final port in [f.socksAuthPort, f.socksNoAuthPort]) {
        final host = targetViaProxy({
          'type': 'socks5',
          'host': f.socksAuthHost,
          'port': port,
          if (port == f.socksAuthPort) 'username': f.socksUser,
          if (port == f.socksAuthPort) 'password': f.socksPassword,
        });
        final session = await SshService().connect(
          sessionId: 'sec1',
          host: host,
          hosts: [host],
          keys: const [],
          proxyProfiles: const [],
          verifyHostKey: knownHosts,
        );
        expect(await runInSession(session, 'hostname'), 'target');
        await session.close();
      }
      expect(trusted.keys, ['${f.targetName}:${f.targetPort}'],
          reason: '不能按 127.0.0.1 或代理端口记信任');
    });

    test('SEC03 代理把连接偷偷转到另一台 SSH：已信任的目标指纹对不上，认证前阻断', () async {
      final f = fixture!;
      final evil = await Socks5Fixture.start(names: {
        f.targetName: (host: f.edgeHost, port: f.edgePort),
      });
      addTearDown(evil.close);
      final before = await sshdLog('ssh-edge');
      final host = targetViaProxy({
        'type': 'socks5',
        'host': evil.host,
        'port': evil.port,
      });
      final error = await hopFailure(host, const []);
      expect(error.hop, 0);
      expect(error.message, contains('主机指纹没有通过校验'));
      final lines = (await newLines('ssh-edge', before)).join('\n');
      expect(lines, isNot(contains('Accepted')));
      expect(lines, isNot(contains('Failed')));
    });
  }, skip: skip);

  group('R06 经外部 SOCKS 与拆包的真实行为', () {
    test('SOX01 同一个外部 SOCKS 连两个不同目标：两条独立 CONNECT；会话关了代理照常可用', () async {
      final f = fixture!;
      final dialer = RecordingDialer();
      final proxy = {
        'type': 'socks5',
        'host': f.socksAuthHost,
        'port': f.socksAuthPort,
        'username': f.socksUser,
        'password': f.socksPassword,
      };
      HostProfile via(String id, String name, int port) => HostProfile({
            'id': id,
            'label': id,
            'hostname': name,
            'port': port,
            'username': f.user,
            'password': f.password,
            'authMethod': 'password',
            'protocol': 'ssh',
            'proxyConfig': proxy,
          });
      final a = await connect(via('a', f.targetName, f.targetPort),
          dialer: dialer.call);
      final b =
          await connect(via('b', f.hop2Name, f.hop2Port), dialer: dialer.call);
      expect(await runInSession(a, 'hostname'), 'target');
      expect(await runInSession(b, 'hostname'), 'ssh-hop2',
          reason: '第二个目标走自己的 CONNECT，不复用第一条已连上的流');
      final socks = '${f.socksAuthHost}:${f.socksAuthPort}';
      expect(dialer.dials, [socks, socks]);
      await a.close();
      await b.close();
      // 外部代理不是 App 启动的，App 关会话也不去停它：马上再连一次照常可用。
      final c = await connect(via('c', f.targetName, f.targetPort));
      addTearDown(c.close);
      expect(await runInSession(c, 'hostname'), 'target');
    });

    test('SOX02 真实 sshd 的版本行被逐字节拆开：照样连上', () async {
      final f = fixture!;
      final relay = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(relay.close);
      relay.listen((client) async {
        client.setOption(SocketOption.tcpNoDelay, true);
        final upstream = await Socket.connect(f.edgeHost, f.edgePort);
        client.listen(upstream.add,
            onDone: upstream.destroy, onError: (_) => upstream.destroy());
        // 服务器发来的前 40 个字节（含版本行）一字节一个包、间隔 2 ms 转给客户端，之后原样转发。
        final fromServer = StreamIterator(upstream);
        var split = 0;
        while (await fromServer.moveNext()) {
          final chunk = fromServer.current;
          var offset = 0;
          while (split < 40 && offset < chunk.length) {
            client.add([chunk[offset++]]);
            await client.flush();
            split++;
            await Future<void>.delayed(const Duration(milliseconds: 2));
          }
          if (offset < chunk.length) client.add(chunk.sublist(offset));
        }
        client.destroy();
      });
      final session = await connect(edgeHost({'port': relay.port}));
      addTearDown(session.close);
      expect(await runInSession(session, 'hostname'), 'ssh-edge');
    });
  }, skip: skip);

  test('TER01 真实 SSH 大段中文输出没有替换符', () async {
    final terminal = Terminal(maxLines: 20000);
    final session = await connect(edgeHost({}), terminal: terminal);
    addTearDown(session.close);
    String screen() =>
        terminal.lines.toList().map((line) => line.getText()).join('\n');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    session.sshSession!.write(utf8.encode(
      r"i=0; while [ $i -lt 2000 ]; do printf '中文字符测试🙂'; i=$((i+1)); done; echo; echo __END__"
      '\n',
    ));
    await waitUntil(
        () => RegExp(r'^__END__', multiLine: true).hasMatch(screen()),
        timeout: const Duration(seconds: 20));
    final text = screen();
    expect(text, isNot(contains('�')));
    expect('测'.allMatches(text).length, greaterThanOrEqualTo(2000));
  }, skip: skip);

  group('REG02 / NET11 断线恢复不重跑 startup、不重放输入', () {
    late ProviderContainer container;
    late SessionController controller;

    setUp(() async {
      if (fixture == null) return;
      SharedPreferences.setMockInitialValues({});
      final repository = await VaultRepository.open();
      container = ProviderContainer(overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
      ]);
      controller = container.read(sessionControllerProvider.notifier);
      await remote('rm -f ~/startup.log ~/managed.log ~/net11-marker');
    });

    tearDown(() async {
      if (fixture == null) return;
      for (final session in [...controller.state.sessions]) {
        await session.close();
      }
      container.dispose();
    });

    Future<int> lines(String file) async =>
        int.parse(await remote('cat $file 2>/dev/null | wc -l'));

    Future<void> dropAndRestore(ActiveTerminalSession old) async {
      await killEdgeSessions();
      await waitUntil(() => !old.connected);
      await controller.reconnectDisconnected();
      await waitUntil(() => controller.state.sessions
          .any((s) => s.id == old.id && s.connected && !identical(s, old)));
    }

    test('普通主机：startup 只在新连接执行一次；半行输入不被重放', () async {
      await controller.connect(
        edgeHost({'startupCommand': 'echo fresh >> ~/startup.log'}),
        verifyByLogicalName,
      );
      final old = controller.state.sessions.single;
      await waitUntil(() => true);
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(await lines('~/startup.log'), 1, reason: 'Fresh 应执行一次');

      controller.sendToSession(old.id, 'touch ~/net11-marker');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await dropAndRestore(old);

      // 只按一个回车：如果旧的半行被重放进新 shell，这个回车会把它执行掉。
      controller.sendToSession(old.id, '', enter: true);
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(
          await remote('test -e ~/net11-marker && echo yes || echo no'), 'no',
          reason: '旧输入被重放到了新连接');
      expect(await lines('~/startup.log'), 1, reason: 'Restore 不得重跑 startup');
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

    test('托管终端：管理命令只执行一次，恢复后不重跑', () async {
      await controller.connect(edgeHost({}), verifyByLogicalName);
      final parent = controller.state.sessions.single;
      await controller.openManagedTerminal(
        parent,
        label: 'managed',
        command: 'echo managed >> ~/managed.log',
      );
      final managed = controller.state.sessions.last;
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(await lines('~/managed.log'), 1);

      await dropAndRestore(managed);
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(await lines('~/managed.log'), 1, reason: '恢复重跑了托管命令');
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));
  });
}
