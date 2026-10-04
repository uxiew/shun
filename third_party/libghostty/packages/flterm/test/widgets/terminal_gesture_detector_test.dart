@Tags(['ffi'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/src/foundation.dart';
import 'package:flterm/src/links/link_settings.dart';
import 'package:flterm/src/widgets.dart';
import 'package:flterm/src/widgets/link_interaction.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart'
    show
        Mods,
        MouseTracking,
        Position,
        Selection,
        SelectionGestureBehaviors,
        Terminal;

extension _SelectionEdges on Selection {
  Position get _startPoint => start.positionIn(.viewport)!;

  Position get _endPoint => end.positionIn(.viewport)!;

  bool get _forward {
    final start = _startPoint;
    final end = _endPoint;
    return start.row != end.row ? start.row < end.row : start.col <= end.col;
  }

  int get startRow => _startPoint.row;

  int get startCol => _forward ? _startPoint.col : _startPoint.col + 1;

  int get endRow => _endPoint.row;

  int get endCol => _forward ? _endPoint.col + 1 : _endPoint.col;

  TerminalSelectionShape get mode {
    return rectangle
        ? TerminalSelectionShape.rectangle
        : TerminalSelectionShape.normal;
  }
}

void main() {
  group('TerminalGestureDetector', () {
    const defaultMetrics = CellMetrics(
      cellWidth: 8,
      cellHeight: 16,
      baseline: 12,
    );
    final enableNormalMouse = Uint8List.fromList(utf8.encode('\x1b[?1000h'));
    final enableX10Mouse = Uint8List.fromList(utf8.encode('\x1b[?9h'));

    TerminalViewBinding bindingFor(TerminalController controller) {
      return controller as TerminalViewBinding;
    }

    Terminal terminalFor(TerminalController controller) {
      return bindingFor(controller).terminal;
    }

    void writeToTerminal(TerminalController controller, String text) {
      terminalFor(controller).write(Uint8List.fromList(utf8.encode(text)));
    }

    Widget buildHandler({
      required TerminalController controller,
      CellMetrics metrics = defaultMetrics,
      TerminalGestureSettings gestureSettings = const TerminalGestureSettings(),
      LinkInteraction? links,
      ValueChanged<ActivatedLink>? onLinkActivate,
      ScrollController? scrollController,
      int visibleRows = 24,
    }) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: TerminalGestureDetector(
            binding: controller as TerminalViewBinding,
            metrics: metrics,
            links: links ?? LinkInteraction(),
            onLinkActivate: onLinkActivate,
            settings: gestureSettings,
            scrollController: scrollController,
            visibleRows: visibleRows,
            child: const SizedBox(width: 640, height: 384),
          ),
        ),
      );
    }

    LinkInteraction linkInteractionFor(TerminalController controller) {
      final links = LinkInteraction();
      links.update(
        context: LinkContext(
          terminal: terminalFor(controller),
          rows: 24,
          cols: 80,
          cwd: null,
        ),
        settings: LinkSettings(modifier: .none, onActivate: (_) {}),
        idleStyle: const HyperlinkStyle(),
      );
      return links;
    }

    void enableMouseTracking(
      TerminalController controller, {
      MouseTracking mode = .normal,
    }) {
      final seq = switch (mode) {
        .normal => enableNormalMouse,
        .x10 => enableX10Mouse,
        _ => enableNormalMouse,
      };
      final viewBinding = bindingFor(controller);
      viewBinding.terminal.write(seq);
      viewBinding.handleResize(
        cols: 80,
        rows: 24,
        metrics: defaultMetrics,
        padding: EdgeInsets.zero,
        devicePixelRatio: 1.0,
      );
    }

    Future<TestGesture> mouseDown(
      WidgetTester tester,
      Offset pos, {
      int buttons = kPrimaryButton,
    }) {
      return tester.startGesture(pos, kind: .mouse, buttons: buttons);
    }

    late TerminalController controller;

    setUp(() => controller = TerminalController());

    tearDown(() => controller.dispose());

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

    testWidgets('tap leaves selection empty', (tester) async {
      await tester.pumpWidget(buildHandler(controller: controller));

      await tapMouse(tester, const Offset(40, 16));

      expect(terminalFor(controller).selection, isNull);
    });

    testWidgets('tap activates a link without starting selection', (
      tester,
    ) async {
      final links = <ActivatedLink>[];
      writeToTerminal(controller, 'https://example.test');
      final linkInteraction = linkInteractionFor(controller);

      await tester.pumpWidget(
        buildHandler(
          controller: controller,
          links: linkInteraction,
          onLinkActivate: links.add,
        ),
      );

      await tapMouse(tester, const Offset(8, 0));

      expect(links, hasLength(1));
      expect(links.single.text, 'https://example.test');
      expect(terminalFor(controller).selection, isNull);
    });

    testWidgets('tap up activates the press candidate after invalidation', (
      tester,
    ) async {
      final links = <ActivatedLink>[];
      writeToTerminal(controller, 'https://example.test');
      final linkInteraction = linkInteractionFor(controller);

      await tester.pumpWidget(
        buildHandler(
          controller: controller,
          links: linkInteraction,
          onLinkActivate: links.add,
        ),
      );

      final gesture = await mouseDown(tester, const Offset(8, 0));
      linkInteraction.invalidateContent();
      await gesture.up();

      expect(links.single.text, 'https://example.test');
    });

    testWidgets('drag cancels claimed link tap', (tester) async {
      final links = <ActivatedLink>[];
      writeToTerminal(controller, 'https://example.test');
      final linkInteraction = linkInteractionFor(controller);

      await tester.pumpWidget(
        buildHandler(
          controller: controller,
          links: linkInteraction,
          onLinkActivate: links.add,
        ),
      );

      final gesture = await mouseDown(tester, const Offset(8, 0));
      await tester.pump(kPressTimeout);
      await gesture.moveTo(const Offset(80, 32));
      await gesture.up();

      expect(links, isEmpty);
    });

    testWidgets('mouse tracking takes priority over link activation', (
      tester,
    ) async {
      final links = <ActivatedLink>[];
      writeToTerminal(controller, 'https://example.test');
      final linkInteraction = linkInteractionFor(controller);
      enableMouseTracking(controller);

      await tester.pumpWidget(
        buildHandler(
          controller: controller,
          links: linkInteraction,
          onLinkActivate: links.add,
        ),
      );

      await tapMouse(tester, const Offset(8, 0));

      expect(links, isEmpty);
    });

    testWidgets('drag creates selection with correct cells', (tester) async {
      await tester.pumpWidget(buildHandler(controller: controller));

      final gesture = await mouseDown(tester, const Offset(8, 0));
      await gesture.moveTo(const Offset(40, 16));
      await gesture.up();

      final selection = terminalFor(controller).selection!;
      expect(selection.startRow, 0);
      expect(selection.startCol, 1);
      expect(selection.endRow, 1);
      expect(selection.endCol, 5);
      expect(selection.mode, TerminalSelectionShape.normal);
    });

    testWidgets('mouse up ends selection drag', (tester) async {
      await tester.pumpWidget(buildHandler(controller: controller));

      final gesture = await mouseDown(tester, Offset.zero);
      await gesture.moveTo(const Offset(80, 32));
      await gesture.up();

      final selection = terminalFor(controller).selection!;
      expect(selection.startRow, 0);
      expect(selection.endRow, 2);
    });

    testWidgets('drag to same cell does not change selection', (tester) async {
      await tester.pumpWidget(buildHandler(controller: controller));

      final gesture = await mouseDown(tester, const Offset(8, 0));
      await gesture.moveTo(const Offset(40, 16));
      final selAfterFirst = terminalFor(controller).selection;

      await gesture.moveTo(const Offset(41, 17));
      final selAfterSecond = terminalFor(controller).selection;

      expect(selAfterFirst, selAfterSecond);

      await gesture.up();
    });

    testWidgets('double click selects word', (tester) async {
      writeToTerminal(controller, 'hello world');

      await tester.pumpWidget(buildHandler(controller: controller));

      await tapMouse(tester, const Offset(8, 0), count: 2);

      final selection = terminalFor(controller).selection!;
      expect(selection.startRow, 0);
      expect(selection.startCol, 0);
      expect(selection.endCol, 5);
    });

    testWidgets('double click on second word selects it', (tester) async {
      writeToTerminal(controller, 'hello world');

      await tester.pumpWidget(buildHandler(controller: controller));

      await tapMouse(tester, const Offset(56, 0), count: 2);

      final selection = terminalFor(controller).selection!;
      expect(selection.startCol, 6);
      expect(selection.endCol, 11);
    });

    testWidgets('double click uses configured word boundaries', (tester) async {
      final boundaryController = TerminalController();
      addTearDown(boundaryController.dispose);
      writeToTerminal(boundaryController, 'hello_world');

      await tester.pumpWidget(
        buildHandler(
          controller: boundaryController,
          gestureSettings: const TerminalGestureSettings(wordBoundaries: '_'),
        ),
      );

      await tapMouse(tester, const Offset(64, 0), count: 2);

      final selection = terminalFor(boundaryController).selection!;
      expect(selection.startCol, 6);
      expect(selection.endCol, 11);
    });

    testWidgets('triple click selects line content only', (tester) async {
      writeToTerminal(controller, 'Hello');

      await tester.pumpWidget(buildHandler(controller: controller));

      await tapMouse(tester, const Offset(40, 0), count: 3);

      final selection = terminalFor(controller).selection!;
      expect(selection.startCol, 0);
      expect(selection.endCol, 5);
    });

    testWidgets('triple click on wrapped line selects full terminal line', (
      tester,
    ) async {
      final narrowController = TerminalController(
        config: const TerminalConfig(cols: 10, rows: 5),
      );
      addTearDown(narrowController.dispose);

      writeToTerminal(narrowController, 'ABCDEFGHIJKLMNO');

      await tester.pumpWidget(buildHandler(controller: narrowController));

      await tapMouse(tester, const Offset(8, 16), count: 3);

      final selection = terminalFor(narrowController).selection!;
      expect(selection.startRow, 0);
      expect(selection.startCol, 0);
      expect(selection.endRow, 1);
      expect(selection.endCol, 5);
    });

    testWidgets('triple click with fullRow mode selects entire row width', (
      tester,
    ) async {
      final wideController = TerminalController(
        config: const TerminalConfig(cols: 20, rows: 5),
      );
      addTearDown(wideController.dispose);

      writeToTerminal(wideController, 'Hello');

      await tester.pumpWidget(
        buildHandler(
          controller: wideController,
          gestureSettings: const TerminalGestureSettings(lineSelectMode: .full),
        ),
      );

      await tapMouse(tester, const Offset(8, 0), count: 3);

      final selection = terminalFor(wideController).selection!;
      expect(selection.endCol, 20);
    });

    testWidgets('tap counting resets on distant clicks', (tester) async {
      await tester.pumpWidget(buildHandler(controller: controller));

      await tapMouse(tester, const Offset(40, 16));
      await tapMouse(tester, const Offset(200, 200));

      expect(terminalFor(controller).selection, isNull);
    });

    testWidgets('touch long press starts normal selection by default', (
      tester,
    ) async {
      await tester.pumpWidget(buildHandler(controller: controller));

      final gesture = await tester.startGesture(const Offset(40, 16));

      await tester.pump(const Duration(milliseconds: 550));

      expect(terminalFor(controller).selection, isNull);

      await gesture.moveTo(const Offset(80, 32));
      final sel = terminalFor(controller).selection!;
      expect(sel.mode, TerminalSelectionShape.normal);

      await gesture.up();
    });

    testWidgets('touch move cancels long press if distance exceeds threshold', (
      tester,
    ) async {
      await tester.pumpWidget(buildHandler(controller: controller));

      final gesture = await tester.startGesture(const Offset(40, 16));
      await gesture.moveTo(const Offset(80, 16));

      await tester.pump(const Duration(milliseconds: 550));

      await gesture.moveTo(const Offset(120, 16));
      expect(terminalFor(controller).selection, isNull);

      await gesture.up();
    });

    testWidgets('new click clears existing selection', (tester) async {
      await tester.pumpWidget(buildHandler(controller: controller));

      final gesture = await mouseDown(tester, Offset.zero);
      await gesture.moveTo(const Offset(80, 32));
      await gesture.up();

      expect(terminalFor(controller).selection, isNotNull);

      final gesture2 = await mouseDown(tester, const Offset(40, 16));
      await gesture2.up();

      expect(terminalFor(controller).selection, isNull);
    });

    testWidgets('click without existing selection keeps selection null', (
      tester,
    ) async {
      await tester.pumpWidget(buildHandler(controller: controller));

      final gesture = await mouseDown(tester, const Offset(40, 16));
      await gesture.up();

      expect(terminalFor(controller).selection, isNull);
    });

    group('gesture settings', () {
      testWidgets('dragSelection false prevents drag selection', (
        tester,
      ) async {
        await tester.pumpWidget(
          buildHandler(
            controller: controller,
            gestureSettings: const TerminalGestureSettings(
              dragSelection: false,
            ),
          ),
        );

        final gesture = await mouseDown(tester, const Offset(8, 0));
        await gesture.moveTo(const Offset(80, 32));
        await gesture.up();

        expect(terminalFor(controller).selection, isNull);
      });

      testWidgets('longPressSelection false cancels press selection', (
        tester,
      ) async {
        writeToTerminal(controller, 'hello world');

        await tester.pumpWidget(
          buildHandler(
            controller: controller,
            gestureSettings: const TerminalGestureSettings(
              longPressSelection: false,
              selectionBehaviors: SelectionGestureBehaviors(
                singleClick: .line,
                doubleClick: .word,
                tripleClick: .line,
              ),
            ),
          ),
        );

        final gesture = await tester.startGesture(const Offset(40, 16));
        await tester.pump(const Duration(milliseconds: 550));
        await gesture.moveTo(const Offset(80, 32));
        await gesture.up();

        expect(terminalFor(controller).selection, isNull);
      });

      testWidgets('single click uses configured line behavior', (tester) async {
        writeToTerminal(controller, 'hello world');

        await tester.pumpWidget(
          buildHandler(
            controller: controller,
            gestureSettings: const TerminalGestureSettings(
              selectionBehaviors: SelectionGestureBehaviors(
                singleClick: .line,
                doubleClick: .word,
                tripleClick: .line,
              ),
            ),
          ),
        );

        await tapMouse(tester, const Offset(8, 0));

        final selection = terminalFor(controller).selection!;
        expect(selection.startCol, 0);
        expect(selection.endCol, 11);
      });

      testWidgets('double click uses configured line behavior', (tester) async {
        writeToTerminal(controller, 'hello world');

        await tester.pumpWidget(
          buildHandler(
            controller: controller,
            gestureSettings: const TerminalGestureSettings(
              selectionBehaviors: SelectionGestureBehaviors(
                singleClick: .cell,
                doubleClick: .line,
                tripleClick: .line,
              ),
            ),
          ),
        );

        await tapMouse(tester, const Offset(8, 0), count: 2);

        final selection = terminalFor(controller).selection!;
        expect(selection.startCol, 0);
        expect(selection.endCol, 11);
      });

      testWidgets('triple click uses configured word behavior', (tester) async {
        writeToTerminal(controller, 'hello world');

        await tester.pumpWidget(
          buildHandler(
            controller: controller,
            gestureSettings: const TerminalGestureSettings(
              selectionBehaviors: SelectionGestureBehaviors(
                singleClick: .cell,
                doubleClick: .line,
                tripleClick: .word,
              ),
            ),
          ),
        );

        await tapMouse(tester, const Offset(56, 0), count: 3);

        final selection = terminalFor(controller).selection!;
        expect(selection.startCol, 6);
        expect(selection.endCol, 11);
      });

      testWidgets('dragSelection false keeps press selection enabled', (
        tester,
      ) async {
        writeToTerminal(controller, 'hello world');

        await tester.pumpWidget(
          buildHandler(
            controller: controller,
            gestureSettings: const TerminalGestureSettings(
              dragSelection: false,
            ),
          ),
        );

        final gesture = await mouseDown(tester, const Offset(8, 0));
        await gesture.moveTo(const Offset(80, 32));
        await gesture.up();
        expect(terminalFor(controller).selection, isNull);

        await tapMouse(tester, const Offset(8, 0), count: 2);

        final selection = terminalFor(controller).selection!;
        expect(selection.startCol, 0);
        expect(selection.endCol, 5);
      });

      testWidgets('double click cell behavior leaves selection empty', (
        tester,
      ) async {
        writeToTerminal(controller, 'hello world');

        await tester.pumpWidget(
          buildHandler(
            controller: controller,
            gestureSettings: const TerminalGestureSettings(
              selectionBehaviors: SelectionGestureBehaviors(
                singleClick: .cell,
                doubleClick: .cell,
                tripleClick: .line,
              ),
            ),
          ),
        );

        await tapMouse(tester, const Offset(8, 0), count: 2);

        expect(terminalFor(controller).selection, isNull);
      });

      testWidgets('triple click cell behavior leaves selection empty', (
        tester,
      ) async {
        writeToTerminal(controller, 'hello world');

        await tester.pumpWidget(
          buildHandler(
            controller: controller,
            gestureSettings: const TerminalGestureSettings(
              selectionBehaviors: SelectionGestureBehaviors(
                singleClick: .cell,
                doubleClick: .word,
                tripleClick: .cell,
              ),
            ),
          ),
        );

        await tapMouse(tester, const Offset(8, 0), count: 3);

        expect(terminalFor(controller).selection, isNull);
      });

      testWidgets('longPressSelectionShape block uses block mode', (
        tester,
      ) async {
        await tester.pumpWidget(
          buildHandler(
            controller: controller,
            gestureSettings: const TerminalGestureSettings(
              longPressSelectionShape: .rectangle,
            ),
          ),
        );

        final gesture = await tester.startGesture(const Offset(40, 16));
        await tester.pump(const Duration(milliseconds: 550));
        await gesture.moveTo(const Offset(80, 32));
        await gesture.up();

        final selection = terminalFor(controller).selection!;
        expect(selection.mode, TerminalSelectionShape.rectangle);
      });

      testWidgets(
        'disabled selection affordances still allow mouse tracking output',
        (tester) async {
          enableMouseTracking(controller);

          await tester.pumpWidget(
            buildHandler(
              controller: controller,
              gestureSettings: const TerminalGestureSettings(
                dragSelection: false,
                longPressSelection: false,
                selectAllShortcut: false,
              ),
            ),
          );

          final events = <Uint8List>[];
          controller.onOutput = events.add;

          final gesture = await mouseDown(tester, const Offset(24, 16));
          await gesture.up();

          expect(events, isNotEmpty);
        },
      );
    });

    group('virtual mods', () {
      testWidgets('virtual alt triggers block selection on drag', (
        tester,
      ) async {
        controller.toggleMod(const Mods.alt());

        await tester.pumpWidget(buildHandler(controller: controller));

        final gesture = await mouseDown(tester, const Offset(8, 0));
        await gesture.moveTo(const Offset(80, 32));
        await gesture.up();

        final selection = terminalFor(controller).selection!;
        expect(selection.mode, TerminalSelectionShape.rectangle);
      });

      testWidgets('virtual alt triggers block selection on long press', (
        tester,
      ) async {
        controller.toggleMod(const Mods.alt());

        await tester.pumpWidget(buildHandler(controller: controller));

        final gesture = await tester.startGesture(const Offset(40, 16));
        await tester.pump(const Duration(milliseconds: 550));
        await gesture.moveTo(const Offset(80, 32));
        await gesture.up();

        final selection = terminalFor(controller).selection!;
        expect(selection.mode, TerminalSelectionShape.rectangle);
      });

      testWidgets('toggling alt mid-drag switches selection mode', (
        tester,
      ) async {
        await tester.pumpWidget(buildHandler(controller: controller));

        final gesture = await mouseDown(tester, const Offset(8, 0));
        await gesture.moveTo(const Offset(80, 32));
        expect(
          terminalFor(controller).selection!.mode,
          TerminalSelectionShape.normal,
        );

        controller.toggleMod(const Mods.alt());
        await gesture.moveTo(const Offset(80, 48));
        expect(
          terminalFor(controller).selection!.mode,
          TerminalSelectionShape.rectangle,
        );

        controller.toggleMod(const Mods.alt());
        await gesture.moveTo(const Offset(80, 64));
        expect(
          terminalFor(controller).selection!.mode,
          TerminalSelectionShape.normal,
        );

        await gesture.up();
      });

      testWidgets('virtual shift bypasses mouse tracking', (tester) async {
        controller.toggleMod(const Mods.shift());
        enableMouseTracking(controller);

        final events = <Uint8List>[];
        controller.onOutput = events.add;

        await tester.pumpWidget(buildHandler(controller: controller));

        final gesture = await mouseDown(tester, const Offset(24, 16));
        await gesture.up();

        expect(events, isEmpty);
      });
    });

    group('wide character selection snapping', () {
      setUp(() {
        terminalFor(controller).write(Uint8List.fromList(utf8.encode('AB日CD')));
      });

      testWidgets('drag from spacer snaps anchor inclusive', (tester) async {
        await tester.pumpWidget(buildHandler(controller: controller));

        final gesture = await mouseDown(tester, const Offset(24, 0));
        await gesture.moveTo(const Offset(40, 0));
        await gesture.up();

        expect(controller.selectedText(), '日C');
      });

      testWidgets('drag ending on wide char snaps end exclusive', (
        tester,
      ) async {
        await tester.pumpWidget(buildHandler(controller: controller));

        final gesture = await mouseDown(tester, Offset.zero);
        await gesture.moveTo(const Offset(24, 0));
        expect(controller.selectedText(), 'AB日');

        await gesture.moveTo(const Offset(16, 0));
        expect(controller.selectedText(), 'AB');

        await gesture.up();
      });

      testWidgets('leftward drag from spacer snaps anchor exclusive', (
        tester,
      ) async {
        await tester.pumpWidget(buildHandler(controller: controller));

        final gesture = await mouseDown(tester, const Offset(24, 0));
        await gesture.moveTo(Offset.zero);
        await gesture.up();

        expect(controller.selectedText(), 'AB日');
      });

      testWidgets('narrow cells pass through unaffected', (tester) async {
        await tester.pumpWidget(buildHandler(controller: controller));

        final gesture = await mouseDown(tester, Offset.zero);
        await gesture.moveTo(const Offset(8, 0));
        await gesture.up();

        final selection = terminalFor(controller).selection!;
        expect(selection.startCol, 0);
        expect(selection.endCol, 1);
      });

      testWidgets('double click on spacer leaves selection empty', (
        tester,
      ) async {
        await tester.pumpWidget(buildHandler(controller: controller));

        await tapMouse(tester, const Offset(24, 0), count: 2);

        expect(terminalFor(controller).selection, isNull);
      });
    });

    group('mouse tracking', () {
      testWidgets('click fires press and release when mode is normal', (
        tester,
      ) async {
        enableMouseTracking(controller);

        final events = <Uint8List>[];
        controller.onOutput = events.add;

        await tester.pumpWidget(buildHandler(controller: controller));

        final gesture = await mouseDown(tester, const Offset(24, 16));
        await gesture.up();

        expect(events.length, 2);
      });

      testWidgets('click fires press only when mode is x10', (tester) async {
        enableMouseTracking(controller, mode: .x10);

        final events = <Uint8List>[];
        controller.onOutput = events.add;

        await tester.pumpWidget(buildHandler(controller: controller));

        final gesture = await mouseDown(tester, const Offset(24, 16));
        await gesture.up();

        expect(events.length, 1);
      });

      testWidgets('no events when mode is none', (tester) async {
        final events = <Uint8List>[];
        controller.onOutput = events.add;

        await tester.pumpWidget(buildHandler(controller: controller));

        final gesture = await mouseDown(tester, const Offset(24, 16));
        await gesture.up();

        expect(events, isEmpty);
      });
    });
  });
}
