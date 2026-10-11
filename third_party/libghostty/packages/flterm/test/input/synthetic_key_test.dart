@Tags(['ffi'])
library;

import 'dart:convert';

import 'package:flterm/src/controller/terminal_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

// shun: R04 问题 2、4。Android 软键盘、adb 发来的键 scanCode=0，Flutter 给的物理键是
// 0x11_0000_0000 + keyCode 这样的合成值，按物理键查表认不出。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('synthetic Android keys', () {
    late TerminalController controller;
    late ViewAttachment attachment;
    late List<int> output;

    setUp(() {
      controller = TerminalController();
      attachment = ViewAttachment(controller);
      output = <int>[];
      controller.onOutput = output.addAll;
    });

    tearDown(() {
      attachment.dispose();
      controller.dispose();
      HardwareKeyboard.instance.clearState();
    });

    KeyEventResult press(int androidKeyCode, LogicalKeyboardKey logical) {
      return attachment.handleKeyEvent(
        KeyDownEvent(
          physicalKey: PhysicalKeyboardKey(0x1100000000 + androidKeyCode),
          logicalKey: logical,
          timeStamp: Duration.zero,
        ),
      );
    }

    test('soft keyboard Backspace sends DEL', () {
      expect(press(67, LogicalKeyboardKey.backspace), KeyEventResult.handled);
      expect(output, [0x7f]);
    });

    test('soft keyboard arrow sends a cursor sequence', () {
      expect(press(21, LogicalKeyboardKey.arrowLeft), KeyEventResult.handled);
      expect(output, utf8.encode('\x1b[D'));
    });

    test('keys outside the fallback stay ignored', () {
      expect(press(8, LogicalKeyboardKey.digit1), KeyEventResult.ignored);
      expect(output, isEmpty);
    });

    testWidgets('resyncs the IME after the terminal swallows the key', (
      tester,
    ) async {
      final focusNode = FocusNode();
      final scrollController = ScrollController();
      addTearDown(focusNode.dispose);
      addTearDown(scrollController.dispose);
      await tester.pumpWidget(
        Focus(focusNode: focusNode, child: const SizedBox()),
      );
      attachment.attach(focusNode, scrollController, viewId: 0);
      focusNode.requestFocus();
      await tester.pump();
      tester.testTextInput.log.clear();

      press(67, LogicalKeyboardKey.backspace);

      final selections = [
        for (final call in tester.testTextInput.log)
          if (call.method == 'TextInput.setEditingState')
            (call.arguments! as Map<String, Object?>)['selectionBase'],
      ];
      expect(output, [0x7f]);
      expect(selections, [0, 1]);
      attachment.detach();
    });

    // shun: R18。软键盘的回车键由按键那条路发出 CR，并清空编辑区；输入法紧跟着补的换行编辑
    // 是按它自己还留着字的编辑区算的。那一整行不能再发一遍，换行也只算一次。
    testWidgets('Enter key followed by a late newline edit sends one CR', (
      tester,
    ) async {
      final focusNode = FocusNode();
      final scrollController = ScrollController();
      addTearDown(focusNode.dispose);
      addTearDown(scrollController.dispose);
      await tester.pumpWidget(
        Focus(focusNode: focusNode, child: const SizedBox()),
      );
      attachment.attach(focusNode, scrollController, viewId: 0);
      focusNode.requestFocus();
      await tester.pump();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: ' ls',
          selection: TextSelection.collapsed(offset: 3),
        ),
      );
      await tester.pump();

      press(66, LogicalKeyboardKey.enter);
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.textInput.name,
        SystemChannels.textInput.codec.encodeMethodCall(
          const MethodCall('TextInputClient.updateEditingStateWithDeltas', [
            -1,
            {
              'deltas': [
                {
                  'oldText': ' ls',
                  'deltaText': '\n',
                  'deltaStart': 3,
                  'deltaEnd': 3,
                  'selectionBase': 4,
                  'selectionExtent': 4,
                  'selectionAffinity': 'TextAffinity.downstream',
                  'selectionIsDirectional': false,
                  'composingBase': -1,
                  'composingExtent': -1,
                },
              ],
            },
          ]),
        ),
        (_) {},
      );
      await tester.pump();

      expect(utf8.decode(output), 'ls\r');
      attachment.detach();
    });
  });
}
