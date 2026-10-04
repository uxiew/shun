import 'dart:convert';

import 'package:flterm/src/foundation.dart';
import 'package:flterm/src/links/link_settings.dart';
import 'package:flterm/src/rendering.dart';
import 'package:flterm/src/widgets.dart';
import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        debugDefaultTargetPlatformOverride,
        defaultTargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart' hide ColorScheme, KeyEvent;
import 'package:libghostty/libghostty.dart'
    as vt
    show ColorScheme, ColorSchemeReportEncode;

extension _SelectionEdges on Selection {
  Position get _startPoint => start.positionIn(.viewport)!;

  Position get _endPoint => end.positionIn(.viewport)!;

  bool get _forward {
    final start = _startPoint;
    final end = _endPoint;
    return start.row != end.row ? start.row < end.row : start.col <= end.col;
  }

  int get startCol => _forward ? _startPoint.col : _startPoint.col + 1;

  int get endCol => _forward ? _endPoint.col + 1 : _endPoint.col;

  TerminalSelectionShape get mode {
    return rectangle
        ? TerminalSelectionShape.rectangle
        : TerminalSelectionShape.normal;
  }
}

void main() {
  group('TerminalView', () {
    Future<void> sendSelectAllShortcut(WidgetTester tester) async {
      switch (defaultTargetPlatform) {
        case TargetPlatform.macOS || TargetPlatform.iOS:
          await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
        case TargetPlatform.linux || TargetPlatform.fuchsia:
          await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
        case TargetPlatform.windows || TargetPlatform.android:
          await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      }
      await tester.pump();
    }

    void writeUtf8(TerminalController controller, String text) {
      controller.write(Uint8List.fromList(utf8.encode(text)));
    }

    Selection? activeSelection(TerminalController controller) {
      return (controller as TerminalViewBinding).terminal.selection;
    }

    Terminal terminal(TerminalController controller) {
      return (controller as TerminalViewBinding).terminal;
    }

    String decodeOutput(List<Uint8List> output) {
      return utf8.decode(
        Uint8List.fromList(output.expand((chunk) => chunk).toList()),
      );
    }

    Future<void> sendTextInputDeltas(List<Map<String, Object?>> deltas) async {
      final messageBytes = const JSONMessageCodec().encodeMessage({
        'method': 'TextInputClient.updateEditingStateWithDeltas',
        'args': [
          -1,
          {'deltas': deltas},
        ],
      });
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            SystemChannels.textInput.name,
            messageBytes,
            (_) {},
          );
    }

    List<MethodCall> recordTextInputCalls() {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.textInput, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.textInput, null);
      });
      return calls;
    }

    Map<String, Object?> lastTextInputCall(
      List<MethodCall> calls,
      String method,
    ) {
      return calls.lastWhere((call) => call.method == method).arguments!
          as Map<String, Object?>;
    }

    Future<void> withMacOSPlatform(Future<void> Function() body) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    Future<void> releaseControlIfPressed(WidgetTester tester) async {
      if (!HardwareKeyboard.instance.isControlPressed) return;
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    }

    Widget wrapInApp({
      required TerminalController controller,
      TerminalTheme? theme,
      TerminalScrollController? scrollController,
      bool autofocus = false,
      bool showKeyboard = true,
      MouseAutoHide mouseAutoHide = .onInput,
      TerminalGestureSettings gestureSettings = const TerminalGestureSettings(),
      LinkSettings linkSettings = const LinkSettings(),
      EdgeInsets padding = EdgeInsets.zero,
      double width = 800,
      double height = 480,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: width,
            height: height,
            child: TerminalView(
              controller: controller,
              theme: theme,
              scrollController: scrollController,
              autofocus: autofocus,
              showKeyboard: showKeyboard,
              mouseAutoHide: mouseAutoHide,
              gestureSettings: gestureSettings,
              linkSettings: linkSettings,
              padding: padding,
            ),
          ),
        ),
      );
    }

    Widget wrapSplitTerminals({
      required TerminalController controller,
      required TerminalController controller2,
      bool scoped = false,
    }) {
      final terminals = Column(
        children: [
          Expanded(
            child: TerminalView(
              controller: controller,
              padding: EdgeInsets.zero,
            ),
          ),
          Expanded(
            child: TerminalView(
              controller: controller2,
              padding: EdgeInsets.zero,
            ),
          ),
        ],
      );
      return MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 480,
            child: scoped ? TerminalScope(child: terminals) : terminals,
          ),
        ),
      );
    }

    late TerminalController controller;

    setUp(() => controller = TerminalController());

    tearDown(() => controller.dispose());

    void writeNumberedLines(int count) {
      for (var i = 0; i < count; i++) {
        writeUtf8(controller, 'line $i\r\n');
      }
    }

    TerminalRenderer renderer(WidgetTester tester) {
      return tester.widget<TerminalRenderer>(find.byType(TerminalRenderer));
    }

    Future<TerminalScrollController> pumpBlinkingScrollableTerminal(
      WidgetTester tester,
    ) async {
      controller.dispose();
      controller = TerminalController(
        config: const TerminalConfig(cursorBlink: true),
      );
      final scrollController = TerminalScrollController();
      final theme = TerminalTheme.dark().copyWith(
        cursor: const CursorTheme(blinkInterval: Duration(milliseconds: 10)),
      );
      addTearDown(scrollController.dispose);
      await tester.pumpWidget(
        wrapInApp(
          controller: controller,
          theme: theme,
          scrollController: scrollController,
          autofocus: true,
          showKeyboard: false,
          width: 400,
          height: 80,
        ),
      );
      await tester.pump();
      writeNumberedLines(40);
      await tester.pump();
      await tester.pump();
      return scrollController;
    }

    testWidgets('renders with controller', (tester) async {
      await tester.pumpWidget(wrapInApp(controller: controller));
      expect(find.byType(TerminalView), findsOneWidget);
    });

    testWidgets('creates an isolated render cache without explicit scope', (
      tester,
    ) async {
      final controller2 = TerminalController();
      addTearDown(controller2.dispose);

      await tester.pumpWidget(
        wrapSplitTerminals(controller: controller, controller2: controller2),
      );
      await tester.pumpAndSettle();

      expect(find.byType(TerminalRenderer), findsNWidgets(2));
      expect(find.byType(TerminalScope), findsNWidgets(2));
    });

    testWidgets('uses explicit TerminalScope for descendant terminals', (
      tester,
    ) async {
      final controller2 = TerminalController();
      addTearDown(controller2.dispose);

      await tester.pumpWidget(
        wrapSplitTerminals(
          controller: controller,
          controller2: controller2,
          scoped: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(TerminalRenderer), findsNWidgets(2));
      expect(find.byType(TerminalScope), findsOneWidget);
    });

    testWidgets('onResize fires with dimensions from layout', (tester) async {
      final cols = <int>[];
      final rows = <int>[];
      controller.onResize = (reportedCols, reportedRows) {
        cols.add(reportedCols);
        rows.add(reportedRows);
      };

      await tester.pumpWidget(wrapInApp(controller: controller));
      await tester.pumpAndSettle();

      expect(cols, isNotEmpty);
      expect(cols.last, greaterThan(0));
      expect(rows.last, greaterThan(0));
    });

    testWidgets('tap to focus', (tester) async {
      await tester.pumpWidget(wrapInApp(controller: controller));

      expect(controller.hasFocus, isFalse);

      await tester.tap(find.byType(TerminalView));
      await tester.pumpAndSettle();

      expect(controller.hasFocus, isTrue);
      expect(controller.keyboardState, KeyboardState.showing);
    });

    testWidgets('alternate screen keeps soft keyboard enabled', (tester) async {
      await tester.pumpWidget(
        wrapInApp(controller: controller, autofocus: true),
      );
      await tester.pump();

      writeUtf8(controller, '\x1b[?1049h');
      await tester.pump();

      expect(controller.keyboardState, KeyboardState.showing);
    });

    testWidgets('autofocus focuses on mount', (tester) async {
      await tester.pumpWidget(
        wrapInApp(controller: controller, autofocus: true),
      );
      await tester.pump();

      expect(controller.hasFocus, isTrue);
      expect(controller.keyboardState, KeyboardState.showing);
    });

    testWidgets('scrolling into scrollback keeps the cursor visible', (
      tester,
    ) async {
      final scrollController = await pumpBlinkingScrollableTerminal(tester);

      scrollController.jumpTo(0);
      await tester.pump();

      expect(
        (controller as TerminalViewBinding).terminal.isViewportActive,
        isFalse,
      );
      expect(renderer(tester).blinkVisible, isTrue);

      await tester.pump(const Duration(milliseconds: 11));
      await tester.pump();

      expect(renderer(tester).blinkVisible, isTrue);
    });

    testWidgets('scrolling to the live viewport restarts cursor blinking', (
      tester,
    ) async {
      final scrollController = await pumpBlinkingScrollableTerminal(tester);

      scrollController.jumpTo(0);
      await tester.pump();
      scrollController.jumpTo(scrollController.position.maxScrollExtent);
      await tester.pump();

      expect(
        (controller as TerminalViewBinding).terminal.isViewportActive,
        isTrue,
      );

      await tester.pump(const Duration(milliseconds: 11));
      await tester.pump();

      expect(renderer(tester).blinkVisible, isFalse);
    });

    testWidgets('text input produces output via onOutput', (tester) async {
      final output = <Uint8List>[];
      controller.onOutput = output.add;

      await tester.pumpWidget(
        wrapInApp(controller: controller, autofocus: true),
      );
      await tester.pump();

      tester.testTextInput.enterText('a');
      await tester.pump();

      expect(utf8.decode(output.single), 'a');
    });

    testWidgets('text input applies virtual ctrl to single-char commit', (
      tester,
    ) async {
      final output = <Uint8List>[];
      controller.onOutput = output.add;
      controller.toggleMod(const Mods.ctrl());

      await tester.pumpWidget(
        wrapInApp(controller: controller, autofocus: true),
      );
      await tester.pump();

      tester.testTextInput.enterText('c');
      await tester.pump();

      expect(output.single, utf8.encode('\x03'));
      expect(controller.virtualMods, const Mods.none());
    });

    testWidgets('text input applies virtual ctrl to punctuation commit', (
      tester,
    ) async {
      final output = <Uint8List>[];
      controller.onOutput = output.add;
      controller.toggleMod(const Mods.ctrl());

      await tester.pumpWidget(
        wrapInApp(controller: controller, autofocus: true),
      );
      await tester.pump();

      tester.testTextInput.enterText('[');
      await tester.pump();

      expect(output.single, utf8.encode('\x1b[91;5u'));
      expect(controller.virtualMods, const Mods.none());
    });

    testWidgets('text input emits multi-character commit as plain text', (
      tester,
    ) async {
      final output = <Uint8List>[];
      controller.onOutput = output.add;
      controller.toggleMod(const Mods.ctrl());

      await tester.pumpWidget(
        wrapInApp(controller: controller, autofocus: true),
      );
      await tester.pump();

      tester.testTextInput.enterText('hello');
      await tester.pump();

      expect(decodeOutput(output), 'hello');
      expect(controller.virtualMods, const Mods.none());
    });

    testWidgets('text input emits unmapped commit as plain text', (
      tester,
    ) async {
      final output = <Uint8List>[];
      controller.onOutput = output.add;
      controller.toggleMod(const Mods.ctrl());

      await tester.pumpWidget(
        wrapInApp(controller: controller, autofocus: true),
      );
      await tester.pump();

      tester.testTextInput.enterText('\u{1F600}');
      await tester.pump();

      expect(decodeOutput(output), '\u{1F600}');
      expect(controller.virtualMods, const Mods.none());
    });

    testWidgets('text input deletion respects back-arrow key mode', (
      tester,
    ) async {
      final output = <Uint8List>[];
      controller.onOutput = output.add;
      controller.modeSet(const TerminalMode.backArrowKeyMode(), value: true);

      await tester.pumpWidget(
        wrapInApp(controller: controller, autofocus: true),
      );
      await tester.pump();

      await sendTextInputDeltas([
        {
          'oldText': 'x',
          'deltaText': '',
          'deltaStart': 0,
          'deltaEnd': 1,
          'selectionBase': 0,
          'selectionExtent': 0,
          'selectionAffinity': 'TextAffinity.downstream',
          'selectionIsDirectional': false,
          'composingBase': -1,
          'composingExtent': -1,
        },
      ]);
      await tester.pump();

      expect(output.single, utf8.encode('\x08'));
    });

    testWidgets('desktop text input commit after key event produces output', (
      tester,
    ) async {
      await withMacOSPlatform(() async {
        final output = <Uint8List>[];
        controller.onOutput = output.add;

        await tester.pumpWidget(
          wrapInApp(controller: controller, autofocus: true),
        );
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        tester.testTextInput.enterText('a');
        await tester.pump();

        expect(utf8.decode(output.single), 'a');
      });
    });

    testWidgets('keyboard input remains available to desktop text input', (
      tester,
    ) async {
      await withMacOSPlatform(() async {
        await tester.pumpWidget(
          wrapInApp(controller: controller, autofocus: true),
        );
        await tester.pump();

        final handled = await tester.sendKeyEvent(LogicalKeyboardKey.keyA);

        expect(handled, isFalse);
      });
    });

    testWidgets('desktop printable key respects terminal keyboard protocol', (
      tester,
    ) async {
      await withMacOSPlatform(() async {
        writeUtf8(controller, '\x1b[=31u');
        final output = <Uint8List>[];
        controller.onOutput = output.add;

        await tester.pumpWidget(
          wrapInApp(controller: controller, autofocus: true),
        );
        await tester.pump();

        final handled = await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await tester.pump();

        expect(handled, isTrue);
        expect(decodeOutput(output), isNot('a'));
        expect(decodeOutput(output), startsWith('\x1b'));
      });
    });

    testWidgets('shifted printable key emits text in keyboard protocol mode', (
      tester,
    ) async {
      writeUtf8(controller, '\x1b[=1u');
      final output = <Uint8List>[];
      controller.onOutput = output.add;

      await tester.pumpWidget(
        wrapInApp(controller: controller, autofocus: true, showKeyboard: false),
      );
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await tester.sendKeyEvent(
        LogicalKeyboardKey.semicolon,
        physicalKey: PhysicalKeyboardKey.semicolon,
        character: ':',
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      await tester.pump();

      expect(decodeOutput(output), ':');
    });

    testWidgets('composition updates preedit without output', (tester) async {
      final output = <Uint8List>[];
      controller.onOutput = output.add;

      await tester.pumpWidget(
        wrapInApp(controller: controller, autofocus: true),
      );
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'ni',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 0, end: 2),
        ),
      );
      await tester.pump();

      expect((controller as TerminalViewBinding).preeditText, 'ni');
      expect(output, isEmpty);
    });

    testWidgets('composition clears selection when it starts', (tester) async {
      await tester.pumpWidget(
        wrapInApp(controller: controller, autofocus: true),
      );
      await tester.pump();
      controller.selectRange(
        start: const Position(row: 0, col: 0),
        end: const Position(row: 0, col: 4),
      );

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'ni',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 0, end: 2),
        ),
      );
      await tester.pump();

      expect(controller.hasSelection, isFalse);
    });

    testWidgets('composition scrolls to bottom when it starts', (tester) async {
      controller.dispose();
      controller = TerminalController(
        config: const TerminalConfig(cols: 20, rows: 3),
      );

      await tester.pumpWidget(
        wrapInApp(controller: controller, autofocus: true),
      );
      await tester.pump();
      writeNumberedLines(100);
      controller.scrollToTop();

      expect(controller.scrollbar.offset, lessThan(controller.scrollbackRows));

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'ni',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 0, end: 2),
        ),
      );
      await tester.pump();

      expect(controller.scrollbar.offset, controller.scrollbackRows);
    });

    testWidgets('delayed desktop composition emits only committed text', (
      tester,
    ) async {
      await withMacOSPlatform(() async {
        final output = <Uint8List>[];
        controller.onOutput = output.add;

        await tester.pumpWidget(
          wrapInApp(controller: controller, autofocus: true),
        );
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
        await tester.pump(const Duration(milliseconds: 2));
        await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
        await tester.pump(const Duration(milliseconds: 2));
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'ni',
            selection: TextSelection.collapsed(offset: 2),
            composing: TextRange(start: 0, end: 2),
          ),
        );
        await tester.pump();
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '你',
            selection: TextSelection.collapsed(offset: 1),
          ),
        );
        await tester.pump();

        expect(decodeOutput(output), '你');
      });
    });

    testWidgets('composition keeps desktop keyboard input available', (
      tester,
    ) async {
      await withMacOSPlatform(() async {
        final output = <Uint8List>[];
        controller.onOutput = output.add;

        await tester.pumpWidget(
          wrapInApp(controller: controller, autofocus: true),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'n',
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange(start: 0, end: 1),
          ),
        );
        await tester.pump();

        final handled = await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
        await tester.pump(const Duration(milliseconds: 1));

        expect(handled, isFalse);
        expect(output, isEmpty);
      });
    });

    testWidgets('finalized composition commits text and clears preedit', (
      tester,
    ) async {
      final output = <Uint8List>[];
      controller.onOutput = output.add;

      await tester.pumpWidget(
        wrapInApp(controller: controller, autofocus: true),
      );
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'ni',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 0, end: 2),
        ),
      );
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '日',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      await tester.pump();

      expect((controller as TerminalViewBinding).preeditText, '');
      expect(utf8.decode(output.single), '日');
    });

    testWidgets(
      'desktop backspace after candidate commit forwards to platform IME',
      (tester) async {
        await withMacOSPlatform(() async {
          final calls = recordTextInputCalls();
          final output = <Uint8List>[];
          controller.onOutput = output.add;
          controller.modeSet(
            const TerminalMode.backArrowKeyMode(),
            value: true,
          );

          await tester.pumpWidget(
            wrapInApp(controller: controller, autofocus: true),
          );
          await tester.pump();
          tester.testTextInput.updateEditingValue(
            const TextEditingValue(
              text: 'ni',
              selection: TextSelection.collapsed(offset: 2),
              composing: TextRange(start: 0, end: 2),
            ),
          );
          await tester.pump();
          tester.testTextInput.updateEditingValue(
            const TextEditingValue(
              text: '你',
              selection: TextSelection.collapsed(offset: 1),
            ),
          );
          await tester.pump();
          calls.clear();
          output.clear();

          final handled = await tester.sendKeyEvent(
            LogicalKeyboardKey.backspace,
          );
          await tester.pump();

          expect(handled, isFalse);
          expect(decodeOutput(output), '\x08');
          expect(
            calls.where((call) => call.method == 'TextInput.clearClient'),
            isEmpty,
          );
          expect(
            calls.where((call) => call.method == 'TextInput.hide'),
            isEmpty,
          );

          await sendTextInputDeltas([
            {
              'oldText': '你',
              'deltaText': '',
              'deltaStart': 0,
              'deltaEnd': 1,
              'selectionBase': 0,
              'selectionExtent': 0,
              'selectionAffinity': 'TextAffinity.downstream',
              'selectionIsDirectional': false,
              'composingBase': -1,
              'composingExtent': -1,
            },
          ]);
          await tester.pump();

          expect(decodeOutput(output), '\x08');
        });
      },
    );

    testWidgets(
      'desktop modified backspace after candidate commit stays terminal-only',
      (tester) async {
        await withMacOSPlatform(() async {
          final output = <Uint8List>[];
          controller.onOutput = output.add;
          controller.modeSet(
            const TerminalMode.backArrowKeyMode(),
            value: true,
          );

          await tester.pumpWidget(
            wrapInApp(controller: controller, autofocus: true),
          );
          await tester.pump();
          tester.testTextInput.updateEditingValue(
            const TextEditingValue(
              text: 'ni',
              selection: TextSelection.collapsed(offset: 2),
              composing: TextRange(start: 0, end: 2),
            ),
          );
          await tester.pump();
          tester.testTextInput.updateEditingValue(
            const TextEditingValue(
              text: '你',
              selection: TextSelection.collapsed(offset: 1),
            ),
          );
          await tester.pump();
          output.clear();

          await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
          final handled = await tester.sendKeyEvent(
            LogicalKeyboardKey.backspace,
          );
          await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
          await tester.pump();

          expect(handled, isTrue);
          expect(output, hasLength(1));

          await sendTextInputDeltas([
            {
              'oldText': 'x',
              'deltaText': '',
              'deltaStart': 0,
              'deltaEnd': 1,
              'selectionBase': 0,
              'selectionExtent': 0,
              'selectionAffinity': 'TextAffinity.downstream',
              'selectionIsDirectional': false,
              'composingBase': -1,
              'composingExtent': -1,
            },
          ]);
          await tester.pump();

          expect(output, hasLength(2));
        });
      },
    );

    testWidgets('text input geometry tracks terminal cursor cell', (
      tester,
    ) async {
      final calls = recordTextInputCalls();
      writeUtf8(controller, 'prompt\r\nab');

      await tester.pumpWidget(
        wrapInApp(controller: controller, autofocus: true),
      );
      await tester.pump();
      await tester.pump();

      final renderBox = tester.renderObject<TerminalRenderBox>(
        find.byType(TerminalRenderer),
      );
      final expected = renderBox.textInputCaretRect;
      final editable = lastTextInputCall(
        calls,
        'TextInput.setEditableSizeAndTransform',
      );
      final caret = lastTextInputCall(calls, 'TextInput.setCaretRect');
      final composing = lastTextInputCall(calls, 'TextInput.setMarkedTextRect');

      expect(editable['width'], renderBox.size.width);
      expect(editable['height'], renderBox.size.height);
      expect(caret['x'], expected.left);
      expect(caret['y'], expected.top);
      expect(composing['x'], expected.left);
      expect(composing['y'], expected.top);
      expect(expected.left, greaterThan(0));
      expect(expected.top, greaterThan(0));
    });

    testWidgets('unmount clears focus state', (tester) async {
      await tester.pumpWidget(wrapInApp(controller: controller));

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpAndSettle();

      expect(controller.hasFocus, isFalse);
    });

    testWidgets('changing theme updates metrics', (tester) async {
      await tester.pumpWidget(wrapInApp(controller: controller));

      final largeTheme = TerminalTheme(
        palette: ColorPalette(
          ansiColors: List.generate(16, (_) => const Color(0xFF888888)),
          background: const Color(0xFF000000),
          foreground: const Color(0xFFFFFFFF),
        ),
        fontSize: 24.0,
      );

      await tester.pumpWidget(
        wrapInApp(controller: controller, theme: largeTheme),
      );
      await tester.pumpAndSettle();

      expect(find.byType(TerminalView), findsOneWidget);
    });

    testWidgets('reports light color scheme for perceived-light backgrounds', (
      tester,
    ) async {
      final output = <Uint8List>[];
      controller.onOutput = output.add;
      final theme = TerminalTheme(
        palette: ColorPalette(
          ansiColors: List.filled(16, const Color(0xFF888888)),
          background: const Color(0xFFFF8000),
          foreground: const Color(0xFF000000),
        ),
      );

      await tester.pumpWidget(wrapInApp(controller: controller, theme: theme));
      writeUtf8(controller, '\x1b[?996n');

      expect(decodeOutput(output), vt.ColorScheme.light.encode());
    });

    testWidgets('sendText via controller produces onOutput', (tester) async {
      final output = <Uint8List>[];
      controller.onOutput = output.add;

      await tester.pumpWidget(wrapInApp(controller: controller));
      await tester.pump();

      controller.sendText('hello');

      expect(output, hasLength(1));
      expect(utf8.decode(output.first), 'hello');
    });

    testWidgets('changing controller detaches old and attaches new', (
      tester,
    ) async {
      final controller2 = TerminalController();
      addTearDown(controller2.dispose);

      await tester.pumpWidget(wrapInApp(controller: controller));

      await tester.pumpWidget(wrapInApp(controller: controller2));
      await tester.pumpAndSettle();

      expect(controller.hasFocus, isFalse);
      expect(find.byType(TerminalView), findsOneWidget);
    });

    testWidgets('changing scrollController keeps the view mounted', (
      tester,
    ) async {
      final sc1 = TerminalScrollController();
      final sc2 = TerminalScrollController();
      addTearDown(sc1.dispose);
      addTearDown(sc2.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 480,
              child: TerminalView(
                controller: controller,
                scrollController: sc1,
                padding: EdgeInsets.zero,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 480,
              child: TerminalView(
                controller: controller,
                scrollController: sc2,
                padding: EdgeInsets.zero,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(TerminalView), findsOneWidget);
    });

    testWidgets('showKeyboard false skips keyboard show on focus', (
      tester,
    ) async {
      final calls = recordTextInputCalls();

      await tester.pumpWidget(
        wrapInApp(controller: controller, showKeyboard: false),
      );

      await tester.tap(find.byType(TerminalView));
      await tester.pumpAndSettle();

      expect(controller.hasFocus, isTrue);
      expect(controller.keyboardState, KeyboardState.hidden);
      expect(
        calls.where((call) => call.method == 'TextInput.setClient'),
        hasLength(1),
      );
      expect(calls.where((call) => call.method == 'TextInput.show'), isEmpty);
    });

    group('text input connection', () {
      List<MethodCall> lifecycleCalls(List<MethodCall> calls) {
        return calls
            .where(
              (call) => const {
                'TextInput.setClient',
                'TextInput.clearClient',
                'TextInput.show',
                'TextInput.hide',
                'TextInput.updateConfig',
              }.contains(call.method),
            )
            .toList();
      }

      testWidgets('uses the containing Flutter view', (tester) async {
        final calls = recordTextInputCalls();

        await tester.pumpWidget(
          wrapInApp(controller: controller, autofocus: true),
        );
        await tester.pump();
        final setClient = calls.singleWhere(
          (call) => call.method == 'TextInput.setClient',
        );
        final arguments = setClient.arguments! as List<Object?>;
        final configuration = arguments[1]! as Map<String, Object?>;

        expect(configuration['viewId'], tester.view.viewId);
      });

      testWidgets('keeps the connection across same-view dependency changes', (
        tester,
      ) async {
        final calls = recordTextInputCalls();
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          wrapInApp(controller: controller, autofocus: true),
        );
        await tester.pump();
        calls.clear();

        tester.view.devicePixelRatio = tester.view.devicePixelRatio + 1;
        await tester.pump();

        expect(lifecycleCalls(calls), isEmpty);
      });
    });

    testWidgets('touch drag does not create selection', (tester) async {
      writeUtf8(controller, 'hello world');
      await tester.pumpWidget(
        wrapInApp(controller: controller, autofocus: true),
      );
      await tester.pumpAndSettle();

      final center = tester.getCenter(find.byType(TerminalView));

      final downEvent = PointerDownEvent(position: center);
      await tester.sendEventToBinding(downEvent);
      await tester.pump();

      final moveEvent = PointerMoveEvent(
        position: center + const Offset(100, 0),
        pointer: downEvent.pointer,
      );
      await tester.sendEventToBinding(moveEvent);
      await tester.pump();

      final upEvent = PointerUpEvent(
        position: center + const Offset(100, 0),
        pointer: downEvent.pointer,
      );
      await tester.sendEventToBinding(upEvent);
      await tester.pumpAndSettle();

      expect(controller.hasSelection, isFalse);
    });

    group('link interaction', () {
      testWidgets('mouse tap ignores link without modifier', (tester) async {
        final links = <ActivatedLink>[];
        writeUtf8(controller, 'https://example.test');

        await tester.pumpWidget(
          wrapInApp(
            controller: controller,
            linkSettings: LinkSettings(
              modifier: .control,
              types: const {LinkType.text},
              onActivate: links.add,
            ),
            width: 400,
            height: 80,
          ),
        );
        await tester.pumpAndSettle();

        final topLeft = tester.getTopLeft(find.byType(TerminalView));
        final gesture = await tester.startGesture(
          topLeft + const Offset(4, 8),
          kind: PointerDeviceKind.mouse,
        );
        await gesture.up();
        await tester.pump();

        expect(links, isEmpty);
      });

      testWidgets('mouse tap activates link with modifier', (tester) async {
        final links = <ActivatedLink>[];
        writeUtf8(controller, 'https://example.test');

        await tester.pumpWidget(
          wrapInApp(
            controller: controller,
            autofocus: true,
            linkSettings: LinkSettings(
              modifier: .control,
              types: const {LinkType.text},
              onActivate: links.add,
            ),
            width: 400,
            height: 80,
          ),
        );
        await tester.pumpAndSettle();

        final topLeft = tester.getTopLeft(find.byType(TerminalView));
        addTearDown(() => releaseControlIfPressed(tester));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
        final gesture = await tester.startGesture(
          topLeft + const Offset(4, 8),
          kind: PointerDeviceKind.mouse,
        );
        await gesture.up();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
        await tester.pump();

        expect(links, [
          isA<ActivatedLink>().having(
            (link) => link.text,
            'text',
            'https://example.test',
          ),
        ]);
      });

      testWidgets('modifier hover highlights link', (tester) async {
        writeUtf8(controller, 'https://example.test');

        await tester.pumpWidget(
          wrapInApp(
            controller: controller,
            autofocus: true,
            linkSettings: LinkSettings(
              modifier: .control,
              types: const {LinkType.text},
              onActivate: (_) {},
            ),
            width: 400,
            height: 80,
          ),
        );
        await tester.pumpAndSettle();

        final topLeft = tester.getTopLeft(find.byType(TerminalView));
        addTearDown(() => releaseControlIfPressed(tester));
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        addTearDown(gesture.removePointer);
        await gesture.addPointer(location: topLeft + const Offset(4, 8));
        await gesture.moveTo(topLeft + const Offset(4, 8));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
        await tester.pump();

        expect(
          renderer(tester).linkSnapshot.highlighted,
          const CellRange(
            start: Position(row: 0, col: 0),
            end: Position(row: 0, col: 19),
          ),
        );
      });

      testWidgets('touch tap activates link without modifier', (tester) async {
        final links = <ActivatedLink>[];
        writeUtf8(controller, 'https://example.test');

        await tester.pumpWidget(
          wrapInApp(
            controller: controller,
            linkSettings: LinkSettings(
              types: const {LinkType.text},
              onActivate: links.add,
            ),
            width: 400,
            height: 80,
          ),
        );
        await tester.pumpAndSettle();

        final topLeft = tester.getTopLeft(find.byType(TerminalView));
        await tester.tapAt(topLeft + const Offset(4, 8));
        await tester.pump();

        expect(links, [
          isA<ActivatedLink>().having(
            (link) => link.text,
            'text',
            'https://example.test',
          ),
        ]);
      });
    });

    testWidgets('long press starts normal selection by default', (
      tester,
    ) async {
      writeUtf8(controller, 'hello world');
      await tester.pumpWidget(
        wrapInApp(controller: controller, autofocus: true),
      );
      await tester.pumpAndSettle();

      final center = tester.getCenter(find.byType(TerminalView));
      final gesture = await tester.startGesture(center);
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveBy(const Offset(80, 40));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      final sel = activeSelection(controller);
      expect(sel, isNotNull);
      expect(sel!.mode, TerminalSelectionShape.normal);
    });

    group('scrolling', () {
      Future<
        ({
          TerminalScrollController scrollController,
          Terminal terminal,
          double cellHeight,
        })
      >
      pumpScrollableTerminal(WidgetTester tester) async {
        final scrollController = TerminalScrollController();
        addTearDown(scrollController.dispose);

        await tester.pumpWidget(
          wrapInApp(
            controller: controller,
            scrollController: scrollController,
            showKeyboard: false,
            width: 400,
            height: 80,
          ),
        );
        await tester.pump();
        writeNumberedLines(80);
        await tester.pump();
        await tester.pump();

        return (
          scrollController: scrollController,
          terminal: terminal(controller),
          cellHeight: renderer(tester).metrics.cellHeight,
        );
      }

      testWidgets('scroll event changes scroll offset', (tester) async {
        final fixture = await pumpScrollableTerminal(tester);
        final initialPixels = fixture.scrollController.position.pixels;
        final center = tester.getCenter(find.byType(TerminalView));

        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: center,
            scrollDelta: const Offset(0, -100),
          ),
        );
        await tester.pumpAndSettle();

        expect(fixture.scrollController.position.pixels, isNot(initialPixels));
      });

      testWidgets('pixel offset maps to terminal row after existing scroll', (
        tester,
      ) async {
        final fixture = await pumpScrollableTerminal(tester);
        final targetRow = fixture.terminal.scrollbackRows ~/ 2;
        fixture.terminal.scrollToBottom();

        fixture.scrollController.jumpTo(targetRow * fixture.cellHeight);
        await tester.pump();

        expect(fixture.terminal.scrollbar.offset, targetRow);
      });

      testWidgets('negative pixel offset clamps to top row', (tester) async {
        final fixture = await pumpScrollableTerminal(tester);

        fixture.scrollController.jumpTo(-100);
        await tester.pump();

        expect(fixture.terminal.scrollbar.offset, 0);
      });

      testWidgets('overscroll pixel offset clamps to live row', (tester) async {
        final fixture = await pumpScrollableTerminal(tester);
        final position = fixture.scrollController.position;

        fixture.scrollController.jumpTo(position.maxScrollExtent + 100);
        await tester.pump();

        expect(
          fixture.terminal.scrollbar.offset,
          fixture.terminal.scrollbackRows,
        );
      });
    });

    testWidgets('selectAll via controller updates view', (tester) async {
      writeUtf8(controller, 'hello world');
      await tester.pumpWidget(
        wrapInApp(controller: controller, autofocus: true),
      );
      await tester.pumpAndSettle();

      controller.selectAll();
      await tester.pump();

      expect(controller.hasSelection, isTrue);
    });

    testWidgets('selectAll shortcut selects content by default', (
      tester,
    ) async {
      writeUtf8(controller, 'hello world');
      await tester.pumpWidget(
        wrapInApp(controller: controller, autofocus: true),
      );
      await tester.pumpAndSettle();

      await sendSelectAllShortcut(tester);

      expect(controller.hasSelection, isTrue);
    });

    testWidgets('selectAll shortcut blocked when selectAllShortcut is false', (
      tester,
    ) async {
      writeUtf8(controller, 'hello world');
      await tester.pumpWidget(
        wrapInApp(
          controller: controller,
          autofocus: true,
          gestureSettings: const TerminalGestureSettings(
            selectAllShortcut: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await sendSelectAllShortcut(tester);

      expect(controller.hasSelection, isFalse);
    });

    testWidgets('typing clears selection when selectionClearOnTyping is true', (
      tester,
    ) async {
      writeUtf8(controller, 'hello world');
      await tester.pumpWidget(
        wrapInApp(controller: controller, autofocus: true),
      );
      await tester.pumpAndSettle();

      controller.selectRange(
        start: const Position(row: 0, col: 0),
        end: const Position(row: 0, col: 4),
      );
      expect(controller.hasSelection, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();

      expect(controller.hasSelection, isFalse);
    });

    testWidgets('shift+arrow extends existing selection', (tester) async {
      writeUtf8(controller, 'hello world');
      await tester.pumpWidget(
        wrapInApp(controller: controller, autofocus: true),
      );
      await tester.pumpAndSettle();

      controller.selectRange(
        start: const Position(row: 0, col: 0),
        end: const Position(row: 0, col: 4),
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      await tester.pump();

      expect(activeSelection(controller)!.endCol, 6);
    });

    group('virtual mods', () {
      testWidgets('focus loss clears virtual mods', (tester) async {
        await tester.pumpWidget(
          wrapInApp(controller: controller, autofocus: true),
        );
        await tester.pump();

        controller.toggleMod(const Mods.ctrl());
        expect(controller.virtualMods.hasCtrl, isTrue);

        controller.unfocus();
        await tester.pumpAndSettle();

        expect(controller.virtualMods, const Mods.none());
      });
    });

    group('mouse cursor', () {
      MouseCursor findMouseCursor(WidgetTester tester) {
        final mouseRegion = tester.widget<MouseRegion>(
          find.descendant(
            of: find.byType(TerminalView),
            matching: find.byType(MouseRegion),
          ),
        );
        return mouseRegion.cursor;
      }

      testWidgets('defaults to text cursor', (tester) async {
        await tester.pumpWidget(wrapInApp(controller: controller));
        expect(findMouseCursor(tester), SystemMouseCursors.text);
      });

      testWidgets('switches to basic when mouse tracking is active', (
        tester,
      ) async {
        await tester.pumpWidget(wrapInApp(controller: controller));
        expect(findMouseCursor(tester), SystemMouseCursors.text);

        writeUtf8(controller, '\x1b[?1000h');
        await tester.pumpAndSettle();

        expect(findMouseCursor(tester), SystemMouseCursors.basic);
      });

      testWidgets('hides cursor on key input when mouseAutoHide is onInput', (
        tester,
      ) async {
        await tester.pumpWidget(
          wrapInApp(controller: controller, autofocus: true),
        );
        await tester.pump();
        expect(findMouseCursor(tester), SystemMouseCursors.text);

        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await tester.pump();

        expect(findMouseCursor(tester), SystemMouseCursors.none);
      });

      testWidgets('shows cursor on mouse hover after hiding', (tester) async {
        await tester.pumpWidget(
          wrapInApp(controller: controller, autofocus: true),
        );
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await tester.pump();
        expect(findMouseCursor(tester), SystemMouseCursors.none);

        final center = tester.getCenter(find.byType(TerminalView));
        final gesture = await tester.createGesture(kind: .mouse);
        await gesture.addPointer(location: center);
        await gesture.moveTo(center + const Offset(10, 0));
        await tester.pump();

        expect(findMouseCursor(tester), isNot(SystemMouseCursors.none));
        await gesture.removePointer();
      });

      testWidgets('does not hide cursor when mouseAutoHide is never', (
        tester,
      ) async {
        await tester.pumpWidget(
          wrapInApp(
            controller: controller,
            autofocus: true,
            mouseAutoHide: .never,
          ),
        );
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await tester.pump();

        expect(findMouseCursor(tester), isNot(SystemMouseCursors.none));
      });
    });

    group('paste', () {
      Future<void> mockClipboard(WidgetTester tester, String text) async {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.getData') {
              return <String, dynamic>{'text': text};
            }
            return null;
          },
        );
      }

      Future<void> sendPasteShortcut(WidgetTester tester) async {
        switch (defaultTargetPlatform) {
          case TargetPlatform.macOS || TargetPlatform.iOS:
            await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
            await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
            await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
          case TargetPlatform.linux || TargetPlatform.fuchsia:
            await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
            await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
            await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
            await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
            await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
          case TargetPlatform.windows || TargetPlatform.android:
            await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
            await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
            await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
        }
        await tester.pump();
      }

      tearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      testWidgets('paste shortcut sends clipboard text to onOutput', (
        tester,
      ) async {
        await mockClipboard(tester, 'pasted');
        final output = <Uint8List>[];
        controller.onOutput = output.add;

        await tester.pumpWidget(
          wrapInApp(controller: controller, autofocus: true),
        );
        await tester.pump();

        await sendPasteShortcut(tester);
        await tester.pumpAndSettle();

        final pasted = output.where((b) => utf8.decode(b).contains('pasted'));
        expect(pasted, isNotEmpty);
      });

      testWidgets('paste wraps with bracketed paste when mode is active', (
        tester,
      ) async {
        writeUtf8(controller, '\x1b[?2004h');
        await mockClipboard(tester, 'hello');
        final output = <Uint8List>[];
        controller.onOutput = output.add;

        await tester.pumpWidget(
          wrapInApp(controller: controller, autofocus: true),
        );
        await tester.pump();

        await sendPasteShortcut(tester);
        await tester.pumpAndSettle();

        final pasted = output
            .map((b) => utf8.decode(b))
            .where((s) => s.contains('hello'));
        expect(pasted, isNotEmpty);
        expect(pasted.first, contains('\x1b[200~'));
        expect(pasted.first, contains('\x1b[201~'));
      });

      testWidgets('paste with empty clipboard produces no output', (
        tester,
      ) async {
        await mockClipboard(tester, '');
        final output = <Uint8List>[];
        controller.onOutput = output.add;

        await tester.pumpWidget(
          wrapInApp(controller: controller, autofocus: true),
        );
        await tester.pump();

        await sendPasteShortcut(tester);
        await tester.pumpAndSettle();

        final pasted = output.where(
          (b) => utf8.decode(b).contains('\x1b[200~'),
        );
        expect(pasted, isEmpty);
      });
    });

    group('mouse selection', () {
      Future<TestGesture> mouseDown(WidgetTester tester, Offset pos) {
        return tester.startGesture(pos, kind: PointerDeviceKind.mouse);
      }

      Future<void> tapMouse(
        WidgetTester tester,
        Offset position, {
        int count = 1,
      }) async {
        for (var i = 0; i < count; i++) {
          final gesture = await mouseDown(tester, position);
          await gesture.up();
        }
      }

      testWidgets('double click selects word', (tester) async {
        writeUtf8(controller, 'hello world');
        await tester.pumpWidget(
          wrapInApp(controller: controller, autofocus: true),
        );
        await tester.pumpAndSettle();

        final topLeft = tester.getTopLeft(find.byType(TerminalView));
        final clickPos = topLeft + const Offset(20, 8);

        await tapMouse(tester, clickPos, count: 2);
        await tester.pump();

        expect(controller.hasSelection, isTrue);
        expect(controller.selectedText(), contains('hello'));
      });

      testWidgets('triple click selects entire line', (tester) async {
        writeUtf8(controller, 'hello world');
        await tester.pumpWidget(
          wrapInApp(controller: controller, autofocus: true),
        );
        await tester.pumpAndSettle();

        final topLeft = tester.getTopLeft(find.byType(TerminalView));
        final clickPos = topLeft + const Offset(20, 8);

        await tapMouse(tester, clickPos, count: 3);
        await tester.pump();

        final sel = activeSelection(controller);
        expect(sel, isNotNull);
        expect(sel!.startCol, 0);
        expect(controller.selectedText().length, greaterThan('hello'.length));
      });

      testWidgets('mouse drag creates selection', (tester) async {
        writeUtf8(controller, 'hello world');
        await tester.pumpWidget(
          wrapInApp(controller: controller, autofocus: true),
        );
        await tester.pumpAndSettle();

        final topLeft = tester.getTopLeft(find.byType(TerminalView));
        final start = topLeft + const Offset(10, 8);
        final end = topLeft + const Offset(100, 8);

        final gesture = await mouseDown(tester, start);
        await gesture.moveTo(end);
        await gesture.up();
        await tester.pump();

        expect(controller.hasSelection, isTrue);
        expect(controller.selectedText(), isNotEmpty);
      });
    });

    group('padding', () {
      testWidgets('padding reduces reported grid size', (tester) async {
        final cols = <int>[];
        final rows = <int>[];
        controller.onResize = (c, r) {
          cols.add(c);
          rows.add(r);
        };

        await tester.pumpWidget(wrapInApp(controller: controller));
        await tester.pumpAndSettle();
        final noPaddingCols = cols.last;
        final noPaddingRows = rows.last;

        cols.clear();
        rows.clear();
        await tester.pumpWidget(
          wrapInApp(controller: controller, padding: const EdgeInsets.all(20)),
        );
        await tester.pumpAndSettle();

        expect(cols.last, lessThan(noPaddingCols));
        expect(rows.last, lessThan(noPaddingRows));
      });
    });

    group('transparent background', () {
      testWidgets('opaque theme paints ColoredBox with theme.background', (
        tester,
      ) async {
        final theme = TerminalTheme.dark();
        await tester.pumpWidget(
          wrapInApp(controller: controller, theme: theme),
        );
        await tester.pumpAndSettle();

        final box = tester.widget<ColoredBox>(
          find.descendant(
            of: find.byType(TerminalView),
            matching: find.byType(ColoredBox),
          ),
        );
        expect(box.color, theme.background);
      });

      testWidgets('backgroundOpacity < 1 scales backdrop alpha to match', (
        tester,
      ) async {
        final theme = TerminalTheme.dark().copyWith(backgroundOpacity: 0.5);
        await tester.pumpWidget(
          wrapInApp(controller: controller, theme: theme),
        );
        await tester.pumpAndSettle();

        final box = tester.widget<ColoredBox>(
          find.descendant(
            of: find.byType(TerminalView),
            matching: find.byType(ColoredBox),
          ),
        );
        expect(box.color.a, closeTo(0.5, 0.01));
        expect(box.color.r, theme.background.r);
        expect(box.color.g, theme.background.g);
        expect(box.color.b, theme.background.b);
      });
    });
  });
}
