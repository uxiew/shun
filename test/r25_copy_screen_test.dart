import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:shun/presentation/widgets/terminal_special_keys.dart';

import 'support/test_terminal.dart';

// R25：整屏快照从终端右上角的浮动按钮挪到标签条（terminal_connection_dialog_test 里测）和「更多」。
// 标签条在收成一行（横屏、小屏弹着键盘）时不显示，那时只能从「更多」里点到。

Widget _keys({
  required bool compact,
  required VoidCallback onCopyScreen,
  required GhosttyTerminalAdapter terminal,
  bool fullscreen = false,
  VoidCallback? onPerformanceMonitor,
}) =>
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: TerminalSpecialKeys(
              order: const ['ESC'],
              customKeys: const [],
              onSend: (text, {bool enter = false}) {},
              onKey: (_) {},
              inputController: terminal.input,
              onAi: null,
              onCopyScreen: onCopyScreen,
              onPerformanceMonitor: onPerformanceMonitor,
              onPortForward: () {},
              pictureInPicture: false,
              onPictureInPicture: () {},
              fullscreen: fullscreen,
              onFullscreen: () {},
              split: false,
              onSplit: () {},
              compact: compact,
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('收成一行时「更多」里有「复制屏幕文字」，点了就弹快照', (tester) async {
    final terminal = newTestTerminal();
    addTearDown(terminal.dispose);
    var copies = 0;
    await tester.pumpWidget(
      _keys(compact: true, onCopyScreen: () => copies++, terminal: terminal),
    );

    await tester.tap(find.byKey(const ValueKey('terminal-action-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('terminal-action-copy-screen')));
    await tester.pumpAndSettle();

    expect(copies, 1);
  });

  testWidgets('平时的操作按钮那一行不多出按钮：分屏、全屏还在原处', (tester) async {
    tester.view.physicalSize = const Size(412, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final terminal = newTestTerminal();
    addTearDown(terminal.dispose);
    await tester.pumpWidget(
      _keys(compact: false, onCopyScreen: () {}, terminal: terminal),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('terminal-action-copy-screen')),
        findsNothing);
    expect(find.byKey(const ValueKey('terminal-action-split')), findsOneWidget);
    expect(find.byKey(const ValueKey('terminal-action-fullscreen')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('terminal-action-more')), findsNothing,
        reason: '不全屏时这两项在标签条上');
  });

  // 全屏时标签条藏起来：以前性能监控浮在终端右上角盖字，不是 SSH 的标签（没有 AI 工具按钮）连「更多」都没有。
  testWidgets('全屏：「更多」一定在，里面有复制屏幕和性能监控；按钮不挤到 48dp 以下', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final terminal = newTestTerminal();
    addTearDown(terminal.dispose);
    var monitors = 0;
    await tester.pumpWidget(_keys(
      compact: false,
      fullscreen: true,
      onCopyScreen: () {},
      onPerformanceMonitor: () => monitors++,
      terminal: terminal,
    ));
    await tester.pumpAndSettle();

    final more = find.byKey(const ValueKey('terminal-action-more'));
    expect(more, findsOneWidget);
    for (final element in find
        .descendant(
            of: find.byKey(const ValueKey('terminal-special-keys-surface')),
            matching: find.byType(IconButton))
        .evaluate()) {
      expect(tester.getSize(find.byWidget(element.widget)).width,
          greaterThanOrEqualTo(48));
    }
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('terminal-action-copy-screen')),
        findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey('terminal-action-performance-monitor')));
    await tester.pumpAndSettle();
    expect(monitors, 1);
  });

  testWidgets('不是连着的 SSH（没给性能监控）：「更多」里没有这一项', (tester) async {
    final terminal = newTestTerminal();
    addTearDown(terminal.dispose);
    await tester.pumpWidget(
        _keys(compact: true, onCopyScreen: () {}, terminal: terminal));
    await tester.tap(find.byKey(const ValueKey('terminal-action-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('terminal-action-performance-monitor')),
        findsNothing);
  });
}
