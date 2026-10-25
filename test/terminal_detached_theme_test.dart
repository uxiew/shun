import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:shun/presentation/terminal/ghostty_terminal_view.dart';

// 后台标签的终端还没显示过时，远端问背景色（OSC 11）要按 App 现在的主题回答（10-25 修）。
// 以前一律回 flterm 默认的深色（1d1f21），浅色界面下后台开的 vim 会按深色配色画。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final light = ThemeData(
      colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal, brightness: Brightness.light));
  final dark = ThemeData(
      colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal, brightness: Brightness.dark));

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

  Widget app(ThemeMode mode) => MaterialApp(
        theme: light,
        darkTheme: dark,
        themeMode: mode,
        builder: (context, child) => GhosttyDetachedThemeSync(child: child!),
        home: const SizedBox(),
      );

  testWidgets('浅色主题下新建的终端回浅色背景；换成深色主题，没显示过的终端跟着换',
      (tester) async {
    await tester.pumpWidget(app(ThemeMode.light));
    final terminal = GhosttyTerminalAdapter();
    addTearDown(terminal.dispose);
    expect(askBackground(terminal), answer(light.colorScheme.surface));

    await tester.pumpWidget(app(ThemeMode.dark));
    await tester.pumpAndSettle();
    expect(askBackground(terminal), answer(dark.colorScheme.surface));
  });

  testWidgets('关掉的终端不再被推主题，换主题不出错', (tester) async {
    await tester.pumpWidget(app(ThemeMode.light));
    GhosttyTerminalAdapter().dispose();
    await tester.pumpWidget(app(ThemeMode.dark));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
