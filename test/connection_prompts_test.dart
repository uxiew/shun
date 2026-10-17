// 指纹核对回调的寿命：它常常在弹出它的菜单已经关掉以后才被调用（「用 Mosh 另开一个」、「安装 mosh」都是先收菜单再连）。
// R42 在模拟器上撞到过：回调里用了已销毁菜单的 ref，抛 StateError，dartssh2 当成核对失败断开，
// 用户看到的是「登录完成前连接被对方关闭」。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/widgets/connection_prompts.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final host = HostProfile({
    'id': 'h1',
    'label': 'box',
    'hostname': 'box.example.com',
    'port': 22,
    'username': 'ops',
    'protocol': 'ssh',
  });

  testWidgets('弹出它的底部菜单关掉以后再核对：记住过的指纹照样放行，不抛异常', (tester) async {
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, null));
    SharedPreferences.setMockInitialValues({});
    final repository = (await tester.runAsync(VaultRepository.open))!;
    await tester.runAsync(() => repository.saveVault(VaultData.fromJson({
          'hosts': [host.toJson()],
          'knownHosts': [
            {
              'hostname': 'box.example.com',
              'port': 22,
              'keyType': 'ssh-ed25519',
              'fingerprint': 'SHA256:known',
            },
          ],
        })));
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    await tester.runAsync(
        () => container.read(vaultControllerProvider.notifier).ready());

    HostKeyVerifier? verify;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                builder: (_) => Consumer(
                  builder: (sheetContext, ref, _) => TextButton(
                    onPressed: () {
                      // 和「用 Mosh 另开一个」一样：在菜单里建好回调，然后收起菜单。
                      verify = hostKeyVerifier(sheetContext);
                      Navigator.of(sheetContext).pop();
                    },
                    child: const Text('switch'),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('switch'));
    await tester.pumpAndSettle();
    expect(find.text('switch'), findsNothing, reason: '菜单已经关了');

    expect(await verify!(host, 'ssh-ed25519', 'SHA256:known'), isTrue);
    // 没记住过的：弹窗的页面已经没了，按拒绝处理，也不抛异常。
    expect(await verify!(host, 'ssh-ed25519', 'SHA256:other'), isFalse);
  });
}
