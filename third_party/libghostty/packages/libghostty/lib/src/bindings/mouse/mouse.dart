import '../../generated/libghostty_enums.g.dart';
import '../../types/types.dart';
import '../types.dart';

abstract interface class MouseBindings {
  String mouseEncoderEncode(LibGhosttyHandle encoder, LibGhosttyHandle event);
  void mouseEncoderFree(LibGhosttyHandle encoder);
  LibGhosttyHandle mouseEncoderNew();
  void mouseEncoderReset(LibGhosttyHandle encoder);
  void mouseEncoderSetBoolOpt(
    LibGhosttyHandle encoder,
    MouseEncoderOption option, {
    required bool value,
  });
  void mouseEncoderSetFormat(LibGhosttyHandle encoder, MouseFormat format);
  void mouseEncoderSetOptFromTerminal(
    LibGhosttyHandle encoder,
    LibGhosttyHandle terminal,
  );
  void mouseEncoderSetSize(LibGhosttyHandle encoder, MouseEncoderSize size);
  void mouseEncoderSetTrackingMode(
    LibGhosttyHandle encoder,
    MouseTrackingMode mode,
  );

  void mouseEventClearButton(LibGhosttyHandle event);
  void mouseEventFree(LibGhosttyHandle event);
  MouseAction mouseEventGetAction(LibGhosttyHandle event);
  MouseButton? mouseEventGetButton(LibGhosttyHandle event);
  int mouseEventGetMods(LibGhosttyHandle event);
  (double x, double y) mouseEventGetPosition(LibGhosttyHandle event);
  LibGhosttyHandle mouseEventNew();
  void mouseEventSetAction(LibGhosttyHandle event, MouseAction action);
  void mouseEventSetButton(LibGhosttyHandle event, MouseButton button);
  void mouseEventSetMods(LibGhosttyHandle event, int mods);
  void mouseEventSetPosition(LibGhosttyHandle event, double x, double y);
}
