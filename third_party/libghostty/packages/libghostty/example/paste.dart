import 'dart:convert';

import 'package:libghostty/libghostty.dart';

void main() {
  print('Safe: ${pasteIsSafe("hello world")}');
  print('Unsafe (newline): ${pasteIsSafe("line1\nline2")}');
  print('Unsafe (escape): ${pasteIsSafe("text\x1b[201~")}');

  final bracketed = pasteEncode('hello', bracketed: true);
  print('Bracketed: ${utf8.decode(bracketed).codeUnits}');

  final plain = pasteEncode('line1\nline2', bracketed: false);
  print('Plain: ${utf8.decode(plain)}');
}
