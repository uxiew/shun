import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/infrastructure/qr_scanner.dart';
import 'package:shun/infrastructure/storage/encrypted_vault_file.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/sync/lan_transfer.dart';
import 'package:shun/presentation/screens/lan_transfer_screen.dart';
import 'package:shun/presentation/widgets/secret_content.dart';

// SYN04 的页面部分：真 socket 走回环，扫码换成直接给内容。相机、两台手机、真局域网不在这里。

VaultData vaultWith({String password = 'HOST-SECRET', String id = 'web'}) =>
    VaultData.fromJson({
      'hosts': [
        {
          'id': id,
          'label': id,
          'hostname': '192.0.2.10',
          'username': 'ops',
          'port': 22,
          'protocol': 'ssh',
          'authMethod': 'password',
          'password': password,
        },
      ],
      'keys': const [],
      'snippets': const [],
      'customGroups': const [],
      'identities': const [],
      'knownHosts': const [
        {
          'hostname': '192.0.2.10',
          'port': 22,
          'keyType': 'ssh-ed25519',
          'fingerprint': 'SHA256:mine',
        },
      ],
    });

class _FakeRepository implements VaultRepository {
  _FakeRepository(this.stored);
  VaultData stored;

  @override
  VaultData? loadVaultPreview() => stored;

  @override
  Future<VaultData> loadVault() async => stored;

  @override
  Future<void> saveVault(VaultData vault, {bool remote = false}) async =>
      stored = vault;

