import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/sftp_service.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';

import 'fixtures/docker_fixture.dart';
import 'fixtures/net/trap_server.dart';

// R24：文件、监控、系统管理、端口转发借标签上那条 SSH，在真实 OpenSSH 的 Direct / SOCKS / Jump 三种路线上测。
// 依赖 tool/fixture-environment；没起时整组 skip，证据里记 NOT_RUN。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = DockerFixture.load();
  final skip = fixture == null ? DockerFixture.skipReason : false;

  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final secrets = <String, String>{};
  setUp(() {
    secrets.clear();
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
  });

  Future<bool> verifyByLogicalName(
      HostProfile host, String algorithm, String fingerprint) async {
    final f = fixture!;
    return fingerprint ==
        {
          '127.0.0.1': f.edgeFingerprint,
          f.targetName: f.targetFingerprint,
        }[host.hostname];
  }

  HostProfile edgeHost(String id) => HostProfile({
        'id': id,
        'label': 'edge',
        'hostname': fixture!.edgeHost,
        'port': fixture.edgePort,
        'username': fixture.user,
        'password': fixture.password,
        'authMethod': 'password',
        'protocol': 'ssh',
      });

  HostProfile target(String id, Map<String, Object?> route) => HostProfile({
        'id': id,
        'label': 'target',
        'hostname': fixture!.targetName,
        'port': fixture.targetPort,
        'username': fixture.user,
        'password': fixture.password,
        'authMethod': 'password',
        'protocol': 'ssh',
        ...route,
      });

  Future<ProcessResult> compose(List<String> args) => Process.run('docker',
      ['compose', '-f', 'tool/fixture-environment/compose.yaml', ...args]);

  /// 容器里 sshd（22 端口）上 ESTABLISHED 的 TCP 连接数，直接读内核连接表（不经 SSH 登录）。
  Future<int> sshdConnections(String service) async {
    final result = await compose(['exec', '-T', service, 'sh', '-c',
        'cat /proc/net/tcp /proc/net/tcp6 2>/dev/null']);
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
    final result = await compose(
        ['exec', '-T', service, 'pkill', '-KILL', '-f', 'sshd-session']);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  }

  Future<void> eventually(FutureOr<bool> Function() condition, String what,
      {Duration timeout = const Duration(seconds: 15)}) async {
    final deadline = DateTime.now().add(timeout);
    while (!await condition()) {
      if (DateTime.now().isAfter(deadline)) fail('等待超时：$what');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  late ProviderContainer container;
  late SessionController controller;
  late RecordingDialer dialer;

  setUp(() async {
    if (fixture == null) return;
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

  group('REG01 借用者开着时断线：释放不半途而止', () {
    test('经跳板：终端 + 文件页开着时目标断线，标签照常自动恢复；旧一代的跳板连接被关掉', () async {
      final vault = container.read(vaultControllerProvider.notifier);
      final edge = edgeHost('reg01-edge');
      final host = target('reg01-target', {
        'hostChain': {
          'hostIds': ['reg01-edge'],
        },
      });
      await vault.upsertHost(edge);
      await vault.upsertHost(host);
      expect(await controller.connect(host, verifyByLogicalName), isTrue);
      final old = controller.state.sessions.single;
      await SftpService(old).list('/etc');
      expect(await sshdConnections('ssh-edge'), 1);
      expect(await sshdConnections('target'), 1);

      // 只杀目标上的会话：目标 client 断了，跳板 client 还活着。修之前 abort 在关目标 client 时抛错，
      // 跳板永远不关、标签不进自动恢复。
      await killSessions('target');
      await eventually(() {
        final now = controller.state.sessions.single;
        return !identical(now, old) && now.connected;
      }, '标签自动恢复成新连接');
      await eventually(
          () async => await sshdConnections('ssh-edge') == 1, '跳板上只剩新一代的连接');
      expect(await sshdConnections('target'), 1);
      expect(old.sshClients.every((c) => c.isClosed), isTrue,
          reason: '旧一代的目标和跳板 client 都关了');
      await controller.close(0);
    }, skip: skip, timeout: const Timeout(Duration(seconds: 90)));
  });
}
