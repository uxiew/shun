import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/host_trust.dart';
import 'package:netcatty_mobile/application/port_forward_controller.dart';
import 'package:netcatty_mobile/application/session_controller.dart';
import 'package:netcatty_mobile/application/vault_controller.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/infrastructure/ssh/server_monitor_service.dart';
import 'package:netcatty_mobile/infrastructure/ssh/sftp_service.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:netcatty_mobile/infrastructure/ssh/system_management_service.dart';
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

  /// 主机密码存在系统安全存储里。测试里换成内存表，controller 销毁重建后还能读回来。
  void useMemorySecureStorage() {
    final secrets = <String, String>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async {
      final args = (call.arguments as Map?) ?? const {};
      final key = args['key'] as String?;
      switch (call.method) {
        case 'write':
          secrets[key!] = args['value'] as String;
        case 'read':
          return secrets[key];
        case 'containsKey':
          return secrets.containsKey(key);
        case 'delete':
          secrets.remove(key);
        case 'readAll':
          return Map<String, String>.from(secrets);
        case 'deleteAll':
          secrets.clear();
      }
      return null;
    });
  }

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

  /// 容器里 sshd（22 端口）上 ESTABLISHED 的 TCP 连接数。直接读内核连接表，不经 SSH 登录，
  /// 检查本身不会被算进去。这是「App 说关了，socket 是不是真关了」的独立观察口（R08 停止条件）。
  Future<int> sshdConnections(String service) async {
    final result = await Process.run('docker', [
      'compose',
      '-f',
      'tool/fixture-environment/compose.yaml',
      'exec',
      '-T',
      service,
      'sh',
      '-c',
      'cat /proc/net/tcp /proc/net/tcp6 2>/dev/null',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    var count = 0;
    for (final line in (result.stdout as String).split('\n')) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length < 4 || !fields[1].contains(':')) continue;
      if (fields[1].endsWith(':0016') && fields[3] == '01') count++;
    }
    return count;
  }

  Future<void> killSessions(String service) async {
    final result = await Process.run('docker', [
      'compose',
      '-f',
      'tool/fixture-environment/compose.yaml',
      'exec',
      '-T',
      service,
      'pkill',
      '-KILL',
      '-f',
      'sshd-session',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  }

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

  group('R08 连接代次、取消与资源所有权（真实 OpenSSH）', () {
    late VaultRepository repository;
    late ProviderContainer container;
    late SessionController controller;

    ProviderContainer open() {
      final value = ProviderContainer(overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
      ]);
      container = value;
      controller = value.read(sessionControllerProvider.notifier);
      return value;
    }

    setUp(() async {
      if (fixture == null) return;
      useMemorySecureStorage();
      SharedPreferences.setMockInitialValues({});
      repository = await VaultRepository.open();
      open();
    });

    tearDown(() async {
      if (fixture == null) return;
      container.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });

    Future<void> eventually(Future<bool> Function() condition, String what,
        {Duration timeout = const Duration(seconds: 5)}) async {
      final deadline = DateTime.now().add(timeout);
      while (!await condition()) {
        if (DateTime.now().isAfter(deadline)) fail('等待超时：$what');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    /// 主机指纹核对可以被「挂住」，模拟用户还没在弹窗里点确认。
    /// hold() 之后第一个到达的核对会停住：reached 完成表示它确实停在这里了，release 放行。
    final gate = (
      pending: <Completer<bool>>[],
      reached: <Completer<void>>[],
    );
    Future<bool> Function(HostProfile, String, String) gatedVerifier(
        Map<String, String> fingerprints) {
      return (host, algorithm, fingerprint) async {
        if (gate.pending.isNotEmpty) {
          final waiting = gate.pending.removeAt(0);
          gate.reached.removeAt(0).complete();
          if (!await waiting.future) return false;
        }
        return fingerprint == fingerprints[host.hostname];
      };
    }

    ({Future<void> reached, void Function() release}) hold() {
      final waiting = Completer<bool>();
      final reached = Completer<void>();
      gate.pending.add(waiting);
      gate.reached.add(reached);
      return (reached: reached.future, release: () => waiting.complete(true));
    }

    setUp(() {
      gate.pending.clear();
      gate.reached.clear();
    });

    HostProfile targetViaDante(String id) {
      final f = fixture!;
      return HostProfile({
        ...targetViaProxy({
          'type': 'socks5',
          'host': f.socksAuthHost,
          'port': f.socksAuthPort,
          'username': f.socksUser,
          'password': f.socksPassword,
        }).data,
        'id': id,
        'label': id,
      });
    }

    test('NET09 真实连接：指纹确认挂着时取消→马上再连→旧确认迟到，旧连接不复活', () async {
      final f = fixture!;
      final host = targetViaDante('net09');
      await container.read(vaultControllerProvider.notifier).upsertHost(host);
      final verify = gatedVerifier({f.targetName: f.targetFingerprint});
      final baseline = await sshdConnections('target');

      final held = hold();
      final first = controller.connect(host, verify);
      await held.reached;
      expect(controller.state.pendingConnections.single.stage?.step,
          ConnectionStep.handshake);
      expect(await sshdConnections('target'), baseline + 1,
          reason: '取消前第一次尝试确实已经连到目标（卡在指纹确认）');

      final watch = Stopwatch()..start();
      controller.cancelPendingConnection(
          controller.state.pendingConnections.single.id);
      await first;
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
      await eventually(
          () async => await sshdConnections('target') == baseline,
          '取消后目标上那条连接被关掉');

      await controller.connect(host, verify);
      held.release(); // 旧尝试的指纹确认这时才到
      await Future<void>.delayed(const Duration(seconds: 1));

      final session = controller.state.sessions.single;
      expect(session.connected, isTrue);
      expect(await runInSession(session, 'hostname'), 'target');
      expect(controller.state.pendingConnections, isEmpty);
      expect(await sshdConnections('target'), baseline + 1,
          reason: '只剩新连接；旧尝试迟到的确认没有让它复活出第二条');
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

    test('NET09 恢复进行中关标签：恢复出的连接被关，服务器上不留连接', () async {
      final f = fixture!;
      final verify = gatedVerifier({'127.0.0.1': f.edgeFingerprint});
      await controller.connect(edgeHost({'id': 'restore-close'}), verify);
      final old = controller.state.sessions.single;
      await killSessions('ssh-edge');
      await waitUntil(() => !old.connected);

      final held = hold();
      final restoring = controller.reconnectDisconnected();
      await held.reached; // 恢复已经连到服务器，卡在指纹确认
      await controller.close(0);
      held.release();
      await restoring;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(controller.state.sessions, isEmpty);
      await eventually(
          () async => await sshdConnections('ssh-edge') == 0, '边缘上不留连接');
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

    test('NET10 两个主机各走不同代理账号；连接中改其中一个：互不污染，运行中的连接不换代理和身份', () async {
      final f = fixture!;
      final proxyB = await Socks5Fixture.start(
        username: 'account-b',
        password: 'secret-b',
        names: {'edge-b.internal': (host: f.edgeHost, port: f.edgePort)},
      );
      addTearDown(proxyB.close);
      final hostA = targetViaDante('net10-a');
      final hostB = HostProfile({
        'id': 'net10-b',
        'label': 'net10-b',
        'hostname': 'edge-b.internal',
        'port': 22,
        'username': f.user,
        'password': f.password,
        'authMethod': 'password',
        'protocol': 'ssh',
        'proxyConfig': {
          'type': 'socks5',
          'host': proxyB.host,
          'port': proxyB.port,
          'username': 'account-b',
          'password': 'secret-b',
        },
      });
      final vault = container.read(vaultControllerProvider.notifier);
      await vault.upsertHost(hostA);
      await vault.upsertHost(hostB);
      final verify = gatedVerifier({
        f.targetName: f.targetFingerprint,
        'edge-b.internal': f.edgeFingerprint,
      });

      // A 卡在指纹确认时，B 同时连；再把 A 的代理改成 B 的账号、用户名改掉。
      final held = hold();
      final connectingA = controller.connect(hostA, verify);
      await held.reached;
      await controller.connect(hostB, verify);
      await vault.upsertHost(HostProfile({
        ...hostA.data,
        'username': 'nobody',
        'proxyConfig': hostB.data['proxyConfig'],
      }));
      held.release();
      await connectingA;

      final sessionA =
          controller.state.sessions.firstWhere((s) => s.host.id == hostA.id);
      final sessionB =
          controller.state.sessions.firstWhere((s) => s.host.id == hostB.id);
      expect(await runInSession(sessionA, 'hostname'), 'target',
          reason: 'A 按开始连接时的路线走 dante，用的是 A 的代理账号');
      expect(await runInSession(sessionA, 'whoami'), f.user);
      expect(await runInSession(sessionB, 'hostname'), 'ssh-edge');
      expect(
          proxyB.attempts
              .map((a) => '${a.username}/${a.password}->${a.requestedHost}'),
          ['account-b/secret-b->edge-b.internal'],
          reason: 'B 的代理只见过 B 自己的账号和目标');

      // 连接回写（最近连接时间、系统识别）落盘后，A 的编辑还在。
      await Future<void>.delayed(const Duration(seconds: 2));
      final savedA = (await vault.ready())
          .hosts
          .firstWhere((h) => h.id == hostA.id);
      expect(savedA.username, 'nobody');
      expect((savedA.data['proxyConfig'] as Map)['username'], 'account-b');

      // A 断线自动恢复：沿用原路线（dante + A 的账号 + 原用户名），不拿改过的配置。
      await killSessions('target');
      await waitUntil(() => !sessionA.connected);
      await controller.reconnectDisconnected();
      final restoredA =
          controller.state.sessions.firstWhere((s) => s.host.id == hostA.id);
      expect(identical(restoredA, sessionA), isFalse);
      expect(await runInSession(restoredA, 'hostname'), 'target');
      expect(await runInSession(restoredA, 'whoami'), f.user);
      expect(proxyB.attempts, hasLength(1), reason: '恢复没有改走 B 的代理');
      expect(await runInSession(sessionB, 'hostname'), 'ssh-edge',
          reason: 'B 全程不受影响');

      // 新开一次 A：这才用上改过的配置（B 的代理账号 + 新用户名）。
      await expectLater(controller.connect(hostA, verify), throwsA(anything));
      expect(proxyB.attempts, hasLength(2));
      expect(proxyB.attempts.last.username, 'account-b');
      expect(proxyB.attempts.last.requestedHost, f.targetName);
    }, skip: skip, timeout: const Timeout(Duration(seconds: 90)));

    test('断线后借这条连接开的端口转发失效：新连接马上被关，不改走别的路线；条目留在列表里', () async {
      final f = fixture!;
      await controller.connect(
          edgeHost({'id': 'forward-owner'}), verifyByLogicalName);
      final session = controller.state.sessions.single;
      final forwards = container.read(portForwardControllerProvider.notifier);
      await forwards.startLocal(
        session: session,
        localPort: 0,
        remoteHost: f.targetName,
        remotePort: f.targetPort,
      );
      final port = container.read(portForwardControllerProvider).single.localPort;
      Future<String> banner() async {
        final socket = await Socket.connect('127.0.0.1', port);
        try {
          final first = await socket.first.timeout(const Duration(seconds: 3));
          return String.fromCharCodes(first);
        } on StateError {
          return ''; // 一个字节都没收到就被关了
        } finally {
          socket.destroy();
        }
      }

      expect(await banner(), startsWith('SSH-2.0-'), reason: '转发正常时经边缘到达目标');
      await killSessions('ssh-edge');
      await waitUntil(() => !session.connected);
      final watch = Stopwatch()..start();
      expect(await banner(), isEmpty, reason: '断线后转发不能再通');
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(container.read(portForwardControllerProvider), hasLength(1),
          reason: '条目还在列表里（R24 再处理），手册写了要手动停');
      await forwards
          .stop(container.read(portForwardControllerProvider).single.id);
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

    test('无全局跳板池：两条经同一跳板的连接各有自己的跳板连接；关一条不影响另一条', () async {
      final vault = container.read(vaultControllerProvider.notifier);
      final edge = edgeHost({'id': 'pool-edge', 'label': 'edge'});
      final chained = HostProfile({
        ...targetViaProxy(const {}).data,
        'id': 'pool-target',
        'proxyConfig': null,
        'hostChain': {
          'hostIds': ['pool-edge'],
        },
      });
      await vault.upsertHost(edge);
      await vault.upsertHost(chained);
      await controller.connect(chained, verifyByLogicalName);
      await controller.connect(chained, verifyByLogicalName);
      final [a, b] = controller.state.sessions;
      expect(await sshdConnections('ssh-edge'), 2,
          reason: '每条终端连接自己连一次跳板，不共用');
      expect(await sshdConnections('target'), 2);

      await controller.close(0);
      await eventually(
          () async => await sshdConnections('ssh-edge') == 1, '关掉的那条的跳板连接被释放');
      expect(await sshdConnections('target'), 1);
      expect(await runInSession(b, 'hostname'), 'target');
      expect(a.connected, isFalse);
      await controller.close(0);
      await eventually(() async => await sshdConnections('ssh-edge') == 0,
          '全部关掉后跳板上不留连接');
      expect(await sshdConnections('target'), 0);
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

    test('LIFE06（连接层部分）100 轮连接/取消/断线恢复/关闭/销毁：fd 与服务器连接不逐轮增长', () async {
      final f = fixture!;
      final vault = container.read(vaultControllerProvider.notifier);
      final edge = edgeHost({'id': 'life-edge', 'label': 'edge'});
      final chained = HostProfile({
        ...targetViaProxy(const {}).data,
        'id': 'life-target',
        'proxyConfig': null,
        'hostChain': {
          'hostIds': ['life-edge'],
        },
      });
      await vault.upsertHost(edge);
      await vault.upsertHost(chained);
      final verify = gatedVerifier({
        '127.0.0.1': f.edgeFingerprint,
        f.targetName: f.targetFingerprint,
      });
      // 用 lsof 数本进程的数字 fd。macOS 上用 Dart 列 /dev/fd 会碰到列目录自己开的那个 fd，直接报 EBADF。
      int openFds() {
        final result = Process.runSync('lsof', ['-p', '$pid', '-F', 'f']);
        return (result.stdout as String)
            .split('\n')
            .where((line) => RegExp(r'^f\d+$').hasMatch(line))
            .length;
      }

      Future<void> round(int i) async {
        switch (i % 5) {
          case 0: // 连上 → 关标签
            await controller.connect(edge, verify);
            await controller.close(0);
          case 1: // 指纹确认挂着时取消，确认迟到
            final held = hold();
            final connecting = controller.connect(edge, verify);
            await held.reached;
            controller.cancelPendingConnection(
                controller.state.pendingConnections.single.id);
            await connecting;
            held.release();
          case 2: // 断线 → 恢复 → 关标签
            await controller.connect(edge, verify);
            final old = controller.state.sessions.single;
            await killSessions('ssh-edge');
            await waitUntil(() => !old.connected);
            await controller.reconnectDisconnected();
            expect(controller.state.sessions.single.connected, isTrue);
            await controller.close(0);
          case 3: // 经跳板到目标 → 关标签
            await controller.connect(chained, verify);
            await controller.close(0);
          case 4: // 连着的时候整个 controller 销毁（应用退出）
            await controller.connect(chained, verify);
            container.dispose();
            open();
        }
      }

      for (var i = 0; i < 5; i++) {
        await round(i); // 预热：让 VM 和 DNS 之类的一次性资源先分配好
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final baseFds = openFds();
      final samples = <String>[];
      // 默认 100 轮；看内存是否走平时可以设 R08_LIFE06_ROUNDS=500 跑长一点。
      final rounds =
          int.tryParse(Platform.environment['R08_LIFE06_ROUNDS'] ?? '') ?? 100;
      for (var i = 0; i < rounds; i++) {
        await round(i);
        if ((i + 1) % (rounds ~/ 5) == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          final edgeConns = await sshdConnections('ssh-edge');
          final targetConns = await sshdConnections('target');
          samples.add('round=${i + 1} fds=${openFds()} (基线 $baseFds) '
              'edge=$edgeConns target=$targetConns '
              'rss=${(ProcessInfo.currentRss / 1048576).toStringAsFixed(1)}MB');
          expect(edgeConns, 0, reason: samples.last);
          expect(targetConns, 0, reason: samples.last);
        }
      }
      // ignore: avoid_print
      print('LIFE06 采样：\n${samples.join('\n')}');
      expect(openFds(), lessThanOrEqualTo(baseFds + 3),
          reason: 'fd 逐轮增长：\n${samples.join('\n')}');
    }, skip: skip, timeout: const Timeout(Duration(minutes: 6)));
  });

  group('R09 所有 SSH 入口走同一条路线、私钥与信任（真实 OpenSSH）', () {
    late ProviderContainer container;
    late SessionController controller;
    late RecordingDialer dialer;

    setUp(() async {
      if (fixture == null) return;
      useMemorySecureStorage();
      SharedPreferences.setMockInitialValues({});
      final repository = await VaultRepository.open();
      dialer = RecordingDialer();
      container = ProviderContainer(overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
        sshServiceProvider.overrideWithValue(SshService(dialer: dialer.call)),
      ]);
      controller = container.read(sessionControllerProvider.notifier);
    });

    tearDown(() async {
      if (fixture == null) return;
      container.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });

    /// 建好终端后依次用终端、SFTP、服务器监控、系统管理、本地端口转发访问同一台主机。
    /// 断言：手机只拨了入口一次；目标机上自始至终只有这一条 TCP 连接——没有任何入口自己另开一条。
    Future<void> everyEntryUsesTheRoute(
      HostProfile target,
      List<HostProfile> jumps, {
      required String expectedHostname,
      required String targetContainer,
      required String entry,
    }) async {
      final vault = container.read(vaultControllerProvider.notifier);
      for (final host in [...jumps, target]) {
        await vault.upsertHost(host);
      }
      expect(await sshdConnections(targetContainer), 0);
      expect(await controller.connect(target, verifyByLogicalName), isTrue);
      final session = controller.state.sessions.single;

      expect(await runInSession(session, 'hostname'), expectedHostname,
          reason: '终端');
      final listing = await SftpService(session).list('/etc');
      expect(listing.map((e) => e.name), contains('hostname'), reason: 'SFTP');
      final info = await ServerMonitorService().detect(session);
      expect(info.platform, isNotEmpty, reason: '服务器监控：识别');
      await ServerMonitorService().poll(session);
      final processes = await SystemManagementService().listProcesses(session);
      expect(processes, isNotEmpty, reason: '系统管理：进程列表');
      expect(await sshdConnections(targetContainer), 1,
          reason: '终端、SFTP、监控、系统管理都在同一条 SSH 连接里，没有谁另开一条');

      final forwards = container.read(portForwardControllerProvider.notifier);
      await forwards.startLocal(
        session: session,
        localPort: 0,
        remoteHost: '127.0.0.1',
        remotePort: 22,
      );
      final port =
          container.read(portForwardControllerProvider).single.localPort;
      final socket = await Socket.connect('127.0.0.1', port);
      final banner = Completer<List<int>>();
      final reading = socket.listen((chunk) {
        if (!banner.isCompleted) banner.complete(chunk);
      });
      expect(
          String.fromCharCodes(
              await banner.future.timeout(const Duration(seconds: 3))),
          startsWith('SSH-2.0-'),
          reason: '端口转发：经目标机转到它自己的 22 端口');
      // 转发连接还开着时再数：多出来的一条是目标机上从 127.0.0.1 连回自己 22 端口的那条，
      // 不是手机另开的。
      expect(await sshdConnections(targetContainer), 2);
      await reading.cancel();
      socket.destroy();

      expect(dialer.dials, [entry], reason: '手机只拨了入口一次，没有任何入口直连');
      await forwards
          .stop(container.read(portForwardControllerProvider).single.id);
      await controller.close(0);
    }

    test('RTE04 经 dante 代理：终端、SFTP、监控、系统管理、端口转发都在这一条连接里', () async {
      final f = fixture!;
      await everyEntryUsesTheRoute(
        targetViaProxy({
          'type': 'socks5',
          'host': f.socksAuthHost,
          'port': f.socksAuthPort,
          'username': f.socksUser,
          'password': f.socksPassword,
        }),
        const [],
        expectedHostname: 'target',
        targetContainer: 'target',
        entry: '${f.socksAuthHost}:${f.socksAuthPort}',
      );
    }, skip: skip, timeout: const Timeout(Duration(seconds: 90)));

    test('RTE04 经边缘跳板：同上，手机只拨边缘机', () async {
      final f = fixture!;
      final edge = edgeHost({'id': 'rte04-edge', 'label': 'edge'});
      await everyEntryUsesTheRoute(
        HostProfile({
          ...targetViaProxy(const {}).data,
          'id': 'rte04-target',
          'proxyConfig': null,
          'hostChain': {
            'hostIds': ['rte04-edge'],
          },
        }),
        [edge],
        expectedHostname: 'target',
        targetContainer: 'target',
        entry: '${f.edgeHost}:${f.edgePort}',
      );
    }, skip: skip, timeout: const Timeout(Duration(seconds: 90)));

    test('RTE04 直连：同上，手机只拨目标本身', () async {
      final f = fixture!;
      await everyEntryUsesTheRoute(
        edgeHost({'id': 'rte04-direct'}),
        const [],
        expectedHostname: 'ssh-edge',
        targetContainer: 'ssh-edge',
        entry: '${f.edgeHost}:${f.edgePort}',
      );
    }, skip: skip, timeout: const Timeout(Duration(seconds: 90)));

    test('服务器没开 SFTP：10 秒内报清楚原因，不无限转圈；终端连接不受影响', () async {
      final f = fixture!;
      final vault = container.read(vaultControllerProvider.notifier);
      final edge = edgeHost({'id': 'nosftp-edge', 'label': 'edge'});
      final hop3 = HostProfile({
        'id': 'nosftp-hop3',
        'label': 'hop3',
        'hostname': f.hop3Name,
        'port': f.hop3Port,
        'username': f.user,
        'password': f.password,
        'authMethod': 'password',
        'protocol': 'ssh',
        'hostChain': {
          'hostIds': ['nosftp-edge'],
        },
      });
      await vault.upsertHost(edge);
      await vault.upsertHost(hop3);
      expect(await controller.connect(hop3, verifyByLogicalName), isTrue);
      final session = controller.state.sessions.single;
      final watch = Stopwatch()..start();
      Object? error;
      try {
        await SftpService(session).list('/');
      } catch (e) {
        error = e;
      }
      expect(watch.elapsed, lessThan(const Duration(seconds: 13)));
      expect('$error', contains('服务器没有回应 SFTP'));
      expect(await runInSession(session, 'hostname'), 'ssh-hop3');
      await controller.close(0);
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

    test('SEC06 加密私钥：口令对能登录；口令错、密文被改都在拨号前拒绝', () async {
      final f = fixture!;
      final dir = await Directory.systemTemp.createTemp('xwshun-sec06-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/id')..writeAsStringSync(f.privateKeyPem);
      await Process.run('chmod', ['600', file.path]);
      final reencrypt = await Process.run('ssh-keygen',
          ['-q', '-p', '-P', '', '-N', 'right-pass', '-f', file.path]);
      expect(reencrypt.exitCode, 0, reason: '${reencrypt.stderr}');
      final encrypted = file.readAsStringSync();
      expect(encrypted, contains('OPENSSH PRIVATE KEY'));

      final lines = const LineSplitter().convert(encrypted.trim());
      final blob = base64.decode(lines.sublist(1, lines.length - 1).join());
      blob[blob.length - 72] ^= 0xff; // 私钥种子里的一个字节
      final tampered = [lines.first, base64.encode(blob), lines.last].join('\n');

      Future<Object?> login(String pem, String passphrase) async {
        final host = edgeHost({
          'id': 'sec06',
          'authMethod': 'key',
          'password': null,
          'identityFileId': 'k',
        });
        final key = SshKeyProfile(
            {'id': 'k', 'label': 'k', 'privateKey': pem, 'passphrase': passphrase});
        try {
          final session = await SshService(dialer: dialer.call).connect(
            sessionId: 'sec06',
            host: host,
            hosts: [host],
            keys: [key],
            verifyHostKey: verifyByLogicalName,
          );
          final name = await runInSession(session, 'hostname');
          await session.close();
          return name;
        } catch (error) {
          return error;
        }
      }

      expect(await login(encrypted, 'right-pass'), 'ssh-edge');
      expect(dialer.dials, hasLength(1));

      final wrong = await login(encrypted, 'wrong-pass');
      expect('$wrong', contains('私钥口令不对'));
      final damaged = await login(tampered, 'right-pass');
      expect('$damaged', contains('私钥内容已损坏'));
      expect(dialer.dials, hasLength(1), reason: '口令错、密文被改时一次都没拨');
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

    test('SEC04 信任按逻辑名：同一台机器换个名字要重新核对；只改大小写或用户名不用', () async {
      final f = fixture!;
      var knownHosts = <Map<String, dynamic>>[];
      final prompts = <String>[];
      Future<bool> verify(HostProfile host, String type, String fp) =>
          verifyHostKeyWithKnownHosts(
            knownHosts: knownHosts,
            hostname: host.hostname,
            port: host.port,
            keyType: type,
            fingerprint: fp,
            confirmNew: () async {
              prompts.add(host.hostname);
              return fp == f.edgeFingerprint;
            },
            onChanged: (_) async => false,
            save: (value) async => knownHosts = value,
          );
      Future<void> connectAs(Map<String, Object?> extra) async {
        final host = edgeHost(extra);
        final session = await SshService().connect(
          sessionId: 'sec04',
          host: host,
          hosts: [host],
          verifyHostKey: verify,
        );
        await session.close();
      }

      await connectAs({'hostname': 'localhost'});
      expect(prompts, ['localhost'], reason: '第一次见要核对');
      await connectAs({'hostname': 'LOCALHOST'});
      expect(prompts, ['localhost'], reason: '只是大小写不同，不再问');

      Object? wrongUser;
      try {
        await connectAs({'hostname': 'localhost', 'username': 'nobody-here'});
      } catch (error) {
        wrongUser = error;
      }
      expect('$wrongUser', contains('登录被拒绝'),
          reason: '换了用户名：信任照旧（没再问），登录按新用户名进行');
      expect(prompts, ['localhost']);

      await connectAs({'hostname': '127.0.0.1'});
      expect(prompts, ['localhost', '127.0.0.1'],
          reason: '同一台机器的另一个名字不隐式沿用信任');
      expect(knownHosts.map((e) => e['hostname']), ['localhost', '127.0.0.1']);
    }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));
  });
}
