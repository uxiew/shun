import 'package:flterm/flterm.dart';
import 'package:flutter/material.dart' hide Key;
import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_spike/main.dart';

// 真机人工测试时，退格在回环页上显示成方格：回环把 0x7f 原样回显，Ghostty 把它画了出来。
// 回环应该像开着 echo 的 PTY 那样擦掉前一格，而不是把 DEL 写回终端。
void main() {
  testWidgets('回环：退格擦掉前一格，DEL 不进终端', (tester) async {
    await tester.pumpWidget(const SpikeApp());
    await tester.pumpAndSettle();
    final controller = tester
        .widget<TerminalView>(find.byType(TerminalView))
        .controller;

    controller.sendText('ab');
    controller.sendKey(Key.backspace);
    await tester.pump();

    final plain = controller.createFormatter(format: FormatterFormat.plain);
    addTearDown(plain.dispose);
    final lastLine = plain.format().trimRight().split('\n').last;
    expect(lastLine, 'a');
    expect(plain.format(), isNot(contains('\x7f')));
  });
}
