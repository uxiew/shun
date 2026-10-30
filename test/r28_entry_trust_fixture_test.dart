import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/host_trust.dart';
import 'package:shun/domain/ai_cli_launch.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/tmux/ai_cli_tmux_run.dart';
import 'package:shun/domain/tmux/tmux_target.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';

import 'fixtures/docker_fixture.dart';
import 'fixtures/net/socks5_fixture.dart';
import 'fixtures/net/trap_server.dart';
import 'support/test_terminal.dart';

// R28：把 SshService 的每个公开入口都拿来打一遍指纹（SEC01–SEC04）。
// 入口清单是从 SSHClient( 的唯一构造处倒推出来的（plan/v3/evidence/R28.md 表 2）。
// 核对函数用生产规则 verifyHostKeyWithKnownHosts，只把弹框换成计数和预设回答；
// 「有没有发认证」看服务端 sshd（LogLevel VERBOSE）的日志，不听 App 自己说。
// 依赖 tool/fixture-environment，没起 fixture 时整组 skip，证据里记 NOT_RUN。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = DockerFixture.load();
  final skip = fixture == null ? DockerFixture.skipReason : false;

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

  Future<String> newLines(String service, List<String> before) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final after = await sshdLog(service);
    return after.sublist(before.length - 1).join('\n');
  }

  // 服务端收到过 USERAUTH_REQUEST 就会出现其中一个：登录成功 / 失败 / 等下一步，
  // 或者断开时标成「authenticating user」（OpenSSH 只在知道用户名之后才这么写）。
  const authMarks = ['Accepted', 'Failed', 'Postponed', 'authenticating user'];

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

  String keyType(String service) =>
      File('tool/fixture-environment/.run/hostkeys/$service.pub')
          .readAsStringSync()
          .split(' ')
          .first;

  Map<String, dynamic> record(String host, int port, String type, String fp) =>
      {'hostname': host, 'port': port, 'keyType': type, 'fingerprint': fp};

  /// 一条路线：要连的主机、保险库里的全部主机、这次实际会碰到哪台 sshd。
  ({HostProfile host, List<HostProfile> hosts, String service}) route(
      String name, Socks5Fixture? evil) {
    final f = fixture!;
    final edge = node('edge', f.edgeHost, f.edgePort);
    return switch (name) {
      'direct' => (host: edge, hosts: [edge], service: 'ssh-edge'),
      'socks' => () {
          final target = node('target', f.targetName, f.targetPort, {
            'proxyConfig': {
              'type': 'socks5',
              'host': f.socksAuthHost,
              'port': f.socksNoAuthPort,
            },
          });
          return (host: target, hosts: [target], service: 'target');
        }(),
      'jump' => () {
          final target = node('target', f.targetName, f.targetPort, {
            'hostChain': {
              'hostIds': ['edge'],
            },
          });
          return (host: target, hosts: [edge, target], service: 'target');
        }(),
      // 代理把「target.fixture.internal」偷偷转到边缘那台 sshd（SEC03）。
      'evil-socks' => () {
          final target = node('target', f.targetName, f.targetPort, {
            'proxyConfig': {
              'type': 'socks5',
              'host': evil!.host,
              'port': evil.port,
            },
          });
          return (host: target, hosts: [target], service: 'ssh-edge');
        }(),
      _ => throw ArgumentError(name),
    };
  }

  final requestId = '0f8b6a4e-3c2d-4e1f-9a7b-5c6d7e8f9a0b';
  AiCliTmuxRun aiRun(RoutePlan plan) => AiCliTmuxRun(
        requestId: requestId,
        target: TmuxTarget(
          hostKey: plan.target.endpoint.authority,
          unixUser: 'fixture',
          uid: 1000,
          socket: const TmuxSocketSpec.standard(),
          server: const TmuxServerIdentity(
              socketPath: '/tmp/tmux-1000/default', pid: 4242, startTime: 1),
          sessionId: r'$1',
          sessionCreated: 1,
          displayName: 'shun-ai-$requestId',
        ),
        windowId: '@1',
        paneId: '%1',
        panePid: 4242,
      );

  /// 表 2 里会自己拨号的入口。返回值只用来判断「不该走到这里」。
  final entries = <String,
      Future<Object?> Function(SshService ssh, HostProfile host, RoutePlan plan,
          HostKeyVerifier verify)>{
    'connect': (ssh, host, plan, verify) async {
      final session = await ssh.connect(
        sessionId: 'r28-connect',
        host: host,
        routePlan: plan,
        verifyHostKey: verify,
        terminal: newTestTerminal(),
      );
      session.abort();
      return session;
    },
    'connectAiCli': (ssh, host, plan, verify) async {
      final session = await ssh.connectAiCli(
        sessionId: 'r28-ai',
        host: host,
        routePlan: plan,
        verifyHostKey: verify,
        terminal: newTestTerminal(),
        attempt: ConnectionAttempt(),
        launch: AiCliLaunchSpec(
            executable: '/usr/bin/true', projectDirectory: '/tmp'),
      );
      session.abort();
      return session;
    },
    'connectAiTmux': (ssh, host, plan, verify) async {
      final session = await ssh.connectAiTmux(
        sessionId: 'r28-ai-tmux',
        host: host,
        routePlan: plan,
        verifyHostKey: verify,
        terminal: newTestTerminal(),
        attempt: ConnectionAttempt(),
        run: aiRun(plan),
      );
      session.abort();
      return session;
    },
    'probe': (ssh, host, plan, verify) => ssh.probe(
          host: host,
          routePlan: plan,
          verifyHostKey: verify,
          attempt: ConnectionAttempt(),
        ),
    'withVerifiedClient': (ssh, host, plan, verify) => ssh.withVerifiedClient(
          routePlan: plan,
          verifyHostKey: verify,
          attempt: ConnectionAttempt(),
          query: (_) async => 'reached',
        ),
    'withVerifiedClientForAiTmux': (ssh, host, plan, verify) =>
        ssh.withVerifiedClientForAiTmux(
          routePlan: plan,
          verifyHostKey: verify,
          attempt: ConnectionAttempt(),
          action: (_) async => 'reached',
        ),
    'bootstrapMosh': (ssh, host, plan, verify) => ssh.bootstrapMosh(
          plan: plan,
          verifyHostKey: verify,
          attempt: ConnectionAttempt(),
        ),
    'bootstrapMoshTmux': (ssh, host, plan, verify) => ssh.bootstrapMoshTmux(
          plan: plan,
          verifyHostKey: verify,
          attempt: ConnectionAttempt(),
          tmux: aiRun(plan).target,
          then: (_, __) async => 'reached',
        ),
  };
  const moshEntries = {'bootstrapMosh', 'bootstrapMoshTmux'};

  group('R28 每个 SSH 入口的指纹', () {
    late Socks5Fixture evil;
    setUp(() async {
      final f = fixture!;
      evil = await Socks5Fixture.start(names: {
        f.targetName: (host: f.edgeHost, port: f.edgePort),
      });
    });
    tearDown(() => evil.close());

    /// 保险库里已有的信任记录：边缘那台是真的；目标记的是 [targetFp]。
    List<Map<String, dynamic>> knownWith(String targetFp) {
      final f = fixture!;
      final edge =
          record(f.edgeHost, f.edgePort, keyType('ssh-edge'), f.edgeFingerprint);
      return [
        edge,
        record(f.targetName, f.targetPort, keyType('target'), targetFp),
      ];
    }

    test('对照：每条路线正常连一次，对应 sshd 日志里确实搜得到登录记录', () async {
      final f = fixture!;
      for (final name in ['direct', 'socks', 'jump']) {
        final r = route(name, evil);
        final before = await sshdLog(r.service);
        final trust = _Trust(knownWith(f.targetFingerprint));
        await SshService().probe(
          host: r.host,
          hosts: r.hosts,
          verifyHostKey: trust.call,
          attempt: ConnectionAttempt(),
        );
        final lines = await newLines(r.service, before);
        expect(lines, contains('Accepted password for ${f.user}'),
            reason: '$name：搜不到正常登录就证明不了「没发认证」');
        expect(trust.asked, isEmpty);
      }
    }, skip: skip);

    for (final routeName in ['direct', 'socks', 'jump', 'evil-socks']) {
      for (final entry in entries.entries) {
        test('SEC02/SEC03 $routeName · ${entry.key}：目标指纹对不上就硬拦，不弹「新主机」，这台收不到认证',
            () async {
          final f = fixture!;
          final r = route(routeName, evil);
          final plan = resolveRoutePlan(r.host,
              hosts: r.hosts, proxyProfiles: const []);
          final dialer = RecordingDialer();
          final ssh = SshService(dialer: dialer.call);
          if (moshEntries.contains(entry.key) && routeName != 'direct') {
            // Mosh 只认直连：经代理或跳板要在拨号前就拒，不能退成直连。
            await expectLater(
                entry.value(ssh, r.host, plan, (_, __, ___) async => true),
                throwsA(isA<StateError>()));
            expect(dialer.dials, isEmpty);
            return;
          }
          // 换钥：直连时边缘就是目标，把它的记录改成别的指纹；其余改目标的。
          // 恶意代理那条保险库是对的，是代理把连接送到了别的机器。
          final known = switch (routeName) {
            'direct' => [
                record(f.edgeHost, f.edgePort, keyType('ssh-edge'),
                    f.hop2Fingerprint),
              ],
            'evil-socks' => knownWith(f.targetFingerprint),
            _ => knownWith(f.hop2Fingerprint),
          };
          // 用户在「指纹变了」里选了「删掉旧指纹」：最容易被当成放行的那一种。
          final trust = _Trust(known, deleteOnChange: true);
          final before = await sshdLog(r.service);
          Object? reached;
          try {
            reached = await entry.value(ssh, r.host, plan, trust.call);
          } on RouteHopException catch (error) {
            expect(error.message, contains('主机指纹没有通过校验'));
          }
          expect(reached, isNull, reason: '指纹没过却走到了登录之后');
          final logical = routeName == 'direct'
              ? '${f.edgeHost}:${f.edgePort}'
              : '${f.targetName}:${f.targetPort}';
          expect(trust.changed, [logical]);
          expect(trust.asked, isEmpty, reason: '指纹变了不能当成新主机再问一遍');
          expect(trust.trusted, isNot(contains(logical)),
              reason: '旧记录删了，但这次不能顺手记下新指纹');
          if (routeName == 'evil-socks') {
            expect(dialer.dials, ['${evil.host}:${evil.port}'],
                reason: '只拨代理，不自己去连目标');
          }
          final lines = await newLines(r.service, before);
          expect(lines, contains('[preauth]'), reason: '连接应当在认证前断开');
          for (final mark in authMarks) {
            expect(lines, isNot(contains(mark)),
                reason: '${r.service} 收到了登录数据（$mark）');
          }
        }, skip: skip);
      }
    }

    for (final routeName in ['direct', 'socks', 'jump']) {
      for (final name in ['connect', 'probe', 'withVerifiedClient']) {
        test('SEC03 $routeName · $name：第一次见必须问用户，拒了就不认证、不记', () async {
          final f = fixture!;
          final r = route(routeName, evil);
          final plan = resolveRoutePlan(r.host,
              hosts: r.hosts, proxyProfiles: const []);
          final trust = _Trust(routeName == 'jump'
              ? [
                  record(f.edgeHost, f.edgePort, keyType('ssh-edge'),
                      f.edgeFingerprint),
                ]
              : []);
          final before = await sshdLog(r.service);
          Object? reached;
          try {
            reached = await entries[name]!(SshService(), r.host, plan, trust.call);
          } on RouteHopException catch (error) {
            expect(error.message, contains('主机指纹没有通过校验'));
          }
          expect(reached, isNull);
          final logical = routeName == 'direct'
              ? '${f.edgeHost}:${f.edgePort}'
              : '${f.targetName}:${f.targetPort}';
          expect(trust.asked, [logical]);
          expect(trust.trusted, isNot(contains(logical)));
          final lines = await newLines(r.service, before);
          for (final mark in authMarks) {
            expect(lines, isNot(contains(mark)), reason: mark);
          }
        }, skip: skip);
      }
    }

    test('SEC01 三个入口、两个 SOCKS 端口加跳板连同一目标：只问一次，只记逻辑名:端口', () async {
      final f = fixture!;
      final trust = _Trust([], acceptNew: true);
      final edge = node('edge', f.edgeHost, f.edgePort);
      HostProfile viaSocks(int port) =>
          node('target', f.targetName, f.targetPort, {
            'proxyConfig': {
              'type': 'socks5',
              'host': f.socksAuthHost,
              'port': port,
              if (port == f.socksAuthPort) 'username': f.socksUser,
              if (port == f.socksAuthPort) 'password': f.socksPassword,
            },
          });
      final viaJump = node('target', f.targetName, f.targetPort, {
        'hostChain': {
          'hostIds': ['edge'],
        },
      });
      final runs = [
        ('probe', viaSocks(f.socksAuthPort), [viaSocks(f.socksAuthPort)]),
        ('connect', viaSocks(f.socksNoAuthPort), [viaSocks(f.socksNoAuthPort)]),
        ('withVerifiedClient', viaJump, [edge, viaJump]),
      ];
      for (final (name, host, hosts) in runs) {
        final plan =
            resolveRoutePlan(host, hosts: hosts, proxyProfiles: const []);
        expect(await entries[name]!(SshService(), host, plan, trust.call),
            isNotNull,
            reason: name);
      }
      final target = '${f.targetName}:${f.targetPort}';
      final edgeKey = '${f.edgeHost}:${f.edgePort}';
      expect(trust.asked, [target, edgeKey],
          reason: '目标只在第一次见时问，换代理端口、换成跳板都不再问；跳板自己是另一台');
      expect(trust.trusted.toSet(), {target, edgeKey});
      for (final port in [f.socksAuthPort, f.socksNoAuthPort]) {
        expect(trust.trusted, isNot(contains('${f.socksAuthHost}:$port')));
      }
    }, skip: skip);

    test('SEC04 同一台机器换个名字（localhost）要重新核对；只改用户名不用', () async {
      final f = fixture!;
      final trust = _Trust([
        record(f.edgeHost, f.edgePort, keyType('ssh-edge'), f.edgeFingerprint),
      ]);
      final alias = node('edge', 'localhost', f.edgePort);
      final aliasPlan =
          resolveRoutePlan(alias, hosts: [alias], proxyProfiles: const []);
      await expectLater(
          entries['probe']!(SshService(), alias, aliasPlan, trust.call),
          throwsA(isA<RouteHopException>()));
      expect(trust.asked, ['localhost:${f.edgePort}'],
          reason: '别名不能靠 DNS 或同一把钥自动继承信任');
      final otherUser = node('edge', f.edgeHost, f.edgePort, {
        'username': 'nobody-$requestId',
      });
      final userPlan = resolveRoutePlan(otherUser,
          hosts: [otherUser], proxyProfiles: const []);
      // 用户名不对会登录失败，但失败的是登录而不是指纹：Unix 用户不是信任身份的一部分。
      await expectLater(
          entries['probe']!(SshService(), otherUser, userPlan, trust.call),
          throwsA(isA<RouteHopException>().having(
              (e) => e.message, 'message', contains('登录被拒绝'))));
      expect(trust.asked, ['localhost:${f.edgePort}']);
    }, skip: skip);
  });
}

/// 生产规则（host_trust.dart），弹框换成记录 + 预设回答。
/// 这和 connection_prompts.dart 的 hostKeyVerifier 传的参数一样：host.hostname + host.port。
class _Trust {
  _Trust(this.records, {this.acceptNew = false, this.deleteOnChange = false});

  List<Map<String, dynamic>> records;
  final bool acceptNew;
  final bool deleteOnChange;
  final asked = <String>[];
  final changed = <String>[];

  List<String> get trusted =>
      [for (final value in records) '${value['hostname']}:${value['port']}'];

  Future<bool> call(HostProfile host, String algorithm, String fingerprint) =>
      verifyHostKeyWithKnownHosts(
        knownHosts: records,
        hostname: host.hostname,
        port: host.port,
        keyType: algorithm,
        fingerprint: fingerprint,
        confirmNew: () async {
          asked.add('${host.hostname}:${host.port}');
          return acceptNew;
        },
        onChanged: (_) async {
          changed.add('${host.hostname}:${host.port}');
          return deleteOnChange;
        },
        save: (value) async => records = value,
      );
}
