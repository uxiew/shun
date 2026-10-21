import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/connection_diagnosis.dart';
import 'package:shun/application/connection_events.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/screens/connection_log_screen.dart';

// R25 / UX10、SEC12、UX02：连接记录页。名字按保险库查、导出先预览且不带名字、清除要确认。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.now().toUtc();

  HostProfile host(String id, String label) => HostProfile({
        'id': id,
        'label': label,
        'hostname': '$id.decoy.example',
        'port': 22,
        'username': 'decoy-user',
        'protocol': 'ssh',
      });

  final opened = ConnectionEvent(
    hostId: 'host-alpha',
    at: now.subtract(const Duration(minutes: 3)),
    kind: ConnectionEventKind.open,
    protocol: HostProtocol.ssh,
    entry: ConnectionEntryKind.direct,
    hopIds: const ['host-alpha'],
    stages: const [
      ConnectionEventStage(ConnectionStep.dial, 0, Duration(milliseconds: 2)),
      ConnectionEventStage(
        ConnectionStep.handshake,
        0,
        Duration(milliseconds: 20),
        userWait: Duration(milliseconds: 4100),
      ),
      ConnectionEventStage(
          ConnectionStep.shell, 0, Duration(milliseconds: 4300)),
    ],
    outcome: ConnectionOutcome.connected,
    total: const Duration(milliseconds: 4350),
  );
  final failed = ConnectionEvent(
    hostId: 'host-alpha',
    at: now.subtract(const Duration(minutes: 2)),
    kind: ConnectionEventKind.restore,
    protocol: HostProtocol.ssh,
    entry: ConnectionEntryKind.socks5,
    hopIds: const ['host-edge', 'host-alpha'],
    stages: const [
      ConnectionEventStage(ConnectionStep.proxy, 0, Duration(milliseconds: 1)),
      ConnectionEventStage(
          ConnectionStep.handshake, 0, Duration(milliseconds: 40)),
      ConnectionEventStage(
          ConnectionStep.forward, 0, Duration(milliseconds: 90)),
      ConnectionEventStage(
          ConnectionStep.handshake, 1, Duration(milliseconds: 95)),
    ],
    outcome: ConnectionOutcome.failed,
    total: const Duration(milliseconds: 180),
    failure: ConnectionFailureKind.authFailed,
    failureHop: 1,
    attempt: 2,
  );
  final dropped = ConnectionEvent(
    hostId: 'host-alpha',
    at: now.subtract(const Duration(minutes: 1)),
    kind: ConnectionEventKind.drop,
    protocol: HostProtocol.ssh,
    dropReason: ConnectionDropReason.closed,
  );
  final other = ConnectionEvent(
    hostId: 'host-beta',
    at: now,
    kind: ConnectionEventKind.probe,
    protocol: HostProtocol.ssh,
    outcome: ConnectionOutcome.cancelled,
    total: const Duration(milliseconds: 5),
  );

  late MemoryConnectionEventStore store;

  Future<void> open(WidgetTester tester, {String? hostId}) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async => null);
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    store = MemoryConnectionEventStore([opened, failed, dropped, other]);
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      connectionEventStoreProvider.overrideWithValue(store),
    ]);
    addTearDown(container.dispose);
    final vault = container.read(vaultControllerProvider.notifier);
    await vault.ready();
    await vault.upsertHost(host('host-alpha', 'LABEL-ALPHA'));
    await vault.upsertHost(host('host-edge', 'LABEL-EDGE'));
    await vault.upsertHost(host('host-beta', 'LABEL-BETA'));
    await container.read(connectionEventLogProvider.notifier).ready;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: ConnectionLogScreen(hostId: hostId)),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('一台主机：最新的在上；展开看得到路线、失败在哪一跳、各阶段用时和下一步', (tester) async {
    await open(tester, hostId: 'host-alpha');
    expect(find.text('LABEL-ALPHA'), findsOneWidget, reason: '标题下是保险库里的名字');
    expect(find.textContaining('LABEL-BETA'), findsNothing, reason: '别的主机的不列');
    final titles = tester
        .widgetList<Text>(find.descendant(
            of: find.byType(ExpansionTile), matching: find.byType(Text)))
        .map((t) => t.data ?? '')
        .where((t) => t.contains(' · '))
        .toList();
    expect(titles.first, startsWith('连接断开'), reason: '最新的在最上面');
    expect(
        find.byKey(const ValueKey('connection-log-summary')), findsOneWidget);
    expect(find.textContaining('失败 1'), findsOneWidget);

    await tester.tap(find.textContaining('自动恢复（第 2 次）'));
    await tester.pumpAndSettle();
    expect(
      find.text('手机 → SOCKS5 代理 → 跳板机“LABEL-EDGE” → 目标“LABEL-ALPHA”'),
      findsOneWidget,
    );
    expect(find.text('失败在：目标“LABEL-ALPHA”'), findsOneWidget);
    expect(find.textContaining('目标“LABEL-ALPHA” · SSH 握手、核对指纹、登录（停在这一步）'),
        findsOneWidget);
    expect(find.text('85 ms'), findsOneWidget, reason: '最后一步 95→180 ms');
    expect(find.textContaining('服务器拒绝了登录'), findsOneWidget, reason: '下一步');

    await tester.ensureVisible(find.textContaining('新开连接'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('新开连接'));
    await tester.pumpAndSettle();
    expect(find.textContaining('其中等你 4.1 秒'), findsOneWidget,
        reason: '等人确认指纹的时间单独标出，不当成握手慢');
    expect(find.textContaining('ping'), findsOneWidget,
        reason: '只在顶上说明里出现一次：「不是网络延迟（ping）」');
  });

  testWidgets('没有结果时间的阶段写「未知」，不造一个值', (tester) async {
    await open(tester, hostId: 'host-alpha');
    await tester.tap(find.textContaining('连接断开'));
    await tester.pumpAndSettle();
    expect(find.textContaining('断开前连了 未知'), findsOneWidget);
  });

  testWidgets('导出：先预览；预览和复制出去的一样，里面没有名字、ID、地址', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('connection-log-export')));
    await tester.pumpAndSettle();
    final preview = tester
        .widget<SelectableText>(
            find.byKey(const ValueKey('connection-log-export-preview')))
        .data!;
    expect(copied, isNull, reason: '预览时还没复制');
    for (final secret in ['LABEL', 'host-', 'decoy']) {
      expect(preview, isNot(contains(secret)), reason: secret);
    }
    expect(preview, contains('主机 1'));
    expect(preview, contains('主机 2'));
    expect(preview, contains('手机 → SOCKS5 代理 → 跳板 1 → 目标'));
    await tester.tap(find.byKey(const ValueKey('connection-log-copy')));
    await tester.pumpAndSettle();
    expect(copied, preview);
  });

  testWidgets('清除：要确认，取消是默认、不删；确认后只删这一台的、马上写盘', (tester) async {
    await open(tester, hostId: 'host-alpha');
    await tester.tap(find.byKey(const ValueKey('connection-log-clear')));
    await tester.pumpAndSettle();
    expect(find.textContaining('会删掉 3 条'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(ExpansionTile), findsNWidgets(3));

    await tester.tap(find.byKey(const ValueKey('connection-log-clear')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('connection-log-clear-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('connection-log-empty')), findsOneWidget);
    expect(store.saved, isNot(contains('host-alpha')));
    expect(store.saved, contains('host-beta'), reason: '别的主机的留着');
  });

  testWidgets('UX02：触控目标 48dp、可点的都有标签、文字对比度够；成败不只靠颜色', (tester) async {
    final semantics = tester.ensureSemantics();
    await open(tester);
    await tester.tap(find.textContaining('自动恢复（第 2 次）'));
    await tester.pumpAndSettle();
    for (final guideline in [
      androidTapTargetGuideline,
      labeledTapTargetGuideline,
      textContrastGuideline,
    ]) {
      final result = await guideline.evaluate(tester);
      expect(result.passed, isTrue, reason: result.reason);
    }
    expect(find.textContaining('失败：服务器拒绝登录'), findsOneWidget,
        reason: '失败写成字，不只是红色图标');
    expect(find.textContaining('已取消'), findsOneWidget);
    semantics.dispose();
  });
}
