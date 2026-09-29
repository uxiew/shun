import 'package:flterm/flterm.dart';
import 'package:flutter/material.dart' hide Key;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_spike/main.dart';

// Android 上 scanCode=0 的键（Gboard 退格、adb 注入）到 Flutter 时物理键是 0x11_0000_0000 + keyCode。
// 模拟器实测：flterm 0.0.5 对这些键 0 字节。这里在本机复现并固定兜底行为。
PhysicalKeyboardKey synthetic(int androidKeyCode) =>
    PhysicalKeyboardKey(0x1100000000 + androidKeyCode);

void main() {
  late List<String> Function() sent;

  Future<void> start(WidgetTester tester) async {
    await tester.pumpWidget(const SpikeApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TerminalView));
    await tester.pump();
    sent = () {
      final t = tester.widget<Text>(find.byKey(const ValueKey('sent-bytes'))).data!;
      if (t.startsWith('（')) return [];
      // 最新在前；只取十六进制部分，按发送先后排
      return t.split('\n').map((l) => l.split('  ')[1]).toList().reversed.toList();
    };
  }

  // flutter_test 的 simulateKeyDownEvent(platform: 'android') 必须能查到 scanCode，
  // 模拟不了 scanCode=0 的键；这里照引擎的分发顺序手工投递：先 HardwareKeyboard，再焦点树。
  void dispatch(KeyEvent e) {
    HardwareKeyboard.instance.handleKeyEvent(e);
    // KeyMessage 已标 deprecated，但 3.44 的 KeyEventManager 自己仍用它把事件交给焦点树，没有替代入口。
    // ignore: deprecated_member_use
    ServicesBinding.instance.keyEventManager.keyMessageHandler!(KeyMessage([e], null));
  }

  void down(PhysicalKeyboardKey phys, LogicalKeyboardKey logical) => dispatch(
    KeyDownEvent(physicalKey: phys, logicalKey: logical, timeStamp: Duration.zero),
  );

  void up(PhysicalKeyboardKey phys, LogicalKeyboardKey logical) => dispatch(
    KeyUpEvent(physicalKey: phys, logicalKey: logical, timeStamp: Duration.zero),
  );

  Future<void> press(PhysicalKeyboardKey phys, LogicalKeyboardKey logical) async {
    down(phys, logical);
    up(phys, logical);
  }

  testWidgets('合成物理键：退格/上/Esc/Tab 各按逻辑键发一次', (tester) async {
    await start(tester);
    await press(synthetic(67), LogicalKeyboardKey.backspace);
    await press(synthetic(19), LogicalKeyboardKey.arrowUp);
    await press(synthetic(111), LogicalKeyboardKey.escape);
    await press(synthetic(61), LogicalKeyboardKey.tab);
    await tester.pump();
    expect(sent(), ['7f', '1b 5b 41', '1b', '09']);
  });

  // Alt 组合不在本机测：macOS 版 libghostty 把 Option 当字符组合键（option-as-alt 默认 false），
  // Alt+X 在本机只发 78，Android 上应是 1b 78——由模拟器上的 tool/adb_key_check.sh 核对。
  testWidgets('合成物理键：Ctrl+C 发 0x03', (tester) async {
    await start(tester);
    down(synthetic(113), LogicalKeyboardKey.controlLeft);
    await press(synthetic(31), LogicalKeyboardKey.keyC);
    up(synthetic(113), LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(sent(), ['03']);
  });

  testWidgets('对照：带真实 scanCode 的退格仍由 flterm 处理，只发一次', (tester) async {
    await start(tester);
    await press(PhysicalKeyboardKey.backspace, LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(sent(), ['7f'], reason: '兜底只接管合成物理键，不能和 flterm 各发一遍');
  });
}
