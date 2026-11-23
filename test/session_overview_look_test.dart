import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';
import 'package:shun/presentation/ui/prism_theme.dart';
import 'package:shun/presentation/ui/shun_ui_host.dart';
import 'package:shun/presentation/widgets/session_overview.dart';

import 'support/prism_test_host.dart';
import 'support/test_terminal.dart';

// FL-10（R95）：会话总览换成 FlClash 那套样子后的外观约定。分组、切换、关闭、重连和两指手势
// 的逻辑在 session_overview_test.dart，这里只管样子：层次靠底色、主色只标当前的、角是超椭圆、
// 点按区不缩水。
//
// 设了 SHUN_FL10_RENDERS=<绝对路径目录> 再跑，还会把各种状态的总览各出一张图（深、浅两套）。
// 出图的用例只认 key，不认样子：在改样子之前的代码上跑同一个文件，出来的就是「改之前」。
const _fontPath = '/System/Library/Fonts/Supplemental/Arial Unicode.ttf';
const _monoFontPath = '/System/Library/Fonts/Supplemental/Courier New.ttf';
const _shot = ValueKey('fl10-shot');

void main() {
  HostProfile host(String id, String label) => HostProfile({
        'id': id,
        'label': label,
        'hostname': '192.0.2.1',
        'username': 'demo',
        'protocol': 'ssh',
      });

  final opened = <ActiveTerminalSession>[];

  ActiveTerminalSession tab(
    String id,
    HostProfile host, {
    bool connected = true,
    String? output,
  }) {
    final terminal = newTestTerminal();
    if (output != null) terminal.feed(utf8.encode(output));
    final session = ActiveTerminalSession(
      id: id,
      host: host,
      terminal: terminal,
      verifyHostKey: (_, __, ___) async => true,
      keyboardInteractive: null,
    )..connected = connected;
    opened.add(session);
    return session;
  }

  Future<ProviderContainer> container(
    WidgetTester tester,
    SessionState state,
    Size size,
  ) async {
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    SharedPreferences.setMockInitialValues({});
    final strategy = tester.binding.schedulingStrategy;
    tester.binding.schedulingStrategy =
        ({required int priority, required SchedulerBinding scheduler}) => true;
    addTearDown(() => tester.binding.schedulingStrategy = strategy);
    final repository = await VaultRepository.open();
    final result = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      sessionControllerProvider.overrideWith(
        (ref) => _Seeded(
          ref.read(vaultControllerProvider.notifier),
          ref,
          state,
        ),
      ),
    ]);
    addTearDown(result.dispose);
    await result.read(vaultControllerProvider.notifier).ready();
    return result;
  }

  /// 和 HomeShell 里一样：总览贴在底下，上面露着页面。
  Widget sheet() => Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: SessionOverview(onClose: () {}),
        ),
      );

  Future<void> open(
    WidgetTester tester,
    SessionState state, {
    Size size = const Size(412, 892),
    double textScale = 1,
  }) async {
    final scope = await container(tester, state, size);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: scope,
      child: MaterialApp(
        localizationsDelegates: prismTestDelegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: prismTestBuilder(context, child),
        ),
        home: sheet(),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 拆掉页面、停掉会话，不留定时器。
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    for (final session in opened) {
      session.abort();
    }
    opened.clear();
  }

  prism.PressSurface surfaceOf(WidgetTester tester, String key) =>
      tester.widget<prism.PressSurface>(find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(prism.PressSurface),
      ));

  testWidgets('层次靠底色：没有 Material 的 Card、TabBar，面板顶上是超椭圆角', (tester) async {
    final alpha = host('a', 'alpha');
    await open(
      tester,
      SessionState(sessions: [tab('s0', alpha), tab('s1', alpha)]),
    );
    final overview = find.byType(SessionOverview);
    for (final type in [Card, TabBar, Divider]) {
      expect(
        find.descendant(of: overview, matching: find.byType(type)),
        findsNothing,
        reason: '$type',
      );
    }
    final panel = tester.widget<Material>(
      find.byKey(const ValueKey('session-overview')),
    );
    expect(panel.shape, isA<RoundedSuperellipseBorder>());
    for (final key in ['overview-window-s0', 'overview-machine-a']) {
      final surface = surfaceOf(tester, key);
      expect(surface.shape, isA<RoundedSuperellipseBorder>(), reason: key);
      expect(surface.side, BorderSide.none, reason: '$key 不描边');
    }
    await finish(tester);
  });

  testWidgets('主色只标当前的：选中的机器整颗是主色，当前的卡片带一层主色、别的卡片是中性底', (tester) async {
    final alpha = host('a', 'alpha');
    final beta = host('b', 'beta');
    await open(
      tester,
      SessionState(
        sessions: [tab('s0', alpha), tab('s1', alpha), tab('s2', beta)],
        activeIndex: 1,
      ),
    );
    final colors = prism.Theme.of(
      tester.element(find.byKey(const ValueKey('session-overview'))),
    ).colorScheme;

    final machine = surfaceOf(tester, 'overview-machine-a');
    final other = surfaceOf(tester, 'overview-machine-b');
    expect(machine.selected, isTrue);
    expect(machine.fill, colors.primary);
    expect(other.selected, isFalse);
    expect(other.fill, isNot(colors.primary));

    final current = surfaceOf(tester, 'overview-window-s1');
    final rest = surfaceOf(tester, 'overview-window-s0');
    expect(current.selected, isTrue);
    expect(rest.selected, isFalse);
    expect(current.fill, isNot(rest.fill), reason: '当前那张要分得出来');
    expect(current.fill, isNot(colors.primary), reason: '状态点还要看得清，不整张涂满');
    expect(
      tester.getSemantics(find.descendant(
        of: find.byKey(const ValueKey('overview-window-s1')),
        matching: find.byType(prism.PressSurface),
      )),
      isSemantics(isButton: true, isSelected: true),
      reason: '读屏也要知道哪张是当前的',
    );
    await finish(tester);
  });

  testWidgets('× 的点按区都是 48dp：面板的、机器胶囊上的、卡片上的', (tester) async {
    final alpha = host('a', 'alpha');
    await open(
      tester,
      SessionState(sessions: [tab('s0', alpha), tab('s1', alpha)]),
    );
    for (final key in [
      'overview-close',
      'overview-close-machine-a',
      'overview-close-s0',
    ]) {
      final size = tester.getSize(find.byKey(ValueKey(key)));
      expect(size.width, greaterThanOrEqualTo(48), reason: key);
      expect(size.height, greaterThanOrEqualTo(48), reason: key);
    }
    // 胶囊看着比点按区矮：× 叠在它右端，不把它撑高。
    final chip = tester.getSize(find.descendant(
      of: find.byKey(const ValueKey('overview-machine-a')),
      matching: find.byType(prism.PressSurface),
    ));
    expect(chip.height, lessThan(48));
    await finish(tester);
  });

  testWidgets('机器多到一行放不下：开着时当前那台在屏幕里，点别的机器换到它的卡片', (tester) async {
    final hosts = [for (var i = 0; i < 8; i++) host('h$i', 'machine-$i')];
    await open(
      tester,
      SessionState(
        sessions: [for (final (i, value) in hosts.indexed) tab('s$i', value)],
        activeIndex: 7,
      ),
    );
    await tester.pumpAndSettle();
    final screen = tester.getSize(find.byType(Scaffold));
    final chip =
        tester.getRect(find.byKey(const ValueKey('overview-machine-h7')));
    expect(chip.left, greaterThanOrEqualTo(0));
    expect(chip.right, lessThanOrEqualTo(screen.width));
    expect(find.byKey(const ValueKey('overview-pager-h7')), findsOneWidget);

    await tester.tap(find.text('machine-6'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('overview-pager-h6')), findsOneWidget);
    expect(surfaceOf(tester, 'overview-machine-h6').selected, isTrue);
    expect(surfaceOf(tester, 'overview-machine-h7').selected, isFalse);
    await finish(tester);
  });

  testWidgets('字号放大到 2 倍：断开、恢复中、连接中、失败的卡片都不溢出', (tester) async {
    final alpha = host('a', 'alpha');
    await open(
      tester,
      SessionState(
        sessions: [
          tab('down', alpha, connected: false),
          tab('r', alpha, connected: false),
        ],
        recovering: const {'r'},
        pendingConnections: [
          PendingTerminalConnection(id: 'p1', host: alpha),
          PendingTerminalConnection(
            id: 'p2',
            host: alpha,
            phase: PendingConnectionPhase.failed,
            error: 'boom',
          ),
        ],
      ),
      size: const Size(840, 892),
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
    expect(
        find.byKey(const ValueKey('overview-reconnect-down')), findsOneWidget);
    await finish(tester);
  });

  // ---- 出图 ----
  final dir = Platform.environment['SHUN_FL10_RENDERS'];
  final skip = dir == null
      ? '设了 SHUN_FL10_RENDERS 才出图'
      : ([_fontPath, _monoFontPath].every((path) => File(path).existsSync())
          ? null
          : '没有出图所需的字体');

  Future<void> loadFonts(WidgetTester tester) => tester.runAsync(() async {
        Future<void> load(String family, String path) async {
          final loader = FontLoader(family)
            ..addFont(File(path)
                .readAsBytes()
                .then((bytes) => ByteData.sublistView(bytes)));
          await loader.load();
        }

        await load('Roboto', _fontPath);
        await load('monospace', _monoFontPath);
        await load(
          'MaterialIcons',
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/'
              'material_fonts/MaterialIcons-Regular.otf',
        );
      });

  for (final brightness in Brightness.values) {
    final suffix = brightness == Brightness.light ? '-light' : '';

    Future<void> render(
      WidgetTester tester,
      String name,
      SessionState state, {
      Size size = const Size(412, 420),
      double textScale = 1,
    }) async {
      await loadFonts(tester);
      final language = ShunLocalizations.language;
      ShunLocalizations.use('zh-CN');
      addTearDown(() => ShunLocalizations.use(language));
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final scope = await container(tester, state, size);
      final id = brightness == Brightness.dark ? 'midnight' : 'snow';
      await tester.pumpWidget(RepaintBoundary(
        key: _shot,
        child: UncontrolledProviderScope(
          container: scope,
          child: ShunUiHost(
            navigatorKey: GlobalKey<NavigatorState>(),
            theme: ShunUiTheme.resolve(Brightness.light, id),
            darkTheme: ShunUiTheme.resolve(Brightness.dark, id),
            themeMode: brightness == Brightness.dark
                ? ThemeMode.dark
                : ThemeMode.light,
            locale: const Locale('zh', 'CN'),
            home: sheet(),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull, reason: '出图前不能有未处理异常');
      final boundary =
          tester.renderObject<RenderRepaintBoundary>(find.byKey(_shot));
      await tester.runAsync(() async {
        await Directory(dir!).create(recursive: true);
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await File('$dir/$name$suffix.png')
            .writeAsBytes(data!.buffer.asUint8List());
      });
      await finish(tester);
    }

    group('出图 ${brightness.name}', () {
      testWidgets('各种状态：当前、断开、恢复中、连接中、失败', skip: skip != null, (tester) async {
        final alpha = host('a', '示例 Web');
        final beta = host('b', '后台任务');
        await render(
          tester,
          'fl10-overview-states-840x420-zh-s1',
          SessionState(
            sessions: [
              tab('up', alpha, output: 'demo@web:~\$ ls\r\nsrc/  docs/\r\n'),
              tab('down', alpha, connected: false, output: 'Connection lost'),
              tab('r', alpha, connected: false),
              tab('other', beta),
            ],
            recovering: const {'r'},
            pendingConnections: [
              PendingTerminalConnection(id: 'p1', host: alpha),
              PendingTerminalConnection(
                id: 'p2',
                host: alpha,
                phase: PendingConnectionPhase.failed,
                error: 'boom',
              ),
            ],
          ),
          size: const Size(840, 420),
        );
      });

      testWidgets('断开两个：卡片上「重新连接」，顶上「全部重连」', skip: skip != null,
          (tester) async {
        final alpha = host('a', '示例 Web');
        await render(
          tester,
          'fl10-overview-reconnect-412x420-zh-s1',
          SessionState(sessions: [
            tab('d1', alpha, connected: false, output: 'Connection lost'),
            tab('d2', alpha, connected: false),
          ]),
        );
      });

      testWidgets('没有会话', skip: skip != null, (tester) async {
        await render(
          tester,
          'fl10-overview-empty-412x420-zh-s1',
          const SessionState(),
        );
      });

      testWidgets('机器多：当前那台滚进来', skip: skip != null, (tester) async {
        final hosts = [for (var i = 0; i < 6; i++) host('h$i', '机器 ${i + 1}')];
        await render(
          tester,
          'fl10-overview-machines-412x420-zh-s1',
          SessionState(
            sessions: [
              for (final (i, value) in hosts.indexed) tab('s$i', value),
            ],
            activeIndex: 4,
          ),
        );
      });

      testWidgets('字号 1.5 倍', skip: skip != null, (tester) async {
        final alpha = host('a', '示例 Web');
        await render(
          tester,
          'fl10-overview-states-412x420-zh-s1.5',
          SessionState(sessions: [
            tab('up', alpha, output: 'demo@web:~\$ ls\r\nsrc/  docs/\r\n'),
            tab('down', alpha, connected: false),
          ]),
          textScale: 1.5,
        );
      });
    });
  }
}

class _Seeded extends SessionController {
  _Seeded(VaultController vaultController, Ref ref, SessionState initial)
      : super(SshService(), vaultController, ref) {
    state = initial;
  }
}
