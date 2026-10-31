import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/app_log.dart';
import 'package:shun/application/connection_diagnosis.dart';
import 'package:shun/application/connection_events.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/screens/app_log_screen.dart';

// R26 F24：日志页。崩溃、出错、同步和连接记录合在一起、新的在上；按类筛；详情能复制；
// 导出先预览、里面没有地址和主机名；清除要确认、两边一起清。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.now();

  final crash = AppLogEntry(
    at: now.subtract(const Duration(minutes: 1)),
    kind: AppLogKind.crash,
    title: 'App 崩溃（Java 层）',
    detail: 'java.lang.IllegalStateException: boom\nthread: main',
    stack:
        'java.lang.IllegalStateException: boom\n\tat top.xdwa.shun.X.y(X.kt:1)',
  );
  final syncFailed = AppLogEntry(
    at: now.subtract(const Duration(minutes: 5)),
    kind: AppLogKind.sync,
    title: '同步失败',
    detail: 'WebDAV 401 at <host>',
    count: 3,
  );
  final event = ConnectionEvent(
    hostId: 'host-alpha',
    at: now.subtract(const Duration(minutes: 3)),
    kind: ConnectionEventKind.open,
    protocol: HostProtocol.ssh,
    entry: ConnectionEntryKind.direct,
    hopIds: const ['host-alpha'],
    stages: const [
      ConnectionEventStage(ConnectionStep.dial, 0, Duration(milliseconds: 2)),
    ],
    outcome: ConnectionOutcome.failed,
    total: const Duration(milliseconds: 30),
    failure: ConnectionFailureKind.unreachable,
    failureHop: 0,
  );

  late ProviderContainer container;

  Future<void> open(WidgetTester tester) async {
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
    final appLog =
        AppLog(MemoryAppLogStore(AppLogFile(entries: [syncFailed, crash])));
    container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      connectionEventStoreProvider
          .overrideWithValue(MemoryConnectionEventStore([event])),
      appLogProvider.overrideWith((ref) => appLog),
    ]);
    addTearDown(container.dispose);
    final vault = container.read(vaultControllerProvider.notifier);
    await vault.ready();
    await vault.upsertHost(HostProfile({
      'id': 'host-alpha',
      'label': 'LABEL-ALPHA',
      'hostname': '100.64.0.9',
      'username': 'decoy-user',
      'protocol': 'ssh',
    }));
    await container.read(connectionEventLogProvider.notifier).ready;
    await appLog.ready;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: AppLogScreen()),
    ));
    await tester.pumpAndSettle();
  }

  List<String> titles(WidgetTester tester) => tester
      .widgetList<ListTile>(find.descendant(
          of: find.byKey(const ValueKey('app-log-list')),
          matching: find.byType(ListTile)))
      .map((tile) => (tile.title! as Text).data!)
      .toList();

  testWidgets('崩溃、同步、连接合在一起，新的在上；按类筛；重复的写次数', (tester) async {
    await open(tester);
    final all = titles(tester);
    expect(all, hasLength(3));
    expect(all.first, 'App 崩溃（Java 层）');
    expect(all[1], contains('·'), reason: '中间是 3 分钟前的连接事件');
    expect(all.last, '同步失败');
    expect(find.textContaining('LABEL-ALPHA'), findsOneWidget,
        reason: '连接事件写保险库里的名字');
    expect(find.textContaining('3 次'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('app-log-filter-crash')));
    await tester.pumpAndSettle();
    expect(titles(tester), ['App 崩溃（Java 层）']);
    await tester.tap(find.byKey(const ValueKey('app-log-filter-connection')));
    await tester.pumpAndSettle();
    expect(titles(tester), hasLength(1));
    expect(titles(tester).single, isNot('App 崩溃（Java 层）'));
  });

  testWidgets('点开看全文：报错和堆栈都在，能复制', (tester) async {
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
    await tester.tap(find.text('App 崩溃（Java 层）'));
    await tester.pumpAndSettle();
    final details = tester
        .widget<SelectableText>(find.byKey(const ValueKey('app-log-details')));
    expect(details.data, contains('IllegalStateException: boom'));
    expect(details.data, contains('X.kt:1'));
    expect(
        'IllegalStateException: boom'.allMatches(details.data!), hasLength(1),
        reason: '详情第一行和堆栈第一行一样，只留一份');
    expect(details.data, contains('thread: main'));
    await tester.tap(find.byKey(const ValueKey('app-log-copy-one')));
    await tester.pumpAndSettle();
    expect(copied, details.data);
  });

  testWidgets('导出：先预览，复制的就是预览的；里面没有主机名和地址', (tester) async {
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
    await tester.tap(find.byKey(const ValueKey('app-log-export')));
    await tester.pumpAndSettle();
    final preview = tester
        .widget<SelectableText>(
            find.byKey(const ValueKey('app-log-export-preview')))
        .data!;
    await tester.tap(find.byKey(const ValueKey('app-log-copy')));
    await tester.pumpAndSettle();
    expect(copied, preview);
    expect(preview, contains('App 崩溃（Java 层）'));
    expect(preview, contains('同步失败 ×3'));
    for (final leak in [
      'LABEL-ALPHA',
      'host-alpha',
      '100.64.0.9',
      'decoy-user'
    ]) {
      expect(preview, isNot(contains(leak)), reason: leak);
    }
  });

  testWidgets('清除要确认，确认后日志和连接一起清', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('app-log-clear')));
    await tester.pumpAndSettle();
    expect(find.textContaining('备份 2 条和连接 1 条'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('app-log-clear-confirm')));
    await tester.pumpAndSettle();
    expect(container.read(appLogProvider), isEmpty);
    expect(container.read(connectionEventLogProvider), isEmpty);
    expect(find.text('还没有记录'), findsOneWidget);
  });
}
