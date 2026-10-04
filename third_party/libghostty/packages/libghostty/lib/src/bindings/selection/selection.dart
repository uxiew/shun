import '../../generated/libghostty_enums.g.dart';
import '../../types/types.dart';
import '../types.dart';

abstract interface class SelectionBindings {
  RawSelection? selectionGestureEvent(
    LibGhosttyHandle gesture,
    LibGhosttyHandle terminal,
    LibGhosttyHandle event,
  );
  void selectionGestureEventClear(
    LibGhosttyHandle event,
    SelectionGestureEventOption option,
  );
  void selectionGestureEventFree(LibGhosttyHandle event);
  LibGhosttyHandle selectionGestureEventNew(SelectionGestureEventType type);
  void selectionGestureEventSetBehaviors(
    LibGhosttyHandle event,
    SelectionGestureBehavior singleClick,
    SelectionGestureBehavior doubleClick,
    SelectionGestureBehavior tripleClick,
  );
  void selectionGestureEventSetGeometry(
    LibGhosttyHandle event, {
    required int columns,
    required int cellWidth,
    required int paddingLeft,
    required int screenHeight,
  });
  void selectionGestureEventSetPosition(
    LibGhosttyHandle event,
    double x,
    double y,
  );
  void selectionGestureEventSetRectangle(
    LibGhosttyHandle event, {
    required bool value,
  });
  void selectionGestureEventSetRef(LibGhosttyHandle event, RawGridRef ref);
  void selectionGestureEventSetRepeatDistance(
    LibGhosttyHandle event,
    double value,
  );
  void selectionGestureEventSetRepeatIntervalNs(
    LibGhosttyHandle event,
    int value,
  );
  void selectionGestureEventSetTimeNs(LibGhosttyHandle event, int value);
  void selectionGestureEventSetViewport(
    LibGhosttyHandle event, {
    required Position position,
  });

  void selectionGestureEventSetWordBoundaryCodepoints(
    LibGhosttyHandle event,
    List<int> codepoints,
  );

  void selectionGestureFree(
    LibGhosttyHandle gesture,
    LibGhosttyHandle terminal,
  );
  RawGridRef? selectionGestureGetAnchor(
    LibGhosttyHandle gesture,
    LibGhosttyHandle terminal,
  );
  SelectionGestureAutoscroll selectionGestureGetAutoscroll(
    LibGhosttyHandle gesture,
    LibGhosttyHandle terminal,
  );
  SelectionGestureBehavior selectionGestureGetBehavior(
    LibGhosttyHandle gesture,
    LibGhosttyHandle terminal,
  );
  int selectionGestureGetClickCount(
    LibGhosttyHandle gesture,
    LibGhosttyHandle terminal,
  );
  bool selectionGestureGetDragged(
    LibGhosttyHandle gesture,
    LibGhosttyHandle terminal,
  );
  RawSelectionGestureState selectionGestureGetState(
    LibGhosttyHandle gesture,
    LibGhosttyHandle terminal,
  );
  LibGhosttyHandle selectionGestureNew();
  void selectionGestureReset(
    LibGhosttyHandle gesture,
    LibGhosttyHandle terminal,
  );

  RawSelection? terminalGetSelection(LibGhosttyHandle terminal);
  RawSelection? terminalSelectAll(LibGhosttyHandle terminal);
  RawSelection terminalSelectionAdjust(
    LibGhosttyHandle terminal,
    RawSelection selection,
    SelectionAdjust adjustment,
  );
  bool terminalSelectionContains(
    LibGhosttyHandle terminal,
    RawSelection selection,
    PointTag pointTag,
    Position position,
  );
  bool terminalSelectionEqual(
    LibGhosttyHandle terminal,
    RawSelection a,
    RawSelection b,
  );
  String? terminalSelectionFormat(
    LibGhosttyHandle terminal,
    FormatterFormat format, {
    bool unwrap = false,
    bool trim = false,
    RawSelection? selection,
  });
  SelectionOrder terminalSelectionOrder(
    LibGhosttyHandle terminal,
    RawSelection selection,
  );
  RawSelection terminalSelectionOrdered(
    LibGhosttyHandle terminal,
    RawSelection selection,
    SelectionOrder desired,
  );
  RawSelection? terminalSelectLine(
    LibGhosttyHandle terminal,
    RawGridRef ref, {
    List<int>? whitespace,
    bool semanticPromptBoundary = false,
  });
  RawSelection? terminalSelectOutput(LibGhosttyHandle terminal, RawGridRef ref);
  RawSelection? terminalSelectWord(
    LibGhosttyHandle terminal,
    RawGridRef ref, {
    List<int>? boundaryCodepoints,
  });
  RawSelection? terminalSelectWordBetween(
    LibGhosttyHandle terminal,
    RawGridRef start,
    RawGridRef end, {
    List<int>? boundaryCodepoints,
  });
  void terminalSetSelection(LibGhosttyHandle terminal, RawSelection? selection);
}
