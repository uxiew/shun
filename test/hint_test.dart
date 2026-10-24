import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';
import 'package:shun/presentation/widgets/hint.dart';

// 功能提示（docs/dev/ui-text.md）：ⓘ 要能单独点开，开关要带标题，否则读屏用户既听不到说明、
// 也不知道开关管什么。
void main() {
  tearDown(() => ShunLocalizations.use('zh-CN'));

  Future<List<bool>> pumpSwitch(WidgetTester tester,
      {bool enabled = true}) async {
    final changes = <bool>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => HintSwitchTile(
            title: '敏感页面允许截屏',
            hint: '关着时截屏是黑的。',
            value: changes.isNotEmpty && changes.last,
            onChanged:
                enabled ? (value) => setState(() => changes.add(value)) : null,
          ),
        ),
      ),
    ));
    return changes;
  }

  testWidgets('开关行：点整行切换，点 ⓘ 只开说明不切换', (tester) async {
    final changes = await pumpSwitch(tester);

    await tester.tap(find.text('敏感页面允许截屏'));
    await tester.pump();
    expect(changes, [true]);

    await tester.tap(find.byIcon(Icons.info_outline));
    await tester.pumpAndSettle();
    expect(changes, [true]);
    expect(find.text('关着时截屏是黑的。'), findsOneWidget);

    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.text('关着时截屏是黑的。'), findsNothing);
  });

  testWidgets('开关行在读屏上是两个节点：带标题的开关、能单独点的 ⓘ', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpSwitch(tester);

    expect(
      tester.getSemantics(find.byType(Switch)),
      matchesSemantics(
        label: '敏感页面允许截屏',
        hasToggledState: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    expect(
      tester.getSemantics(find.byType(IconButton)),
      matchesSemantics(
        tooltip: '「敏感页面允许截屏」说明',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    // 标题文字不单独成节点：已经念在开关上了。
    expect(find.bySemanticsLabel('敏感页面允许截屏'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('开关不可用时点整行不切换，ⓘ 照样能开', (tester) async {
    final changes = await pumpSwitch(tester, enabled: false);
    await tester.tap(find.text('敏感页面允许截屏'));
    await tester.pump();
    expect(changes, isEmpty);
    await tester.tap(find.byIcon(Icons.info_outline));
    await tester.pumpAndSettle();
    expect(find.text('关着时截屏是黑的。'), findsOneWidget);
  });

  testWidgets('说明很长、屏幕很矮（横屏）：弹层不溢出，滚到底能点「知道了」', (tester) async {
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HintButton(
          title: 'AI 命令行工具',
          message: List.filled(12, '很长的一段说明。').join('\n\n'),
        ),
      ),
    ));
    await tester.tap(find.byIcon(Icons.info_outline));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('知道了'), 100,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.text('知道了'), findsNothing);
  });

  testWidgets('英文界面的 ⓘ 读作 About …', (tester) async {
    ShunLocalizations.use('en');
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: HintTitle('敏感页面允许截屏', hint: '关着时截屏是黑的。'),
      ),
    ));
    expect(
      find.byTooltip('About “${localized('敏感页面允许截屏')}”'),
      findsOneWidget,
    );
  });
}
