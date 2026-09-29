import 'package:flterm/flterm.dart';
// flterm 导出的 Key 是终端按键枚举，和 Flutter 的 Widget Key 重名。
import 'package:flutter/material.dart' hide Key;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:terminal_spike/main.dart';

// 真机/模拟器上跑：flutter test integration_test -d <设备ID>
// 证明 native 库在该 ABI/页面大小上能加载、终端能初始化、字节能双向走通。
// 它不证明中文输入法可用——IME 的 composing/提交必须真人在真机上用输入法操作（TER02）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native 初始化、文本与控制键按原始字节发出', (tester) async {
    await tester.pumpWidget(const SpikeApp());
    await tester.pumpAndSettle();
    final view = tester.widget<TerminalView>(find.byType(TerminalView));
    final controller = view.controller;

    String sent() =>
        tester.widget<Text>(find.byKey(const ValueKey('sent-bytes'))).data!;

    controller.sendText('中文');
    await tester.pump();
    expect(sent(), contains('e4 b8 ad e6 96 87'), reason: 'UTF-8 原样发出，只发一次');

    controller.sendKey(Key.arrowUp);
    await tester.pump();
    expect(
      sent().split('\n').first,
      contains('1b 5b 41'),
      reason: '方向键是 ESC [ A，不是文字',
    );

    controller.sendKey(Key.escape);
    await tester.pump();
    expect(sent().split('\n').first, startsWith('1B  1b'));
  });
}
