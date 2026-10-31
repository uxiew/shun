// SEC14 设备验证：真 App 页面、真安全存储、真 SSH（测试环境的 ssh-edge）。
// 第一次连接在核对框里接受 → 再连不问 → 在可信主机密钥页删掉 → 再连又弹核对框，拒绝就连不上。
//
// 只用 tool/fixture-drive.py 跑，它转端口、传测试环境凭据、跑完清掉 App 数据。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shun/app.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/host_trust.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/screens/settings_screen.dart';
import 'package:shun/presentation/widgets/connection_prompts.dart';

const _raw = String.fromEnvironment('SHUN_FIXTURE');
final Map<String, dynamic> fixture =
    _raw.isEmpty ? const {} : jsonDecode(_raw) as Map<String, dynamic>;

void report(String key, Object? value) => debugPrint('R65 $key=$value');

Future<void> settle(WidgetTester tester, [int ms = 600]) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> waitFor(WidgetTester tester, bool Function() condition,
    {required String what,
    Duration timeout = const Duration(seconds: 30)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待$what超时');
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('SEC14 删一条指纹后重连按第一次见核对', (tester) async {
    final repository = await VaultRepository.open();
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
    ]);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const ShunApp(),
    ));
    await settle(tester, 1500);

    final vault = container.read(vaultControllerProvider.notifier);
    final sessions = container.read(sessionControllerProvider.notifier);
    final port = fixture['edgePort'] as int;
    final host = HostProfile({
      'id': 'r65',
      'label': 'r65',
      'hostname': '127.0.0.1',
      'port': port,
      'username': fixture['user'],
      'password': fixture['password'],
      'authMethod': 'password',
      'protocol': 'ssh',
    });
    await vault.upsertHost(host);
    await settle(tester);

    List<Map<String, dynamic>> known() => knownHostsFromExtras(
        container.read(vaultControllerProvider).data!.extras);
    final context = tester.element(find.byType(Scaffold).first);
    final verifier = hostKeyVerifier(context);
    final prompt = find.text('确认服务器指纹');
    final fingerprint = fixture['edgeFingerprint'] as String;

    // 第一次：核对框里的指纹就是测试环境那台的，接受后记下。
    final first = sessions.connect(host, verifier);
    await waitFor(tester, () => prompt.evaluate().isNotEmpty, what: '第一次的核对框');
    expect(find.textContaining(fingerprint), findsOneWidget);
    await tester.tap(find.text('接受并记住'));
    expect(await first, isTrue);
    expect(known().single['fingerprint'], fingerprint);
    report('first.record', known().single['keyType']);
    await sessions.close(0);
    await settle(tester);

    // 第二次：指纹对得上，不问。
    expect(await sessions.connect(host, verifier), isTrue);
    expect(prompt, findsNothing);
    report('second.prompted', false);
    await sessions.close(0);
    await settle(tester);

    // 从设置进页面，看得到这条，删掉。
    container.read(homeTabProvider.notifier).state = 4;
    await settle(tester);
    final entry = find.byKey(const ValueKey('settings-known-hosts'));
    await tester.scrollUntilVisible(entry, 240,
        scrollable: find
            .descendant(
                of: find.byType(SettingsScreen),
                matching: find.byType(Scrollable))
            .first);
    await settle(tester);
    await tester.tap(entry);
    await settle(tester);
    final row = find.byKey(ValueKey('known-host-127.0.0.1:$port'));
    expect(row, findsOneWidget);
    expect(find.text(fingerprint), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);
    await tester.tap(
        find.descendant(of: row, matching: find.byIcon(Icons.delete_outline)));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await waitFor(tester, () => known().isEmpty, what: '删掉记录');
    await settle(tester);
    expect(find.text('还没有接受过服务器'), findsOneWidget);
    report('deleted', true);
    await tester.tap(find.byType(BackButton));
    await settle(tester);

    // 删完再连：又弹核对框。点拒绝就连不上，也不记。
    Object? refused;
    final third = sessions.connect(host, verifier).catchError((Object error) {
      refused = error;
      return false;
    });
    await waitFor(tester, () => prompt.evaluate().isNotEmpty, what: '删完后的核对框');
    await tester.tap(find.text('拒绝'));
    expect(await third, isFalse);
    await settle(tester);
    expect(known(), isEmpty);
    report('reconnect.prompted', true);
    report('reconnect.refused', refused?.runtimeType);
    await sessions.close(0);

    // 重新接受后又能连：删一条不会把主机弄坏。
    final fourth = sessions.connect(host, verifier);
    await waitFor(tester, () => prompt.evaluate().isNotEmpty, what: '再次的核对框');
    await tester.tap(find.text('接受并记住'));
    expect(await fourth, isTrue);
    expect(known(), hasLength(1));
    report('reaccepted', true);
    await sessions.close(0);
    await settle(tester);
  }, skip: fixture.isEmpty);
}
