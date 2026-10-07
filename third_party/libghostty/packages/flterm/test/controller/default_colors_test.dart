@Tags(['ffi'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/src/controller/terminal_controller.dart';
import 'package:flterm/src/foundation/color_palette.dart';
import 'package:flterm/src/foundation/terminal_theme.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:flutter_test/flutter_test.dart';

// xwshun: 没挂视图时远端问前景/背景/光标色（OSC 10/11/12）也要有应答（R20）。
// 上游要等视图挂上才把颜色交给 Ghostty，在那之前一律不回，问颜色的程序只能等到超时。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TerminalController controller;
  late List<String> output;

  setUp(() {
    controller = TerminalController();
    output = <String>[];
    controller.onOutput = (bytes) => output.add(latin1.decode(bytes));
  });

  tearDown(() => controller.dispose());

  String ask(String query) {
    output.clear();
    controller.write(Uint8List.fromList(utf8.encode(query)));
    return output.join();
  }

  test('no view yet: OSC 10/11 answer with the default dark theme', () {
    // Tomorrow Night：前景 C5C8C6，背景 1D1F21。
    expect(ask('\x1b]10;?\x07'), '\x1b]10;rgb:c5c5/c8c8/c6c6\x07');
    expect(ask('\x1b]11;?\x07'), '\x1b]11;rgb:1d1d/1f1f/2121\x07');
    expect(ask('\x1b]12;?\x07'), isNotEmpty, reason: '光标色没设时也要回点什么');
  });

  test('a view theme replaces the defaults', () {
    final attachment = ViewAttachment(controller);
    addTearDown(attachment.dispose);
    attachment.applyTheme(
      TerminalTheme(
        palette: ColorPalette(
          ansiColors: TerminalTheme.light().palette.ansiColors,
          background: const Color(0xFFFAFAFA),
          foreground: const Color(0xFF383A42),
        ),
      ),
      initial: true,
    );
    expect(ask('\x1b]11;?\x07'), '\x1b]11;rgb:fafa/fafa/fafa\x07');
    expect(ask('\x1b]10;?\x07'), '\x1b]10;rgb:3838/3a3a/4242\x07');
  });
}
