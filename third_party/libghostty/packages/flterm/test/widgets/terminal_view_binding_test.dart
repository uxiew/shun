@Tags(['ffi'])
library;

import 'dart:convert';

import 'package:flterm/src/foundation.dart';
import 'package:flterm/src/widgets/terminal_controller_impl.dart';
import 'package:flterm/src/widgets/terminal_view_binding.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart' hide KeyEvent;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TerminalViewBinding', () {
    late TerminalViewBinding binding;
    late TerminalControllerImpl controller;

    setUp(() {
      controller = TerminalControllerImpl();
      binding = controller as TerminalViewBinding;
    });

    tearDown(() => controller.dispose());

    void writeUtf8(Terminal terminal, String text) {
      terminal.write(Uint8List.fromList(utf8.encode(text)));
    }

    void writeNumberedLines(TerminalControllerImpl target, int count) {
      for (var i = 0; i < count; i++) {
        writeUtf8(target.terminal, 'line $i\r\n');
      }
    }

    group('attach and detach', () {
      test('detaches after attach', () {
        final focusNode = FocusNode();
        final scrollController = ScrollController();
        addTearDown(focusNode.dispose);
        addTearDown(scrollController.dispose);

        binding.attach(focusNode, scrollController, viewId: 0);

        expect(binding.detach, returnsNormally);
      });

      test('re-attach replaces previous focus node', () {
        final node1 = FocusNode();
        final node2 = FocusNode();
        final scrollController1 = ScrollController();
        final scrollController2 = ScrollController();
        addTearDown(node1.dispose);
        addTearDown(node2.dispose);
        addTearDown(scrollController1.dispose);
        addTearDown(scrollController2.dispose);

        binding.attach(node1, scrollController1, viewId: 0);

        expect(
          () => binding.attach(node2, scrollController2, viewId: 0),
          returnsNormally,
        );
      });
    });

    group('handleResize', () {
      test('fires onResize callback with correct dimensions', () {
        int? reportedCols;
        int? reportedRows;
        controller.onResize = (cols, rows) {
          reportedCols = cols;
          reportedRows = rows;
        };

        binding.handleResize(
          cols: 120,
          rows: 40,
          metrics: const CellMetrics(
            cellWidth: 8,
            cellHeight: 16,
            baseline: 12,
          ),
          padding: EdgeInsets.zero,
          devicePixelRatio: 1.0,
        );

        expect(reportedCols, 120);
        expect(reportedRows, 40);
      });
    });

    group('handleScroll', () {
      test('emits cursor key sequences on alternate screen', () {
        writeUtf8(controller.terminal, '\x1b[?1049h');
        final output = <Uint8List>[];
        controller.onOutput = output.add;

        binding.handleScroll(-3);

        expect(output, hasLength(1));
        expect(output.first.length, greaterThan(0));
      });

      test('emits no output on primary screen', () {
        final output = <Uint8List>[];
        controller.onOutput = output.add;

        binding.handleScroll(-3);

        expect(output, isEmpty);
      });

      test('emits no output for zero lines', () {
        writeUtf8(controller.terminal, '\x1b[?1049h');
        final output = <Uint8List>[];
        controller.onOutput = output.add;

        binding.handleScroll(0);

        expect(output, isEmpty);
      });
    });

    group('selection drag', () {
      test('updates terminal selection', () {
        final custom = TerminalControllerImpl(
          config: const TerminalConfig(cols: 20, rows: 5),
        );
        addTearDown(custom.dispose);
        final customBinding = custom as TerminalViewBinding;

        custom.terminal.write(Uint8List.fromList(utf8.encode('AB日CD')));
        customBinding.handleResize(
          cols: 20,
          rows: 5,
          metrics: const CellMetrics(
            cellWidth: 8,
            cellHeight: 16,
            baseline: 12,
          ),
          padding: EdgeInsets.zero,
          devicePixelRatio: 1.0,
        );

        customBinding.handleSelectionPress(
          cell: const Position(row: 0, col: 2),
          localPosition: const Offset(16, 0),
          settings: const TerminalGestureSettings(),
        );
        customBinding.updateSelectionDrag(
          cell: const Position(row: 0, col: 4),
          localPosition: const Offset(32, 0),
          rectangle: false,
        );

        expect(custom.selectedText(), '日');
      });
    });

    group('handleKeyEvent', () {
      test('returns handled and emits output for printable key', () {
        final output = <Uint8List>[];
        controller.onOutput = output.add;

        final result = binding.handleKeyEvent(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.keyA,
            logicalKey: LogicalKeyboardKey.keyA,
            character: 'a',
            timeStamp: Duration.zero,
          ),
        );

        expect(result, KeyEventResult.handled);
        expect(output, isNotEmpty);
      });

      test('returns ignored for key release', () {
        final result = binding.handleKeyEvent(
          const KeyUpEvent(
            physicalKey: PhysicalKeyboardKey.keyA,
            logicalKey: LogicalKeyboardKey.keyA,
            timeStamp: Duration.zero,
          ),
        );

        expect(result, KeyEventResult.ignored);
      });

      test('clears selection on typing when enabled', () {
        controller.selectRange(
          start: const Position(row: 0, col: 0),
          end: const Position(row: 0, col: 4),
        );
        controller.onOutput = (_) {};

        binding.handleKeyEvent(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.keyA,
            logicalKey: LogicalKeyboardKey.keyA,
            character: 'a',
            timeStamp: Duration.zero,
          ),
        );

        expect(controller.hasSelection, isFalse);
      });

      test('scrolls to bottom on input', () {
        final custom = TerminalControllerImpl(
          config: const TerminalConfig(cols: 20, rows: 3),
        );
        addTearDown(custom.dispose);
        final sc = ScrollController();
        final focusNode = FocusNode();
        addTearDown(focusNode.dispose);
        addTearDown(sc.dispose);
        final customBinding = custom as TerminalViewBinding;
        customBinding.attach(focusNode, sc, viewId: 0);

        writeNumberedLines(custom, 10);
        custom.terminal.scrollViewport(-5);
        expect(
          custom.terminal.scrollbar.offset,
          lessThan(custom.scrollbackRows),
        );

        custom.onOutput = (_) {};
        customBinding.handleKeyEvent(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.keyA,
            logicalKey: LogicalKeyboardKey.keyA,
            character: 'a',
            timeStamp: Duration.zero,
          ),
        );

        expect(custom.terminal.scrollbar.offset, custom.scrollbackRows);
      });
    });

    group('scrollToBottom', () {
      test('restores viewport to bottom after scrolling up', () {
        final custom = TerminalControllerImpl(
          config: const TerminalConfig(cols: 20, rows: 3),
        );
        addTearDown(custom.dispose);

        writeNumberedLines(custom, 10);
        final bottomOffset = custom.terminal.scrollbar.offset;

        custom.terminal.scrollViewport(-5);
        expect(custom.terminal.scrollbar.offset, isNot(bottomOffset));

        custom.scrollToBottom();

        expect(custom.terminal.scrollbar.offset, bottomOffset);
      });
    });

    group('handleMouseEvent', () {
      test('emits encoded output when tracking is enabled', () {
        writeUtf8(controller.terminal, '\x1b[?1000h');
        binding.handleResize(
          cols: 80,
          rows: 24,
          metrics: const CellMetrics(
            cellWidth: 8,
            cellHeight: 16,
            baseline: 12,
          ),
          padding: EdgeInsets.zero,
          devicePixelRatio: 1.0,
        );

        final output = <Uint8List>[];
        controller.onOutput = output.add;

        binding.handleMouseEvent((
          action: .press,
          button: .left,
          pixelX: 10.0,
          pixelY: 10.0,
        ));

        expect(output, isNotEmpty);
      });

      test('does not emit when tracking is off', () {
        final output = <Uint8List>[];
        controller.onOutput = output.add;

        binding.handleMouseEvent((
          action: .press,
          button: .left,
          pixelX: 10.0,
          pixelY: 10.0,
        ));

        expect(output, isEmpty);
      });

      test('scales pixel coordinates by devicePixelRatio', () {
        writeUtf8(controller.terminal, '\x1b[?1000h');
        binding.handleResize(
          cols: 80,
          rows: 24,
          metrics: const CellMetrics(
            cellWidth: 8,
            cellHeight: 16,
            baseline: 12,
          ),
          padding: EdgeInsets.zero,
          devicePixelRatio: 2.0,
        );

        final output = <Uint8List>[];
        controller.onOutput = output.add;

        binding.handleMouseEvent((
          action: .press,
          button: .left,
          pixelX: 8.0,
          pixelY: 16.0,
        ));

        expect(output, hasLength(1));
        expect(output.single, [
          0x1b,
          0x5b,
          0x4d,
          ' '.codeUnitAt(0),
          '!'.codeUnitAt(0) + 1,
          '!'.codeUnitAt(0) + 1,
        ]);
      });
    });

    group('mouseTracking', () {
      test('reflects mode changes', () {
        expect(binding.mouseTracking, MouseTracking.none);

        writeUtf8(controller.terminal, '\x1b[?1000h');

        expect(binding.mouseTracking, MouseTracking.normal);
      });
    });

    group('cursorBlinks', () {
      test('false without focus', () {
        expect(binding.cursorBlinks, isFalse);
      });

      test('stays false without a widget focus context', () {
        final focusNode = FocusNode();
        final sc = ScrollController();
        addTearDown(focusNode.dispose);
        addTearDown(sc.dispose);
        binding.attach(focusNode, sc, viewId: 0);

        expect(binding.cursorBlinks, isFalse);
      });

      testWidgets('uses libghostty viewport-active state on primary screen', (
        tester,
      ) async {
        controller.dispose();
        controller = TerminalControllerImpl(
          config: const TerminalConfig(cols: 20, rows: 2),
        );
        binding = controller as TerminalViewBinding;
        final focusNode = FocusNode();
        final sc = ScrollController();
        addTearDown(focusNode.dispose);
        addTearDown(sc.dispose);
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Focus(focusNode: focusNode, child: const SizedBox()),
          ),
        );
        binding.attach(focusNode, sc, viewId: 0);
        focusNode.requestFocus();
        await tester.pump();

        writeNumberedLines(controller, 10);
        controller.terminal.scrollViewport(-1);

        expect(controller.hasFocus, isTrue);
        expect(controller.scrollbackRows, greaterThan(0));
        expect(controller.terminal.isViewportActive, isFalse);
        expect(binding.cursorBlinks, isFalse);
      });

      testWidgets('respects cursorBlink config before terminal changes', (
        tester,
      ) async {
        controller.dispose();
        controller = TerminalControllerImpl(
          config: const TerminalConfig(cursorBlink: false),
        );
        binding = controller as TerminalViewBinding;
        final focusNode = FocusNode();
        final sc = ScrollController();
        addTearDown(focusNode.dispose);
        addTearDown(sc.dispose);
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Focus(focusNode: focusNode, child: const SizedBox()),
          ),
        );
        binding.attach(focusNode, sc, viewId: 0);
        focusNode.requestFocus();
        await tester.pump();

        expect(controller.hasFocus, isTrue);
        expect(binding.cursorBlinks, isFalse);
      });
    });

    group('paste', () {
      test('scrolls to bottom on primary screen', () {
        final custom = TerminalControllerImpl(
          config: const TerminalConfig(cols: 20, rows: 3),
        );
        addTearDown(custom.dispose);

        writeNumberedLines(custom, 10);
        custom.terminal.scrollViewport(-5);
        expect(
          custom.terminal.scrollbar.offset,
          lessThan(custom.scrollbackRows),
        );

        custom.onOutput = (_) {};
        custom.paste('hello');

        expect(custom.terminal.scrollbar.offset, custom.scrollbackRows);
      });
    });

    group('primary screen restore', () {
      test('re-applies configured modes', () {
        final focusNode = FocusNode();
        final sc = ScrollController();
        addTearDown(focusNode.dispose);
        addTearDown(sc.dispose);
        binding.attach(focusNode, sc, viewId: 0);

        writeUtf8(controller.terminal, '\x1b[?1049h');
        writeUtf8(controller.terminal, '\x1b[?12l');

        writeUtf8(controller.terminal, '\x1b[?1049l');

        expect(
          controller.terminal.modeGet(const TerminalMode.cursorBlinking()),
          isTrue,
        );
      });
    });
  });
}
