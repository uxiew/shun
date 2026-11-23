import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:shun/presentation/widgets/terminal_key_button.dart';
import 'package:shun/presentation/widgets/terminal_keys.dart';

/// 终端输入这一批（R94）的外观约定。只查外观：按键发什么、发给谁在
/// terminal_input_panel_test、terminal_input_routing_test 里。
void main() {
  // 这一批的文件。描边、Material 的圆角矩形和分隔线换成了底色层级和 Prism 的超椭圆，别再写回来。
  const files = [
    'lib/presentation/screens/terminal_screen_input.dart',
    'lib/presentation/widgets/terminal_input_panel.dart',
    'lib/presentation/widgets/terminal_special_keys.dart',
    'lib/presentation/widgets/terminal_keys.dart',
    'lib/presentation/widgets/terminal_key_button.dart',
    'lib/presentation/widgets/terminal_compose_box.dart',
    'lib/presentation/widgets/terminal_paste_sheet.dart',
    'lib/presentation/widgets/terminal_link_sheet.dart',
    'lib/presentation/widgets/terminal_key_settings_sheet.dart',
    'lib/presentation/widgets/terminal_key_feel_tiles.dart',
  ];

  test('这一批的文件里没有描边按钮、Material 圆角矩形、胶囊边和分隔线', () {
    final banned = RegExp(
      r'OutlinedButton|RoundedRectangleBorder|StadiumBorder|'
      r'BorderRadius\.circular|Border\.all|\bDivider\(',
    );
    for (final path in files) {
      final lines = File(path).readAsLinesSync();
      for (final (index, line) in lines.indexed) {
        expect(banned.hasMatch(line), isFalse,
            reason: '$path:${index + 1} ${line.trim()}');
      }
    }
  });

  group('键帽', () {
    Future<void> pumpKeys(
      WidgetTester tester, {
      required bool ctrlLit,
      double cell = 49,
    }) =>
        tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: cell * 2,
                height: 48,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final spec in [ctrlKey, tabKey])
                      Expanded(
                        child: TerminalKeyButton(
                          key: ValueKey(spec.label),
                          spec: spec,
                          selected: ctrlLit && spec == ctrlKey,
                          onPressed: (_) {},
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ));

    Finder capOf(String label) => find.descendant(
          of: find.byKey(ValueKey(label)),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is DecoratedBox && widget.decoration is ShapeDecoration,
          ),
        );

    ShapeDecoration decorationOf(WidgetTester tester, String label) =>
        tester.widget<DecoratedBox>(capOf(label)).decoration as ShapeDecoration;

    testWidgets('360dp 宽的手机上（一格 49dp）：点按范围是整个格子，相邻的键帽不连成一片', (tester) async {
      await pumpKeys(tester, ctrlLit: false);
      final ctrlTarget = tester.getRect(find.descendant(
        of: find.byKey(const ValueKey('Ctrl')),
        matching: find.byType(TextButton),
      ));
      expect(ctrlTarget.size, const Size(49, 48), reason: '点按范围没有跟着键帽缩小（UX02）');
      final ctrlCap = tester.getRect(capOf('Ctrl'));
      final tabCap = tester.getRect(capOf('Tab'));
      expect(tabCap.left - ctrlCap.right, greaterThanOrEqualTo(4));
      expect(ctrlTarget.deflate(2), ctrlCap);
    });

    testWidgets('键帽比所在表面高一层、是超椭圆；亮着的修饰键是主色', (tester) async {
      await pumpKeys(tester, ctrlLit: true);
      final colors =
          prism.Theme.of(tester.element(find.byType(Scaffold))).colorScheme;
      final lit = decorationOf(tester, 'Ctrl');
      final plain = decorationOf(tester, 'Tab');
      expect(lit.color, colors.primary);
      expect(plain.color, prism.SurfaceLevel.card.colorOf(colors));
      expect(plain.shape, prism.AppShape.sm);
      expect(lit.shape, prism.AppShape.sm);
      final label = tester.widget<RichText>(find.descendant(
        of: find.byKey(const ValueKey('Ctrl')),
        matching: find.byType(RichText),
      ));
      expect(label.text.style!.color, colors.onPrimary);
    });

    testWidgets('按住时键帽深一层（代替水波），松开回到原来的底色', (tester) async {
      await pumpKeys(tester, ctrlLit: false);
      final colors =
          prism.Theme.of(tester.element(find.byType(Scaffold))).colorScheme;
      final rest = prism.SurfaceLevel.card.colorOf(colors);
      expect(decorationOf(tester, 'Tab').color, rest);
      final gesture = await tester.startGesture(tester.getCenter(capOf('Tab')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        decorationOf(tester, 'Tab').color,
        prism.SurfaceLevel.block.colorOf(colors),
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(decorationOf(tester, 'Tab').color, rest);
    });
  });
}
