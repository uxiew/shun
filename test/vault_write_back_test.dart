import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

// R08 / NET10：连接产生的保险库回写（最近连接时间、识别出的系统）只补字段、基于最新数据、
// 不复活已删除的主机，并和主机编辑排队执行。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async => null);
  });

  final host = HostProfile.create(
    id: 'h1',
    label: 'web',
    hostname: 'web.example.com',
    username: 'root',
  );

  group('NET10 连接回写不污染用户的编辑', () {
    late VaultController vault;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      vault = VaultController(await VaultRepository.open());
      await vault.ready();
    });
    tearDown(() => vault.dispose());

    test('连接期间改了主机：记录最近连接时间不会把改动冲掉', () async {
      await vault.upsertHost(host);
      final snapshot = (await vault.ready()).hosts.single;
      await vault.upsertHost(snapshot.copyWith(
        hostname: 'edited.example.com',
        username: 'deploy',
      ));
      await vault.markConnected(snapshot); // 连接开始时的旧快照
      final saved = (await vault.ready()).hosts.single;
      expect(saved.hostname, 'edited.example.com');
      expect(saved.username, 'deploy');
      expect(saved.data['lastConnectedAt'], isNotNull);
    });

    test('识别系统的回写只补字段；主机已被删除就不写，不会被加回来', () async {
      await vault.upsertHost(host);
      await vault.upsertHost(host.copyWith(username: 'edited'));
      await vault.patchHost(host.id, {'os': 'linux', 'distro': 'alpine'});
      var saved = (await vault.ready()).hosts.single;
      expect(saved.username, 'edited');
      expect(saved.data['distro'], 'alpine');

      await vault.deleteHost(host.id);
      await vault.patchHost(host.id, {'os': 'linux'});
      await vault.markConnected(saved);
      expect((await vault.ready()).hosts, isEmpty);
    });

    test('编辑还在保存时连接回写到达：排队执行，编辑不被盖掉', () async {
      await vault.upsertHost(host);
      final snapshot = (await vault.ready()).hosts.single;
      // 不排队时，回写读到的是编辑落盘前的旧列表，存盘后把用户名改回去。
      final editing = vault.upsertHost(snapshot.copyWith(username: 'edited'));
      final marking = vault.markConnected(snapshot);
      await Future.wait([editing, marking]);
      final saved = (await vault.ready()).hosts.single;
      expect(saved.username, 'edited');
      expect(saved.data['lastConnectedAt'], isNotNull);
    });
  });
}
