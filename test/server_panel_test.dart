import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:shun/presentation/widgets/system_management/process_manager_panel.dart';
import 'package:shun/presentation/widgets/system_management/server_overview_panel.dart';
import 'package:shun/presentation/widgets/system_management/server_panel_sheet.dart';
import 'package:shun/presentation/widgets/system_management/service_manager_panel.dart';
import 'package:shun/presentation/widgets/system_management/tmux_manager_panel.dart';

// R68 / MON01：性能监控和系统管理合成一个面板。这里用的是断开的标签：不碰网络，只看面板怎么排、怎么切。
// 真的 SSH 上每页干活的测试还是原来那些（各 manager panel 的测试），面板本身没改。

void main() {
  ActiveTerminalSession tab() => ActiveTerminalSession(
        id: 'tab',
        host: HostProfile({
          'id': 'host',
          'label': 'nas',
          'hostname': 'example.invalid',
          'username': 'demo',
        }),
        terminal: GhosttyTerminalAdapter(),
        verifyHostKey: (_, __, ___) async => true,
        keyboardInteractive: null,
      )..connected = false;

  Future<void> open(WidgetTester tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    // 同 terminal_connection_banner_test：让 flterm 的空闲任务不等动画。
    final strategy = tester.binding.schedulingStrategy;
    tester.binding.schedulingStrategy =
        ({required int priority, required SchedulerBinding scheduler}) => true;
    addTearDown(() => tester.binding.schedulingStrategy = strategy);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ServerPanelSheet(
            session: tab(),
            snippets: const [],
            onOpenTerminal: (_, __) async {},
            onOpenSftp: (_) {},
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  /// 面板里 tab 在屏幕上从左到右的文字。
  List<String> tabTitles(WidgetTester tester) => [
        for (final tab in tester.widgetList<Tab>(find.byType(Tab))) tab.text!,
      ];

  Future<void> settlePage(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('tab 按所有者说的顺序排，打开在概览', (tester) async {
    await open(tester);
    expect(tabTitles(tester), ['概览', '进程', 'tmux', 'Docker', '服务', 'Caddy']);
    expect(find.byType(ServerOverviewPanel), findsOneWidget);
    final bar = tester.widget<TabBar>(
      find.byKey(const ValueKey('server-panel-tabs')),
    );
    expect(bar.isScrollable, isTrue, reason: 'tab 多了 tab 条自己能滑');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('点 tab 能切，左右滑也能切；刷新键只在概览上', (tester) async {
    await open(tester);
    final refresh = find.byKey(const ValueKey('server-panel-refresh'));
    expect(refresh, findsOneWidget);

    await tester.tap(find.text('tmux'));
    await settlePage(tester);
    expect(find.byType(TmuxManagerPanel), findsOneWidget);
    expect(refresh, findsNothing);

    // 往左滑到下一页 Docker，再滑到服务。
    // Docker 页里还有一层 tab：它只能点，不抢横滑，不然滑到 Docker 就滑不走了。
    final pages = find.byType(TabBarView).first;
    final size = tester.getSize(pages);
    for (var i = 0; i < 2; i++) {
      await tester.drag(pages, Offset(-size.width * .8, 0));
      await settlePage(tester);
    }
    expect(find.byType(ServiceManagerPanel), findsOneWidget);

    // 滑回去一直到概览，刷新键回来。
    for (var i = 0; i < 4; i++) {
      await tester.drag(pages, Offset(size.width * .8, 0));
      await settlePage(tester);
    }
    expect(find.byType(ServerOverviewPanel), findsOneWidget);
    expect(refresh, findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('断开时：概览不变灰，管理页整页点不动', (tester) async {
    await open(tester);
    expect(find.text('读取不到系统信息'), findsOneWidget, reason: '不再读了就别写正在读');
    expect(find.text('正在读取系统信息…'), findsNothing);
    expect(
      tester
          .widgetList<AbsorbPointer>(find.ancestor(
            of: find.byType(ServerOverviewPanel),
            matching: find.byType(AbsorbPointer),
          ))
          .where((pointer) => pointer.absorbing),
      isEmpty,
    );
    await tester.tap(find.text('进程'));
    await settlePage(tester);
    final absorb = tester.widget<AbsorbPointer>(
      find
          .ancestor(
            of: find.byType(ProcessManagerPanel),
            matching: find.byType(AbsorbPointer),
          )
          .first,
    );
    expect(absorb.absorbing, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  // 断了才点开的页：不会再读，转圈就是骗人。真 SSH 上断线后才看到（MON01）。
  for (final name in ['进程', 'tmux', 'Docker', '服务', 'Caddy']) {
    testWidgets('断开后才打开「$name」页：不一直转', (tester) async {
      await open(tester);
      await tester.tap(find.text(name));
      await settlePage(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is ProgressIndicator && widget.value == null,
        ),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
    });
  }
}