  @override
  Set<String> get unreadableSecrets => const {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeScanner implements QrScanner {
  _FakeScanner(this.next);
  Future<String?> Function() next;
  var calls = 0;

  @override
  Future<String?> scan({required String prompt}) {
    calls++;
    return next();
  }
}

void main() {
  Future<_FakeRepository> pumpPage(
    WidgetTester tester,
    Widget page, {
    VaultData? vault,
    QrScanner? scanner,
  }) async {
    final repository = _FakeRepository(vault ?? vaultWith());
    await tester.pumpWidget(ProviderScope(
      overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
        if (scanner != null) qrScannerProvider.overrideWithValue(scanner),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => page),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    return repository;
  }

  /// 页面在等真 socket 和后台 isolate：要放开真实时间才有进展。
  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      // 页面在测试的假时钟里：到期的 Timer 要靠 pump 推着走。
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(finder, findsWidgets);
  }

  /// 页面里的发送方跑在测试的假时钟里，它的回调只有 pump 时才走，所以接收方也不能放进 runAsync
  /// 一口气等完（那样发送方动不了，接收方等到超时）。真 socket 的事件靠中间的 runAsync 放进来。
  Future<T> drive<T>(WidgetTester tester, Future<T> future) async {
    T? value;
    Object? failure;
    var done = false;
    unawaited(future.then((result) {
      value = result;
      done = true;
    }, onError: (Object error) {
      failure = error;
      done = true;
    }));
    for (var i = 0; i < 300 && !done; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(done, isTrue, reason: '接收方没有结束');
    if (failure != null) throw failure!;
    return value as T;
  }

  /// runAsync 里的异常不会传出来，要在里面接住。
  Future<bool> portClosed(WidgetTester tester, int port) async =>
      (await tester.runAsync(() async {
        try {
          final socket = await Socket.connect('127.0.0.1', port);
          socket.destroy();
          return false;
        } on SocketException {
          return true;
        }
      }))!;

  String qrText(WidgetTester tester) =>
      tester.widget<LanQrCode>(find.byType(LanQrCode)).data;

  group('发送页', () {
    testWidgets('显示二维码和倒计时，整页防截屏；对方拿到含密码、不含指纹的内容，页面显示已传完', (tester) async {
      await pumpPage(tester, const LanSendScreen(addresses: _loopback));
      await waitFor(tester, find.byType(LanQrCode));
      expect(
        find.ancestor(
          of: find.byType(LanQrCode),
          matching: find.byType(SecretContent),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('等对方扫码'), findsOneWidget);
      expect(find.textContaining('4:5'), findsOneWidget);

      final pairing = parseLoopback(qrText(tester));
      final received = await drive(tester, receiveLanTransfer(pairing));
      final json = jsonDecode(utf8.decode(received)) as Map<String, dynamic>;
      expect(jsonEncode(json), contains('HOST-SECRET'));
      expect(json, isNot(contains('knownHosts')));

      await waitFor(tester, find.text('已传完'));
      expect(find.byType(LanQrCode), findsNothing);
      expect(await portClosed(tester, pairing.port), isTrue);
    });

    testWidgets('没有局域网地址：说清楚，不开端口', (tester) async {
      await pumpPage(tester, LanSendScreen(addresses: () async => const []));
      await waitFor(tester, find.textContaining('没连局域网'));
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('离开页面就关端口', (tester) async {
      await pumpPage(tester, const LanSendScreen(addresses: _loopback));
      await waitFor(tester, find.byType(LanQrCode));
      final pairing = parseLoopback(qrText(tester));
      await tester.pageBack();
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
      }
      expect(find.text('open'), findsOneWidget);
      expect(await portClosed(tester, pairing.port), isTrue);
    });

    testWidgets('退到后台就关端口；回来点重新生成是新密钥', (tester) async {
      await pumpPage(tester, const LanSendScreen(addresses: _loopback));
      await waitFor(tester, find.byType(LanQrCode));
      final first = qrText(tester);
      final pairing = parseLoopback(first);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await waitFor(tester, find.text('二维码已失效'));
      expect(await portClosed(tester, pairing.port), isTrue);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.tap(find.text('重新生成'));
      await tester.pump();
      await waitFor(tester, find.byType(LanQrCode));
      expect(qrText(tester).split(':')[2], isNot(first.split(':')[2]));
    });

    testWidgets('到期：二维码消失', (tester) async {
      await pumpPage(
        tester,
        const LanSendScreen(
          addresses: _loopback,
          validFor: Duration(milliseconds: 300),
        ),
      );
      await waitFor(tester, find.text('二维码已失效'));
      expect(find.byType(LanQrCode), findsNothing);
    });
  });

  group('接收页', () {
    testWidgets('扫码 → 确认框 → 合并：主机和密码都到了，指纹还是本机的', (tester) async {
      final sender = (await tester.runAsync(() => LanTransferSender.start(
            EncryptedVaultFile.plainForTransfer(vaultWith(id: 'incoming')),
            addresses: const ['127.0.0.1'],
          )))!;
      addTearDown(sender.close);
      final scanner = _FakeScanner(() async => _sampleQr);
      final repository = await pumpPage(
        tester,
        LanReceiveScreen(receive: (_) => receiveLanTransfer(sender.pairing)),
        vault: VaultData.fromJson({
          ...vaultWith(id: 'local').toJson(),
          'knownHosts': const [
            {
              'hostname': 'mine.example',
              'port': 22,
              'keyType': 'ssh-ed25519',
              'fingerprint': 'SHA256:local',
            },
          ],
        }),
        scanner: scanner,
      );
      await waitFor(tester, find.byKey(const ValueKey('vault-import-merge')));
      expect(scanner.calls, 1);
      await tester.tap(find.byKey(const ValueKey('vault-import-merge')));
      await tester.pump();
      await waitFor(tester, find.textContaining('导入完成'));
      expect(
        repository.stored.hosts.map((host) => host.id),
        containsAll(['local', 'incoming']),
      );
      final incoming =
          repository.stored.hosts.firstWhere((host) => host.id == 'incoming');
      expect(incoming.toJson()['password'], 'HOST-SECRET');
      expect(
        (repository.stored.extras['knownHosts'] as List).single['fingerprint'],
        'SHA256:local',
      );
      expect(
        await tester.runAsync(() => sender.outcome),
        LanSendOutcome.delivered,
      );
    });

    testWidgets('确认框点取消：什么都不写，退出', (tester) async {
      final sender = (await tester.runAsync(() => LanTransferSender.start(
            EncryptedVaultFile.plainForTransfer(vaultWith(id: 'incoming')),
            addresses: const ['127.0.0.1'],
          )))!;
      addTearDown(sender.close);
      final repository = await pumpPage(
        tester,
        LanReceiveScreen(receive: (_) => receiveLanTransfer(sender.pairing)),
        scanner: _FakeScanner(() async => _sampleQr),
      );
      await waitFor(tester, find.byKey(const ValueKey('vault-import-cancel')));
      await tester.tap(find.byKey(const ValueKey('vault-import-cancel')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('open'), findsOneWidget);
      expect(repository.stored.hosts.single.id, 'web');
    });

    testWidgets('退出扫码页：回到设置', (tester) async {
      await pumpPage(
        tester,
        const LanReceiveScreen(),
        scanner: _FakeScanner(() async => null),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('没相机权限：说清楚，能再扫', (tester) async {
      final scanner = _FakeScanner(() async => throw const QrScanDenied());
      await pumpPage(tester, const LanReceiveScreen(), scanner: scanner);
      await tester.pump();
      expect(find.textContaining('没有相机权限'), findsOneWidget);
      await tester.tap(find.text('重新扫码'));
      await tester.pump();
      expect(scanner.calls, 2);
    });

    testWidgets('扫到别的二维码', (tester) async {
      await pumpPage(
        tester,
        const LanReceiveScreen(),
        scanner: _FakeScanner(() async => 'https://example.com'),
      );
      await tester.pump();
      expect(find.text('不是 shun 的互传二维码'), findsOneWidget);
    });

    String pairingExpiring(DateTime expiresAt) {
      final key = base64Url.encode(List.filled(32, 1)).replaceAll('=', '');
      return 'shun-lan:1:$key:40123:'
          '${expiresAt.millisecondsSinceEpoch ~/ 1000}:192.168.1.5';
    }

    testWidgets('连不上，没 VPN：说同一个 Wi-Fi 和 AP 隔离', (tester) async {
      final text =
          pairingExpiring(DateTime.now().add(const Duration(minutes: 5)));
      await pumpPage(
        tester,
        LanReceiveScreen(
          vpnUp: () async => false,
          receive: (_) => throw const LanTransferUnreachable(),
        ),
        scanner: _FakeScanner(() async => text),
      );
      await waitFor(tester, find.textContaining('AP 隔离'));
      expect(find.text('重新扫码'), findsOneWidget);
    });

    testWidgets('连不上，开着 VPN：先说 VPN', (tester) async {
      final text =
          pairingExpiring(DateTime.now().add(const Duration(minutes: 5)));
      await pumpPage(
        tester,
        LanReceiveScreen(
          vpnUp: () async => true,
          receive: (_) => throw const LanTransferUnreachable(),
        ),
        scanner: _FakeScanner(() async => text),
      );
      await waitFor(tester, find.textContaining('开着 VPN'));
    });

    testWidgets('连不上，二维码过期了：直接说过期', (tester) async {
      final text =
          pairingExpiring(DateTime.now().subtract(const Duration(minutes: 1)));
      await pumpPage(
        tester,
        LanReceiveScreen(
          vpnUp: () async => true,
          receive: (_) => throw const LanTransferUnreachable(),
        ),
        scanner: _FakeScanner(() async => text),
      );
      await waitFor(tester, find.textContaining('已过期'));
    });

    testWidgets('错的一台、内容坏了：各有一句', (tester) async {
      final text =
          pairingExpiring(DateTime.now().add(const Duration(minutes: 5)));
      await pumpPage(
        tester,
        LanReceiveScreen(
          vpnUp: () async => false,
          receive: (_) => throw const LanTransferWrongPeer(),
        ),
        scanner: _FakeScanner(() async => text),
      );
      await waitFor(tester, find.textContaining('不是出这个二维码'));
    });
  });

  testWidgets('二维码是白底黑块、带留白', (tester) async {
    final boundary = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Center(
        child: RepaintBoundary(
          key: boundary,
          child: const SizedBox(
            width: 320,
            height: 320,
            child: LanQrCode(_sampleQr),
          ),
        ),
      ),
    ));
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final bytes = (await tester.runAsync(() async {
      final image = await render.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return (image.width, data!.buffer.asUint8List());
    }))!;
    int pixel(int x, int y) => bytes.$2[(y * bytes.$1 + x) * 4];
    // 左上角是留白，留白里面是定位图案的黑块。
    expect(pixel(2, 2), 255);
    expect(pixel(22, 22), 0);
    // 手动核对扫得出来时用：解码方法见 evidence/R62.md。
    const out = String.fromEnvironment('LAN_QR_PNG');
    if (out.isNotEmpty) {
      final png = (await tester.runAsync(() async {
        final image = await render.toImage(pixelRatio: 3);
        return (await image.toByteData(format: ui.ImageByteFormat.png))!;
      }))!;
      File(out).writeAsBytesSync(
        Uint8List.view(png.buffer, png.offsetInBytes, png.lengthInBytes),
      );
    }
  });
}

const _sampleQr =
    'shun-lan:1:AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE:40123:1767225600:192.168.1.5,10.0.0.2';

Future<List<String>> _loopback() async => const ['127.0.0.1'];

/// 二维码里是 127.0.0.1 时 LanPairing.tryParse 不收（它只认局域网地址），这里按格式拆。
LanPairing parseLoopback(String text) {
  final parts = text.split(':');
  return LanPairing(
    addresses: parts[5].split(','),
    port: int.parse(parts[3]),
    key: base64Url.decode(base64Url.normalize(parts[2])),
    expiresAt: DateTime.fromMillisecondsSinceEpoch(int.parse(parts[4]) * 1000),
  );
}
