import 'dart:convert';

import 'package:flterm/flterm.dart' as flterm show TerminalView;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/prism_ui.dart' as p;
import 'package:shun/application/app_lock.dart';
import 'package:shun/domain/models/settings.dart';
import 'package:shun/infrastructure/device_auth.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:shun/presentation/terminal/ghostty_terminal_view.dart';
import 'package:shun/presentation/terminal/terminal_view.dart';
import 'package:shun/presentation/ui/material_compat.dart';
import 'package:shun/presentation/ui/prism_theme.dart';
import 'package:shun/presentation/ui/shun_ui_host.dart';

// 后台标签的终端还没显示过时，远端问背景色（OSC 11）要按 App 现在的主题回答（10-25 修）。
// 以前一律回 flterm 默认的深色（1d1f21），浅色界面下后台开的 vim 会按深色配色画。
// R83 起主题是同一个语义主题生成的 Prism/Material 两种表示，终端读其中 Material 的 surface。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late GlobalKey<NavigatorState> navigatorKey;
  setUp(() {
    navigatorKey = GlobalKey<NavigatorState>();
    container = ProviderContainer(overrides: [
      appLockControllerProvider.overrideWith((ref) => AppLockController(
            auth: _NoDeviceAuth(),
            settings: const AppSettings(),
            hasConnectedTerminal: () => false,
          )),
    ]);
  });
  tearDown(() => container.dispose());

  final light = ShunUiTheme.resolve(Brightness.light, 'tokyo-night');
  final dark = ShunUiTheme.resolve(Brightness.dark, 'tokyo-night');
  Color surfaceOf(ShunUiTheme theme) =>
      materialThemeFor(theme).colorScheme.surface;

  String answer(Color color) {
    String channel(double v) {
      final hex = (v * 255).round().toRadixString(16).padLeft(2, '0');
      return '$hex$hex';
    }

    final rgb = [color.r, color.g, color.b].map(channel).join('/');
    return '\x1b]11;rgb:$rgb\x07';
  }

  String askBackground(GhosttyTerminalAdapter terminal) {
    final sent = <String>[];
    final binding = terminal.bind((bytes) => sent.add(latin1.decode(bytes)));
    terminal.feed(Uint8List.fromList(utf8.encode('\x1b]11;?\x07')));
    binding.release();
    return sent.join();
  }

  Widget app(
    ThemeMode mode, {
    Widget home = const SizedBox(),
    ShunUiTheme? lightTheme,
    ShunUiTheme? darkTheme,
  }) =>
      UncontrolledProviderScope(
        container: container,
        child: ShunUiHost(
          navigatorKey: navigatorKey,
          theme: lightTheme ?? light,
          darkTheme: darkTheme ?? dark,
          themeMode: mode,
          locale: const Locale('zh', 'CN'),
          home: home,
        ),
      );

  testWidgets('浅色主题下新建的终端回浅色背景；换成深色主题，没显示过的终端跟着换', (tester) async {
    await tester.pumpWidget(app(ThemeMode.light));
    final terminal = GhosttyTerminalAdapter();
    addTearDown(terminal.dispose);
    final navigator = navigatorKey.currentState;
    expect(askBackground(terminal), answer(surfaceOf(light)));

    await tester.pumpWidget(app(ThemeMode.dark));
    await tester.pumpAndSettle();
    expect(askBackground(terminal), answer(surfaceOf(dark)));
    expect(navigatorKey.currentState, same(navigator));
  });

  // R20 TER12 10-25 复跑撞出来的：配色以前在 App 最外层当场算，算要调 libghostty，
  // 原生库加载不了时整个 App 起不来。现在有终端要上色时才算。
  testWidgets('没有终端时不算配色，建第一个终端时才算、只算一次', (tester) async {
    var computed = 0;
    final scheme = materialThemeFor(light).colorScheme;
    GhosttyTerminalAdapter.useDetachedTheme(() {
      computed++;
      return terminalColorsFor(scheme);
    });
    expect(computed, 0);
    final first = GhosttyTerminalAdapter();
    addTearDown(first.dispose);
    final second = GhosttyTerminalAdapter();
    addTearDown(second.dispose);
    expect(computed, 1);
    expect(askBackground(second), answer(scheme.surface));
  });

  testWidgets('关掉的终端不再被推主题，换主题不出错', (tester) async {
    await tester.pumpWidget(app(ThemeMode.light));
    GhosttyTerminalAdapter().dispose();
    await tester.pumpWidget(app(ThemeMode.dark));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  // UIM04：同一时刻一个终端挂着视图、一个在后台，按浅→深→系统（系统浅/深）→浅切换。
  // 两个终端的回答每一步都要等于当前 Material surface，也就是 Prism 同一个角色；视图和焦点不重建。
  testWidgets('已显示和未显示的终端在浅/深/系统切换后回答同一底色，视图不重建', (tester) async {
    _allowIdleTasks(tester);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final shown = GhosttyTerminalAdapter();
    final hidden = GhosttyTerminalAdapter();
    addTearDown(shown.dispose);
    addTearDown(hidden.dispose);
    final home = Scaffold(
      body: GhosttyTerminalView(
        adapter: shown,
        options: const TerminalViewOptions(
          fontSize: 14,
          secureKeyboard: false,
          interactive: true,
          transparentBackground: false,
          softKeyboard: false,
        ),
      ),
    );
    await tester.pumpWidget(app(ThemeMode.light, home: home));
    await _frames(tester);
    final view = tester.state(find.byType(GhosttyTerminalView));
    final engine = tester.state(find.byType(flterm.TerminalView));
    final input = tester
        .widget<flterm.TerminalView>(
          find.byType(flterm.TerminalView),
        )
        .focusNode!;
    expect(shown.hasEngineView, isTrue);
    expect(hidden.hasActiveView, isFalse);
    expect(input.hasFocus, isTrue);

    final steps = <(ThemeMode, Brightness, ShunUiTheme)>[
      (ThemeMode.light, Brightness.dark, light),
      (ThemeMode.dark, Brightness.light, dark),
      (ThemeMode.system, Brightness.light, light),
      (ThemeMode.system, Brightness.dark, dark),
      (ThemeMode.light, Brightness.dark, light),
    ];
    for (final (mode, platform, expected) in steps) {
      tester.platformDispatcher.platformBrightnessTestValue = platform;
      await tester.pumpWidget(app(mode, home: home));
      await _frames(tester);
      final context = tester.element(find.byType(GhosttyTerminalView));
      final surface = surfaceOf(expected);
      expect(Theme.of(context).colorScheme.surface, surface,
          reason: '$mode / 系统 $platform');
      expect(p.Theme.of(context).colorScheme.surface, surface);
      expect(askBackground(shown), answer(surface), reason: '挂着视图的终端按视图主题回答');
      expect(askBackground(hidden), answer(surface),
          reason: '后台终端按 GhosttyDetachedThemeSync 推的主题回答');
      expect(tester.state(find.byType(GhosttyTerminalView)), same(view));
      expect(tester.state(find.byType(flterm.TerminalView)), same(engine));
      expect(input.hasFocus, isTrue);
    }
    // 浅深两套底色确实不同，上面的相等不是碰巧。
    expect(surfaceOf(light), isNot(surfaceOf(dark)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('认不出的旧 uiThemeId 落回 snow/midnight，后台终端跟着落回后的底色', (tester) async {
    final unknownLight = ShunUiTheme.resolve(Brightness.light, 'no-such-theme');
    final unknownDark = ShunUiTheme.resolve(Brightness.dark, 'no-such-theme');
    expect(unknownLight.preset.id, 'snow');
    expect(unknownDark.preset.id, 'midnight');
    final terminal = GhosttyTerminalAdapter();
    addTearDown(terminal.dispose);
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      await tester.pumpWidget(app(
        mode,
        lightTheme: unknownLight,
        darkTheme: unknownDark,
      ));
      await tester.pumpAndSettle();
      expect(
        askBackground(terminal),
        answer(surfaceOf(mode == ThemeMode.light ? unknownLight : unknownDark)),
      );
    }
  });
}

Future<void> _frames(WidgetTester tester) async {
  // 终端光标有自己的时钟，不用 pumpAndSettle 等它停下。
  for (var frame = 0; frame < 5; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void _allowIdleTasks(WidgetTester tester) {
  final strategy = tester.binding.schedulingStrategy;
  tester.binding.schedulingStrategy =
      ({required int priority, required SchedulerBinding scheduler}) => true;
  addTearDown(() => tester.binding.schedulingStrategy = strategy);
}

class _NoDeviceAuth implements DeviceAuth {
  @override
  set onActivityPaused(void Function(bool ownActivity)? callback) {}

  @override
  Future<bool> isDeviceSecure() async => false;

  @override
  Future<DeviceAuthOutcome> authenticate({
    required String title,
    String? description,
    required bool pinOnly,
    required bool allowWeak,
  }) async =>
      const DeviceAuthOutcome(DeviceAuthResult.unavailable);

  @override
  Future<void> setProtectRecents(bool enabled) async {}
}
