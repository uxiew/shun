// SYN04 的设备部分：同一台设备上走真网卡地址、真 socket、真安全存储。没有两台手机，所以不算 SYN04 通过。
//
// 发送页出码 → 错密钥试一次 → 删掉本机主机 → 接收页扫码（扫码这步直接给内容）→ 确认导入 →
// 重新打开仓库读回密码 → 同一张码再扫拿不到。
//
// 跑法：SHUN_R39_AVD=shun-r39-a30 python3 tool/fixture-drive.py integration_test/r62_lan_transfer_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shun/app.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/sensitive_screen.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/infrastructure/qr_scanner.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/sync/lan_transfer.dart';
import 'package:shun/presentation/screens/lan_transfer_screen.dart';
import 'package:shun/presentation/screens/settings_screen.dart';

void report(String key, Object? value) => debugPrint('R62 $key=$value');

Future<void> settle(WidgetTester tester, [int ms = 600]) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> waitFor(WidgetTester tester, bool Function() condition,
    {required String what,
    Duration timeout = const Duration(seconds: 40)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待$what超时');
    await tester.pump(const Duration(milliseconds: 50));
  }
}

class _GivenText implements QrScanner {
  String? text;

  @override
  Future<String?> scan({required String prompt}) async => text;
}

VaultData seed() => VaultData.fromJson({
      'hosts': [
        {
          'id': 'r62',
          'label': 'r62',
          'hostname': '192.0.2.10',
          'username': 'ops',
          'port': 22,
          'protocol': 'ssh',
          'authMethod': 'password',
          'password': 'R62-HOST-PASSWORD',
        },
      ],
      'keys': const [],
      'snippets': const [],
      'customGroups': const [],
      'identities': const [
        {
          'id': 'r62-identity',
          'label': 'identity',
          'username': 'ops',
          'authMethod': 'password',
          'password': 'R62-IDENTITY-PASSWORD',
        },
      ],
    });

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('SYN04 同一台设备：真地址互传带凭据回来，密钥只用一次', (tester) async {
    for (final interface in await NetworkInterface.list()) {
      report(
          'interface',
          '${interface.name} '
              '${interface.addresses.map((a) => a.address).join(',')}');
    }
    final addresses = await lanAddresses();
    report('lanAddresses', addresses.join(','));
    expect(addresses, isNotEmpty);

    final repository = await VaultRepository.open();
    final scanner = _GivenText();
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      qrScannerProvider.overrideWithValue(scanner),
    ]);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const ShunApp(),
    ));
    await settle(tester, 1500);

    final vault = container.read(vaultControllerProvider.notifier);
    await vault.replace(seed());
    await settle(tester);

    // 从设置进发送页。
    container.read(homeTabProvider.notifier).state = 4;
    await settle(tester);
    final settingsList = find
        .descendant(
            of: find.byType(SettingsScreen), matching: find.byType(Scrollable))
        .first;
    final send = find.byKey(const ValueKey('lan-send'));
    await tester.scrollUntilVisible(send, 240, scrollable: settingsList);
    await settle(tester);
    await tester.tap(send);
    await waitFor(
      tester,
      () => find.byType(LanQrCode).evaluate().isNotEmpty,
      what: '二维码',
    );
    await settle(tester);
    expect(SensitiveScreenGuard.instance.secure, isTrue);
    report('send.secure', true);

    final text = tester.widget<LanQrCode>(find.byType(LanQrCode)).data;
    final pairing = LanPairing.tryParse(text);
    expect(pairing, isNotNull, reason: '真地址要能过解析');
    report('pairing.addresses', pairing!.addresses.join(','));
    report('qr.length', text.length);

    // 错密钥：拿不到，发送页还在等。
    Object? wrongKey;
    await receiveLanTransfer(LanPairing(
      addresses: pairing.addresses,
      port: pairing.port,
      key: List.filled(32, 7),
      expiresAt: pairing.expiresAt,
    )).then<void>((_) {}, onError: (Object error) => wrongKey = error);
    expect(wrongKey, isA<LanTransferWrongPeer>());
    await settle(tester);
    expect(find.byType(LanQrCode), findsOneWidget);
    report('wrongKey', wrongKey.runtimeType);

    // 删掉本机的，这样导回来才看得见效果；安全存储里的密码也跟着删了。
    final data = await vault.ready();
    await vault.replace(data.copyWith(hosts: const [], extras: {
      ...data.extras,
      'identities': const [],
    }));
    expect((await VaultRepository.open()).loadVaultPreview()?.hosts, isEmpty);

    // 接收页盖在发送页上。
    scanner.text = text;
    unawaited(Navigator.of(tester.element(find.byType(LanQrCode))).push(
        MaterialPageRoute<void>(builder: (_) => const LanReceiveScreen())));
    await waitFor(
      tester,
      () => find
          .byKey(const ValueKey('vault-import-merge'))
          .evaluate()
          .isNotEmpty,
      what: '导入确认框',
    );
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('vault-import-merge')));
    await waitFor(
      tester,
      () => find.textContaining('恢复完成').evaluate().isNotEmpty,
      what: '恢复完成',
    );
    await settle(tester);
    report('receive.done', true);

    // 重新打开仓库读：密码真的进了安全存储。
    final reopened = await (await VaultRepository.open()).loadVault();
    expect(reopened.hosts.single.toJson()['password'], 'R62-HOST-PASSWORD');
    expect(
      '${(reopened.extras['identities'] as List).single}',
      contains('R62-IDENTITY-PASSWORD'),
    );
    report('secrets.readBack', true);

    // 退回发送页：显示已传完。
    await tester.tap(find.byType(BackButton));
    await settle(tester, 1000);
    expect(find.byType(LanReceiveScreen), findsNothing);
    expect(find.text('已传完'), findsOneWidget);
    report('send.delivered', true);

    // 密钥只用一次：同一张码再扫，端口已经关了。
    Object? again;
    await receiveLanTransfer(pairing)
        .then<void>((_) {}, onError: (Object error) => again = error);
    expect(again, isA<LanTransferUnreachable>());
    report('secondScan', again.runtimeType);

    await tester.tap(find.byType(BackButton));
    await settle(tester, 1000);
    expect(find.byType(LanSendScreen), findsNothing);
  });

  testWidgets('过期之前离开页面：端口关掉', (tester) async {
    final addresses = await lanAddresses();
    final repository = await VaultRepository.open();
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
    ]);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: _Opener()),
    ));
    await settle(tester);
    await tester.tap(find.text('open'));
    await waitFor(
      tester,
      () => find.byType(LanQrCode).evaluate().isNotEmpty,
      what: '二维码',
    );
    final pairing = LanPairing.tryParse(
      tester.widget<LanQrCode>(find.byType(LanQrCode)).data,
    )!;
    final probe = await Socket.connect(addresses.first, pairing.port);
    probe.destroy();
    await tester.tap(find.byType(BackButton));
    await settle(tester, 1200);
    Object? refused;
    await Socket.connect(addresses.first, pairing.port)
        .then((socket) => socket.destroy(), onError: (Object e) => refused = e);
    expect(refused, isA<SocketException>());
    report('leave.portClosed', true);
  });
}

class _Opener extends StatelessWidget {
  const _Opener();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const LanSendScreen()),
          ),
          child: const Text('open'),
        ),
      );
}
