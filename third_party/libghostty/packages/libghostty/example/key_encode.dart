import 'package:libghostty/libghostty.dart';

void main() {
  final encoder = KeyEncoder();
  final event = KeyEvent()
    ..mods = const .ctrl()
    ..action = .press
    ..key = .c;

  final sequence = encoder.encode(event);
  print('Ctrl+C encodes to: ${sequence.codeUnits}');

  event.key = .arrowUp;
  event.mods = const .none();
  print('Arrow Up encodes to: ${encoder.encode(event).codeUnits}');

  event.dispose();
  encoder.dispose();
}
