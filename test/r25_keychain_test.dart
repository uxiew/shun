import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/ssh_key_type.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/widgets/keychain_sheet.dart';

import 'support/prism_test_host.dart';

// R25 第四部分：私钥列表的类型照实写（以前一律 ED25519），删除前先问、写出哪些主机在用。
// 测试用的私钥现场用 ssh-keygen 生成，没有 ssh-keygen 的机器这一组跳过。
void main() {
  final hasKeygen = Process.runSync('which', ['ssh-keygen']).exitCode == 0;
  late Directory dir;
  final keys = <String, String>{};

  setUpAll(() async {
    if (!hasKeygen) return;
    dir = await Directory.systemTemp.createTemp('shun-keytype-');
    Future<void> gen(String name, List<String> args) async {
      final result = await Process.run(
          'ssh-keygen', ['-q', ...args, '-C', '', '-f', '${dir.path}/$name']);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      keys[name] = File('${dir.path}/$name').readAsStringSync();
    }

    await gen('ed25519', ['-t', 'ed25519', '-N', '']);
    await gen('ed25519_enc', ['-t', 'ed25519', '-N', 'pass']);
    await gen('rsa', ['-t', 'rsa', '-b', '2048', '-N', '']);
    await gen('rsa_pem', ['-t', 'rsa', '-b', '2048', '-m', 'PEM', '-N', '']);
    await gen('ecdsa', ['-t', 'ecdsa', '-b', '256', '-N', '']);
    await gen('ecdsa_pem', ['-t', 'ecdsa', '-b', '256', '-m', 'PEM', '-N', '']);
  });
  tearDownAll(() async {
    if (hasKeygen) await dir.delete(recursive: true);
  });

  test('类型照实读，加密的也不要口令', () {
    expect(sshKeyTypeOf(keys['ed25519']!), 'ED25519');
    expect(sshKeyTypeOf(keys['ed25519_enc']!), 'ED25519');
    expect(sshKeyTypeOf(keys['rsa']!), 'RSA');
    expect(sshKeyTypeOf(keys['rsa_pem']!), 'RSA');
    expect(sshKeyTypeOf(keys['ecdsa']!), 'ECDSA');
    expect(sshKeyTypeOf(keys['ecdsa_pem']!), 'ECDSA');
  }, skip: hasKeygen ? false : '没有 ssh-keygen');

  test('认不出就是 null，不猜', () {
    expect(sshKeyTypeOf('not a key'), isNull);
    expect(
        sshKeyTypeOf('-----BEGIN OPENSSH PRIVATE KEY-----\n!!!\n'
            '-----END OPENSSH PRIVATE KEY-----'),
        isNull);
    expect(
        sshKeyTypeOf('-----BEGIN OPENSSH PRIVATE KEY-----\n'
            '${base64.encode(utf8.encode('openssh-key-v1\x00'))}\n'
            '-----END OPENSSH PRIVATE KEY-----'),
        isNull,
        reason: '截断的文件');
    expect(
        sshKeyTypeOf(
            '-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----'),
        isNull,
        reason: 'PKCS#8 头里没写类型');
  });

  group('删除私钥', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    Future<ProviderContainer> open(WidgetTester tester) async {
      const channel =
          MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => null);
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      SharedPreferences.setMockInitialValues({
        'shun_vault_v1': jsonEncode({
          'hosts': [
            {
              'id': 'web',
              'label': 'web',
              'hostname': '192.0.2.10',
              'username': 'ops',
              'port': 22,
              'identityFileId': 'k1',
            },
            {
              'id': 'db',
              'label': 'db',
              'hostname': '192.0.2.11',
              'username': 'ops',
              'port': 22,
            },
          ],
          'keys': [
            {'id': 'k1', 'label': 'laptop', 'type': 'ED25519'},
            {'id': 'k2', 'label': 'spare', 'type': 'RSA'},
          ],
          'snippets': const [],
          'customGroups': const [],
        }),
      });
      final repository = await VaultRepository.open();
      final container = ProviderContainer(overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
      ]);
      addTearDown(container.dispose);
      await container.read(vaultControllerProvider.notifier).ready();
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: prismTestDelegates,
          builder: prismTestBuilder,
          home: const KeychainSheet(),
        ),
      ));
      await tester.pumpAndSettle();
      return container;
    }

    List<String> keyIds(ProviderContainer container) => [
          for (final key in container.read(vaultControllerProvider).data!.keys)
            key.id
        ];

    testWidgets('先问，写出在用它的主机；取消就不删', (tester) async {
      final container = await open(tester);
      await tester.tap(find.byKey(const ValueKey('keychain-delete-k1')));
      await tester.pumpAndSettle();
      expect(find.textContaining('这些在用它：web。'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(keyIds(container), ['k1', 'k2']);

      await tester.tap(find.byKey(const ValueKey('keychain-delete-k1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('keychain-confirm-delete')));
      await tester.pumpAndSettle();
      expect(keyIds(container), ['k2']);
    });

    testWidgets('没人用的：直说没有主机在用', (tester) async {
      final container = await open(tester);
      await tester.tap(find.byKey(const ValueKey('keychain-delete-k2')));
      await tester.pumpAndSettle();
      expect(find.text('没有主机在用它。删了不能撤销。'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('keychain-confirm-delete')));
      await tester.pumpAndSettle();
      expect(keyIds(container), ['k1']);
    });
  });
}
