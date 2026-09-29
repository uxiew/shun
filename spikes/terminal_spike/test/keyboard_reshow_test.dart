import 'package:flterm/flterm.dart';
import 'package:flutter/material.dart' hide Key;
import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_spike/main.dart';

// 模拟器实测：返回键收起软键盘后，点终端叫不回键盘（flterm 0.0.5 内部状态仍是 showing）。
// 测试里模拟不了"系统收起键盘"，但能看出第二次点按有没有向平台发 TextInput.show：
// 真机上系统已收起键盘时，没有这次 show 就不会再弹出来。
List<String> shows(WidgetTester t) =>
    t.testTextInput.log.map((c) => c.method).where((m) => m == 'TextInput.show').toList();

void main() {
  testWidgets('对照：裸 TerminalView 第二次点按不再请求显示键盘（flterm 现状）', (tester) async {
    final controller = TerminalController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TerminalView(controller: controller))),
    );
    await tester.tap(find.byType(TerminalView));
    await tester.pump();
    expect(shows(tester), isNotEmpty, reason: '首次获得焦点会弹键盘');

    tester.testTextInput.log.clear();
    await tester.tap(find.byType(TerminalView));
    await tester.pump();
    expect(shows(tester), isEmpty, reason: '如果这里变成非空，说明上游修了，可以删掉 KeyboardReshow');
  });

  testWidgets('spike 页：第二次点按会重新请求显示键盘', (tester) async {
    await tester.pumpWidget(const SpikeApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TerminalView));
    await tester.pump();

    tester.testTextInput.log.clear();
    await tester.tap(find.byType(TerminalView));
    await tester.pump();
    expect(shows(tester), isNotEmpty);
  });

  testWidgets('spike 页：拖动（滚动/选择）不弹键盘', (tester) async {
    await tester.pumpWidget(const SpikeApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TerminalView));
    await tester.pump();

    tester.testTextInput.log.clear();
    await tester.drag(find.byType(TerminalView), const Offset(0, -200));
    await tester.pump();
    expect(shows(tester), isEmpty);
  });
}
