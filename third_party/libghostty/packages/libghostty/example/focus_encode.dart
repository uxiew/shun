import 'package:libghostty/libghostty.dart';

void main() {
  final gained = FocusEvent.gained.encode();
  final lost = FocusEvent.lost.encode();
  print('Focus gained: ${gained.codeUnits}');
  print('Focus lost: ${lost.codeUnits}');
}
