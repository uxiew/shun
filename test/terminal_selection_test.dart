import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'support/xterm_terminal_adapter.dart';
import 'package:netcatty_mobile/presentation/terminal/terminal_view.dart';
import 'package:xterm2/xterm.dart' show BufferRangeLine, CellOffset;

// R19 / TER08：选字跨中文（占两格）、emoji、组合字符（e + 组合重音），复制出来的字对；
// 硬换行的两行之间有换行，不被并成一行；自动折行的接回去。

const _options = TerminalViewOptions(
  fontSize: 14,
  secureKeyboard: false,
  interactive: true,
  transparentBackground: false,
);

/// 中文两格宽、emoji 两格宽、e + U+0301 是一个字两个码点。
const _mixed = 'A你好👍e\u0301Z';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Ghostty：长按拖过两行，点「复制」：中文、emoji、组合字符都对，两行之间是换行；远端什么都没收到', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 1800);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final strategy = tester.binding.schedulingStrategy;
    tester.binding.schedulingStrategy =
        ({required int priority, required SchedulerBinding scheduler}) => true;
    addTearDown(() => tester.binding.schedulingStrategy = strategy);
    final copied = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(() =>
        messenger.setMockMethodCallHandler(SystemChannels.platform, null));

    final terminal = GhosttyTerminalAdapter();
    addTearDown(terminal.dispose);
    final sent = StringBuffer();
    terminal.bind((bytes) => sent.write(latin1.decode(bytes)));
    terminal.feed(_bytes('$_mixed\r\nsecond line\r\nthird'));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: terminalViewFor(terminal, _options)),
    ));
    await tester.pump();
    sent.clear();

    final box = tester.getRect(find.byType(Scaffold));
    final rowHeight = (box.height - 16) / terminal.viewRows;
    Offset cell(int row, double x) =>
        Offset(box.left + 8 + x, box.top + 8 + (row + .5) * rowHeight);

    final gesture = await tester.startGesture(
      cell(0, 2),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    // 拖到第二行最右边：第二行整行都在选区里。
    await gesture.moveTo(cell(1, box.width - 30));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(terminal.controller.hasSelection, isTrue);

    await tester.tap(find.byKey(const ValueKey('copy-terminal-selection')));
    await tester.pump();
    expect(copied, hasLength(1));
    expect(copied.single.trimRight(), '$_mixed\nsecond line');
    expect(sent.toString(), isEmpty, reason: '选字、复制不发任何按键');
  });

  test('Ghostty：自动折行的长行复制时接回去，硬换行保留', () {
    final terminal = GhosttyTerminalAdapter();
    addTearDown(terminal.dispose);
    // 默认 80 列：100 个 x 自动折成两行；后面是硬换行的另一行。
    terminal.feed(_bytes('${'x' * 100}\r\nnext'));
    terminal.controller.selectAll();
    final text = terminal.controller.selectedText().trimRight();
    expect(text, '${'x' * 100}\nnext');
  });

  test('xterm2（对照）：同一段文字按行取出，中文、emoji、组合字符对，两行不并', () {
    final terminal = XtermTerminalAdapter();
    addTearDown(terminal.dispose);
    terminal.feed(_bytes('$_mixed\r\nsecond line'));
    final buffer = terminal.terminal.buffer;
    final text = buffer.getText(
      BufferRangeLine(CellOffset(0, 0), CellOffset(11, 1)),
    );
    expect(text.trimRight(), '$_mixed\nsecond line');
  });
}
