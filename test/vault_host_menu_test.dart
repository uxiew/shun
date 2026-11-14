import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/connection_events.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/screens/app_log_screen.dart';
import 'package:shun/presentation/screens/vault_screen.dart';
import 'support/prism_test_host.dart';

// R43：主机列表的 ⋮ 菜单只列这台能用的动作；隐藏只管列表显示、找得回来。
// 换方式连、挂在连着的 SSH 上的几项在 connection_switch_test.dart 的「主机菜单（R43）」组。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  Future<void> open(WidgetTester tester, List<Map<String, Object?>> hosts,
      {String view = 'list', List<ConnectionEvent> events = const []}) async {
    const channel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    SharedPreferences.setMockInitialValues({
      'shun_vault_v1': jsonEncode({
        'hosts': hosts,
        'keys': const [],
        'snippets': const [],
        'customGroups': const [],
      }),
      'shun_settings_v1': jsonEncode({'serverViewMode': view}),
    });
    final repository = await VaultRepository.open();
    container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      connectionEventStoreProvider
          .overrideWithValue(MemoryConnectionEventStore(events)),
    ]);
    addTearDown(container.dispose);
    await container.read(connectionEventLogProvider.notifier).ready;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
          localizationsDelegates: prismTestDelegates,
          builder: prismTestBuilder,
          home: Scaffold(body: VaultScreen())),
    ));
    await tester.pumpAndSettle();
  }

  Map<String, Object?> host(String id, String protocol,
          [Map<String, Object?> extra = const {}]) =>
      {
        'id': id,
        'label': id,
        'hostname': '192.0.2.10',
        'username': 'ops',
        'port': protocol == 'telnet' ? 23 : 22,
        'protocol': protocol,
        ...extra,
      };

  Future<List<String>> menuOf(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(ValueKey('vault-host-menu-$id')));
    await tester.pumpAndSettle();
    final items = [
      for (final element in find
          .byWidgetPredicate((w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('host-menu-'))
          .evaluate())
        (element.widget.key! as ValueKey<String>)
            .value
            .substring('host-menu-'.length),
    ];
    return items;
  }

  testWidgets('类型角标跟着保存的协议走；SSH 是默认的，不压角标', (tester) async {
    await open(tester, [
      host('web', 'ssh'),
      host('roam', 'mosh'),
      host('old', 'telnet'),
    ]);
    expect(find.byKey(const ValueKey('host-type-ssh')), findsNothing);
    expect(find.byKey(const ValueKey('host-type-mosh')), findsOneWidget);
    expect(find.byKey(const ValueKey('host-type-telnet')), findsOneWidget);
  });

  testWidgets('菜单只列这台用得上的：Telnet 只有编辑和隐藏；没连着的 SSH 没有转发、文件、监控', (tester) async {
    await open(tester, [
      host('web', 'ssh'),
      host('old', 'telnet'),
      // 跳板机已经删掉了：路线算不出来，测不了。
      host('broken', 'ssh', {
        'hostChain': {
          'hostIds': ['gone']
        }
      }),
    ]);
    expect(await menuOf(tester, 'old'), ['edit', 'hide']);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    // 测试环境不是 Android，Mosh 插件用不了，所以也没有「用 Mosh 连接」。
    // AI 工具和测试连接同一个条件（R25 接 R57）：普通 SSH、路线算得出来。
    expect(await menuOf(tester, 'web'),
        ['aiCli', 'testConnection', 'edit', 'hide']);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(await menuOf(tester, 'broken'), ['edit', 'hide']);
  });

  testWidgets('R25：有连接记录的主机菜单里才有「连接日志」，点进去是这一台的', (tester) async {
    await open(tester, [
      host('web', 'ssh'),
      host('db', 'ssh'),
    ], events: [
      ConnectionEvent(
        hostId: 'web',
        at: DateTime.now(),
        kind: ConnectionEventKind.open,
        protocol: HostProtocol.ssh,
        outcome: ConnectionOutcome.connected,
        total: const Duration(milliseconds: 12),
      ),
    ]);
    expect(await menuOf(tester, 'web'),
        ['aiCli', 'testConnection', 'connectionLog', 'edit', 'hide']);
    await tester.tap(find.byKey(const ValueKey('host-menu-connectionLog')));
    await tester.pumpAndSettle();
    expect(find.byType(AppLogScreen), findsOneWidget);
    expect(find.textContaining('新开连接 · 连上了'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(
        await menuOf(tester, 'db'), ['aiCli', 'testConnection', 'edit', 'hide'],
        reason: '没有记录的主机不列：点进去只会是空的');
  });

  for (final view in ['list', 'grid', 'tree']) {
    testWidgets('隐藏只管列表：藏起来、连接页不留入口、能撤销（$view）', (tester) async {
      await open(tester, [host('web', 'ssh'), host('db', 'ssh')], view: view);
      expect(await menuOf(tester, 'web'), contains('hide'));
      await tester.tap(find.byKey(const ValueKey('host-menu-hide')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('vault-host-menu-web')), findsNothing);
      expect(find.byKey(const ValueKey('vault-host-menu-db')), findsOneWidget);
      expect(find.byKey(const ValueKey('vault-show-hidden')), findsNothing);
      final saved = container.read(vaultControllerProvider).data!.hosts;
      final web = saved.firstWhere((h) => h.id == 'web');
      expect(web.hidden, isTrue);
      expect(web.hostname, '192.0.2.10', reason: '只改隐藏这一个字段');
      // updatedAt 是保险库每次写主机都会盖的时间戳（同步用），不是隐藏改的。
      expect(
          web.data.keys.toSet().difference(host('web', 'ssh').keys.toSet())
            ..remove('updatedAt'),
          {hiddenHostKey});

      await tester.tap(find.widgetWithText(SnackBarAction, '撤销'));
      await tester.pumpAndSettle();
      expect(
          container
              .read(vaultControllerProvider)
              .data!
              .hosts
              .firstWhere((h) => h.id == 'web')
              .data
              .containsKey(hiddenHostKey),
          isFalse);
      expect(find.byKey(const ValueKey('vault-host-menu-web')), findsOneWidget);
    });
  }

  testWidgets('全都藏了也不说「还没有终端连接」', (tester) async {
    await open(tester, [
      host('web', 'ssh', {hiddenHostKey: true})
    ]);
    expect(find.text('还没有终端连接'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('vault-open-hidden')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('hidden-host-web')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('hidden-restore-web')));
    await tester.pumpAndSettle();
    expect(find.text('没有隐藏的主机'), findsOneWidget);
    expect(
      container
          .read(vaultControllerProvider)
          .data!
          .hosts
          .firstWhere((h) => h.id == 'web')
          .hidden,
      isFalse,
    );
  });

  testWidgets('UXR07：搜分组也搜得到；搜不到不说「还没有」，也不摆新建按钮', (tester) async {
    await open(tester, [
      host('web', 'ssh', {'group': 'prod'}),
      host('db', 'ssh'),
    ]);
    final search = find.byKey(const ValueKey('vault-search'));
    await tester.enterText(search, 'PROD');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('vault-host-menu-web')), findsOneWidget);
    expect(find.byKey(const ValueKey('vault-host-menu-db')), findsNothing);

    await tester.enterText(search, 'nothing-like-this');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的主机'), findsOneWidget);
    expect(find.text('还没有终端连接'), findsNothing);
    expect(find.byKey(const ValueKey('vault-empty-add-host')), findsNothing);
  });

  // 首页的「加载中」：安全存储（密码、私钥）还在读时，主机列表先按本机缓存显示，不等它、
  // 也不说「还没有」。缓存本身读不出来时才只转圈（vault-loading），那条路这里不造。
  testWidgets('UIM08：安全存储还在读：先按缓存列出主机，不说「还没有」，不连接', (tester) async {
    const channel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    final unblock = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      await unblock.future;
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    SharedPreferences.setMockInitialValues({
      'shun_vault_v1': jsonEncode({
        'hosts': [host('web', 'ssh'), host('db', 'ssh')],
        'keys': const [],
        'snippets': const [],
        'customGroups': const [],
      }),
      'shun_settings_v1': jsonEncode({'serverViewMode': 'list'}),
    });
    final repository = await VaultRepository.open();
    container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
          localizationsDelegates: prismTestDelegates,
          builder: prismTestBuilder,
          home: Scaffold(body: VaultScreen())),
    ));
    await tester.pump();
    expect(container.read(vaultControllerProvider).loading, isTrue);
    expect(find.byKey(const ValueKey('vault-host-menu-web')), findsOneWidget);
    expect(find.byKey(const ValueKey('vault-host-menu-db')), findsOneWidget);
    expect(find.byKey(const ValueKey('vault-loading')), findsNothing);
    expect(find.text('还没有终端连接'), findsNothing);
    expect(
        container.read(sessionControllerProvider).pendingConnections, isEmpty);

    unblock.complete();
    await tester.pumpAndSettle();
    expect(container.read(vaultControllerProvider).loading, isFalse);
    expect(find.byKey(const ValueKey('vault-host-menu-web')), findsOneWidget);
    expect(container.read(sessionControllerProvider).sessions, isEmpty);
  });
}
