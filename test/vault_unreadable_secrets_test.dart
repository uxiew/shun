import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/credential_availability.dart';
import 'package:netcatty_mobile/application/session_controller.dart';
import 'package:netcatty_mobile/application/vault_controller.dart';
import 'package:netcatty_mobile/domain/connection_route.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/models/vault.dart';
import 'package:netcatty_mobile/domain/tmux/tmux_target.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:netcatty_mobile/infrastructure/terminal/xterm_terminal_adapter.dart';
import 'package:netcatty_mobile/infrastructure/terminal/terminal_session_adapter.dart';

// SEC06：安全存储里某条凭据解不开（设备密钥失效、密文被改）时——
// 其余照常加载；用到它的连接在拨号前拒绝并说清原因；无关的保存不删那条密文；重新填写后恢复。
// 模拟器上真改密文的结果见 plan/v3/evidence/R09.md。
const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

class FakeSecureStorage {
  final values = <String, String>{};
  final broken = <String>{};
  final calls = <String>[];

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = (call.arguments as Map?) ?? const {};
      final key = args['key'] as String?;
      calls.add('${call.method} $key');
      switch (call.method) {
        case 'read':
          if (broken.contains(key)) {
            // 和设备上一样：插件把 SecurityException 包成 PlatformException 抛上来。
            throw PlatformException(
                code: 'Exception encountered',
                message: 'Could not decrypt value. decryption failed');
          }
          return values[key];
        case 'write':
          values[key!] = args['value'] as String;
          broken.remove(key);
        case 'delete':
          values.remove(key);
          broken.remove(key);
        case 'readAll':
          return Map<String, String>.from(values);
        case 'containsKey':
          return values.containsKey(key);
      }
      return null;
    });
  }
}

