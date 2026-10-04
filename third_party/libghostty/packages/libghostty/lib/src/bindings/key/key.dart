import '../../generated/libghostty_enums.g.dart';
import '../types.dart';

abstract interface class KeyBindings {
  String keyEncoderEncode(LibGhosttyHandle encoder, LibGhosttyHandle event);
  void keyEncoderFree(LibGhosttyHandle encoder);
  LibGhosttyHandle keyEncoderNew();
  void keyEncoderSetBoolOpt(
    LibGhosttyHandle encoder,
    KeyEncoderOption option, {
    required bool value,
  });
  void keyEncoderSetKittyFlags(LibGhosttyHandle encoder, int flags);
  void keyEncoderSetOptFromTerminal(
    LibGhosttyHandle encoder,
    LibGhosttyHandle terminal,
  );
  void keyEncoderSetOptionAsAlt(LibGhosttyHandle encoder, OptionAsAlt value);

  void keyEventFree(LibGhosttyHandle event);
  KeyAction keyEventGetAction(LibGhosttyHandle event);
  bool keyEventGetComposing(LibGhosttyHandle event);
  int keyEventGetConsumedMods(LibGhosttyHandle event);
  Key keyEventGetKey(LibGhosttyHandle event);
  int keyEventGetMods(LibGhosttyHandle event);
  int keyEventGetUnshiftedCodepoint(LibGhosttyHandle event);
  String? keyEventGetUtf8(LibGhosttyHandle event);
  LibGhosttyHandle keyEventNew();
  void keyEventSetAction(LibGhosttyHandle event, KeyAction action);
  void keyEventSetComposing(LibGhosttyHandle event, {required bool composing});
  void keyEventSetConsumedMods(LibGhosttyHandle event, int mods);
  void keyEventSetKey(LibGhosttyHandle event, Key key);
  void keyEventSetMods(LibGhosttyHandle event, int mods);
  void keyEventSetUnshiftedCodepoint(LibGhosttyHandle event, int codepoint);
  void keyEventSetUtf8(LibGhosttyHandle event, String? text);
}
