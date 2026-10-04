import 'package:flutter/foundation.dart';

/// Applies one-shot toolbar modifiers to the next system-keyboard input.
/// This bridges Flutter's soft keyboard and the terminal toolbar, which do
/// not share hardware modifier state on Android or iOS.
class TerminalInputController extends ChangeNotifier {
  Set<String> modifiers = const {};

  void setModifiers(Iterable<String> value) {
    final next = Set<String>.unmodifiable(value);
    if (setEquals(next, modifiers)) return;
    modifiers = next;
    notifyListeners();
  }

  void clearModifiers() => setModifiers(const {});

  String consume(String value) {
    final active = modifiers;
    if (active.isEmpty || value.isEmpty) return value;
    modifiers = const {};
    notifyListeners();
    final shift = active.contains('shift');
    final alt = active.contains('alt');
    final ctrl = active.contains('ctrl');
    final parameter = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0);
    var result = value;
    if (result.length == 3 &&
        result.startsWith('\x1b[') &&
        'ABCDHF'.contains(result[2])) {
      result = '\x1b[1;$parameter${result[2]}';
    } else {
      if (shift && result.length == 1) result = result.toUpperCase();
      if (ctrl && result.length == 1) {
        final code = result.toUpperCase().codeUnitAt(0);
        if (code >= 64 && code <= 95) {
          result = String.fromCharCode(code & 0x1f);
        }
      }
      if (alt) result = '\x1b$result';
    }
    return result;
  }
}
