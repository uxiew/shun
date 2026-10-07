@Tags(['ffi'])
library;

import 'dart:convert';

import 'package:flterm/src/controller/terminal_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart' show Key, Mods;

// xwshun: Ctrl+I、Ctrl+M、Ctrl+[ 在传统键盘编码下发 Tab、回车、ESC
// （R20，所有者 10-07 定和 xterm2 一样）。上游照 fixterms 编成 CSI u；
// Android 硬件键盘的按键事件不带字符，实测什么都不发。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Ctrl+I/M/[', () {
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

    const keys = [
      (PhysicalKeyboardKey.keyI, LogicalKeyboardKey.keyI, 'i', 0x09, 105),
      (PhysicalKeyboardKey.keyM, LogicalKeyboardKey.keyM, 'm', 0x0d, 109),
      (
        PhysicalKeyboardKey.bracketLeft,
        LogicalKeyboardKey.bracketLeft,
        '[',
        0x1b,
        91,
      ),
    ];

    KeyEventResult press(
      PhysicalKeyboardKey physical,
      LogicalKeyboardKey logical,
      String? character,
    ) => attachment.handleKeyEvent(
      KeyDownEvent(
        physicalKey: physical,
        logicalKey: logical,
        character: character,
        timeStamp: Duration.zero,
      ),
    );

    for (final (physical, logical, char, c0, codepoint) in keys) {
      // Android 硬件键盘给的是 null；桌面平台常给不带 Ctrl 的那个字符，也有给控制字符本身的。
      for (final character in <String?>[
        null,
        char,
        String.fromCharCode(c0),
      ]) {
        test('Ctrl+$char sends ${c0.toRadixString(16)} '
            '(character: ${character?.codeUnits})', () async {
          await simulateKeyDownEvent(LogicalKeyboardKey.controlLeft);
          expect(press(physical, logical, character), KeyEventResult.handled);
          expect(output, [c0]);
        });
      }

      test('Ctrl+Alt+$char sends ESC + ${c0.toRadixString(16)}', () async {
        await simulateKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await simulateKeyDownEvent(LogicalKeyboardKey.altLeft);
        expect(press(physical, logical, null), KeyEventResult.handled);
        expect(output, [0x1b, c0]);
      });

      test('Kitty keyboard protocol keeps CSI u for Ctrl+$char', () async {
        controller.write(Uint8List.fromList(utf8.encode('\x1b[=1u')));
        await simulateKeyDownEvent(LogicalKeyboardKey.controlLeft);
        expect(press(physical, logical, null), KeyEventResult.handled);
        expect(utf8.decode(output), '\x1b[$codepoint;5u');
      });

      // 快捷键栏亮着 Ctrl 再按软键盘、或者 App 直接 sendKey：走 encodeKeyPress。
      test('programmatic Ctrl+$char sends ${c0.toRadixString(16)}', () {
        final key = switch (char) {
          'i' => Key.i,
          'm' => Key.m,
          _ => Key.bracketLeft,
        };
        controller.sendKey(key, mods: const Mods.ctrl());
        expect(output, [c0]);
      });

      test('Ctrl+Shift+$char is not turned into the control byte', () async {
        await simulateKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await simulateKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        press(physical, logical, null);
        expect(output, isNot([c0]));
      });
    }

    test('plain I, M and [ are untouched', () {
      press(PhysicalKeyboardKey.keyI, LogicalKeyboardKey.keyI, 'i');
      press(PhysicalKeyboardKey.keyM, LogicalKeyboardKey.keyM, 'm');
      press(
        PhysicalKeyboardKey.bracketLeft,
        LogicalKeyboardKey.bracketLeft,
        '[',
      );
      expect(utf8.decode(output), 'im[');
    });

    test('other Ctrl letters keep their control bytes', () async {
      await simulateKeyDownEvent(LogicalKeyboardKey.controlLeft);
      press(PhysicalKeyboardKey.keyA, LogicalKeyboardKey.keyA, null);
      press(PhysicalKeyboardKey.keyJ, LogicalKeyboardKey.keyJ, null);
      press(PhysicalKeyboardKey.keyN, LogicalKeyboardKey.keyN, null);
      expect(output, [0x01, 0x0a, 0x0e]);
    });
  });
}
