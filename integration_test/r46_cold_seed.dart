// R46 冷启动的种子：写一台主机、打开应用锁。tool/r46-app-lock.py 把它编成调试包跑一次，再覆盖安装真 App。
// 不放进 r46_app_lock_test.dart：flutter test 收尾会把 App 卸载，写的东西全没了。
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shun/application/settings_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox.shrink());
  final repository = await VaultRepository.open();
  final container = ProviderContainer(overrides: [
    vaultRepositoryProvider.overrideWithValue(repository),
  ]);
  final vault = container.read(vaultControllerProvider.notifier);
  await vault.load();
  await vault.upsertHost(HostProfile({
    'id': 'r46',
    'label': 'R46-SENTINEL',
    'hostname': '192.0.2.1',
    'port': 22,
    'username': 'nobody',
    'authMethod': 'password',
    'protocol': 'ssh',
  }));
  await container
      .read(settingsControllerProvider.notifier)
      .edit((s) => s.copyWith(appLockEnabled: true, appLockGraceSeconds: 0));
  debugPrint('R46 SEEDED');
}