HostProfile host(String id, {Map<String, Object?> extra = const {}}) =>
    HostProfile({
      'id': id,
      'label': id,
      'hostname': '$id.example.com',
      'port': 22,
      'username': 'deploy',
      'protocol': 'ssh',
      'password': 'pw-$id',
      ...extra,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeSecureStorage storage;

  Future<VaultRepository> seeded() async {
    storage = FakeSecureStorage()..install();
    SharedPreferences.setMockInitialValues({});
    final writer = await VaultRepository.open();
    await writer.saveVault(VaultData.fromJson({
      'hosts': [host('h1').toJson(), host('h2').toJson()],
      'keys': [],
      'snippets': [],
      'customGroups': [],
    }));
    storage.broken.add('host.h1.password');
    storage.calls.clear();
    return VaultRepository.open(); // 新进程：凭据要重新从安全存储读
  }

  group('仓库逐条读凭据', () {
    test('一条解不开：其余照常加载，解不开的那条记下来，不当成成功', () async {
      final repository = await seeded();
      final vault = await repository.loadVault();
      expect(vault.hosts.firstWhere((h) => h.id == 'h2').password, 'pw-h2');
      expect(vault.hosts.firstWhere((h) => h.id == 'h1').password, isNull);
      expect(repository.unreadableSecrets, {'host.h1.password'});
    });

    test('无关的保存不删那条密文；重新填写后写入并恢复；删主机时一并删掉', () async {
      final repository = await seeded();
      final vault = await repository.loadVault();
      final renamed = VaultData.fromJson(vault.toJson());
      renamed.hosts.firstWhere((h) => h.id == 'h2').data['label'] = 'renamed';
      await repository.saveVault(renamed);
      expect(storage.calls, isNot(contains('delete host.h1.password')),
          reason: '可能只是暂时解不开，删了就真没了');
      expect(repository.unreadableSecrets, {'host.h1.password'});

      final fixed = VaultData.fromJson(renamed.toJson());
      fixed.hosts.firstWhere((h) => h.id == 'h1').data['password'] = 'new-pw';
      await repository.saveVault(fixed);
      expect(storage.values['host.h1.password'], 'new-pw');
      expect(repository.unreadableSecrets, isEmpty);

      storage.broken.add('host.h2.password');
      final again = await VaultRepository.open();
      await again.loadVault();
      expect(again.unreadableSecrets, {'host.h2.password'});
      final withoutH2 = VaultData.fromJson(fixed.toJson())
        ..hosts.removeWhere((h) => h.id == 'h2');
      await again.saveVault(withoutH2);
      expect(storage.calls, contains('delete host.h2.password'));
      expect(again.unreadableSecrets, isEmpty);
    });
  });

  group('存过却读成空（Keystore 失效时插件的实际表现）', () {
    test('之前存过的凭据现在读出空、不抛异常：同样算解不开', () async {
      await seeded();
      storage.broken.clear();
      storage.values.remove('host.h1.password'); // 插件悄悄换了一份新存储，旧值读成空
      final repository = await VaultRepository.open();
      await repository.loadVault();
      expect(repository.unreadableSecrets, {'host.h1.password'});
    });

    test('清单只有键名没有值；旧安装没有清单时按第一次读到的补上', () async {
      await seeded();
      final prefs = await SharedPreferences.getInstance();
      final index = prefs.getStringList('xwshun_secret_index_v1')!;
      expect(index, containsAll(['host.h1.password', 'host.h2.password']));
      expect(index.join(), isNot(contains('pw-')), reason: '只记键名');

      storage.broken.clear();
      await prefs.remove('xwshun_secret_index_v1'); // 升级前的安装
      final first = await VaultRepository.open();
      await first.loadVault();
      expect(first.unreadableSecrets, isEmpty, reason: '没有清单就无从判断，不误报');
      expect(prefs.getStringList('xwshun_secret_index_v1'),
          containsAll(['host.h1.password', 'host.h2.password']));

      storage.values.remove('host.h2.password');
      final later = await VaultRepository.open();
      await later.loadVault();
      expect(later.unreadableSecrets, {'host.h2.password'});
    });
  });

  group('路线要用的凭据', () {
    final vault = VaultData.fromJson({
      'hosts': [
        host('jump', extra: {'authMethod': 'key', 'identityFileId': 'k1'})
            .toJson(),
        host('t', extra: {
          'hostChain': {
            'hostIds': ['jump'],
          },
          'proxyProfileId': 'p1',
        }).toJson(),
        host('keyonly', extra: {'authMethod': 'key', 'identityFileId': 'k2'})
            .toJson(),
      ],
      'keys': [],
      'snippets': [],
      'customGroups': [],
    });
    HostProfile byId(String id) => vault.hosts.firstWhere((h) => h.id == id);

    test('目标的登录密码解不开：拒绝并说清是谁、哪种凭据', () {
      expect(unreadableCredentialProblem(byId('t'), vault, {'host.t.password'}),
          startsWith('目标“t”：登录密码无法解密'));
    });

    test('跳板机的私钥、目标的代理口令解不开：按那一跳说明', () {
      expect(
          unreadableCredentialProblem(byId('t'), vault, {'key.k1.passphrase'}),
          startsWith('跳板机“jump”：私钥无法解密'));
      expect(
          unreadableCredentialProblem(byId('t'), vault, {'proxy.p1.password'}),
          startsWith('目标“t”：代理口令无法解密'));
    });

    test('路线用不到的那条解不开：不拦', () {
      expect(
          unreadableCredentialProblem(
              byId('keyonly'), vault, {'host.keyonly.password'}),
          isNull,
          reason: '只用私钥登录，密码解不开无所谓');
      expect(
          unreadableCredentialProblem(byId('t'), vault,
              {'host.t.telnetPassword', 'host.other.password'}),
          isNull);
    });
  });

  test('连接入口：用到解不开凭据的主机在拨号前拒绝，界面标失败并写原因；别的主机照常', () async {
    final repository = await seeded();
    final service = _RecordingService();
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      sshServiceProvider.overrideWithValue(service),
    ]);
    addTearDown(container.dispose);
    final controller = container.read(sessionControllerProvider.notifier);
    final vault =
        await container.read(vaultControllerProvider.notifier).ready();
    expect(container.read(vaultControllerProvider).unreadableSecrets,
        {'host.h1.password'},
        reason: '保险库页据此显示提示');

    await expectLater(
      controller.connect(vault.hosts.firstWhere((h) => h.id == 'h1'),
          (_, __, ___) async => true),
      throwsA(isA<CredentialUnavailableException>()
          .having((e) => e.message, 'message', contains('登录密码无法解密'))),
    );
    expect(service.connected, isEmpty, reason: '一次都没拨');
    final failed = controller.state.pendingConnections.single;
    expect(failed.phase, PendingConnectionPhase.failed);
    expect('${failed.error}', contains('重新填写'));

    expect(
        await controller.connect(vault.hosts.firstWhere((h) => h.id == 'h2'),
            (_, __, ___) async => true),
        isTrue);
    expect(service.connected, ['h2']);
  });
}

class _RecordingService extends SshService {
  final connected = <String>[];

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
    connected.add(host.id);
    return _NeverDone(sessionId, host);
  }
}

class _NeverDone extends ActiveTerminalSession {
  _NeverDone(String id, HostProfile host)
      : super(
          id: id,
          host: host,
          terminal: XtermTerminalAdapter(),
          verifyHostKey: (_, __, ___) async => true,
          keyboardInteractive: null,
        );

  final _done = Completer<void>();

  @override
  Future<void> get done => _done.future;
}
