import 'package:libghostty/libghostty.dart';

void main() {
  final parser = SgrParser();

  final attrs = parser.parse([1, 31]);
  for (final attr in attrs) {
    switch (attr.tag) {
      case .bold:
        print('Bold');
      case .fg8:
        print('Foreground color: ${attr.paletteIndex}');
      case _:
        print(attr.tag);
    }
  }

  parser.dispose();
}
