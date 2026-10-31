import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_ui_scan.dart';

/// 界面的硬规矩（docs/dev/ui-text.md）。报错时按提示改界面，别改这里的上限。
void main() {
  final files = [
    for (final entity
        in Directory('lib/presentation').listSync(recursive: true))
      if (entity is File &&
          entity.path.endsWith('.dart') &&
          !entity.path.contains('/localization/'))
        entity,
  ]..sort((a, b) => a.path.compareTo(b.path));

  test('上下相邻的输入框之间必须是 FormGap', () {
    final field = RegExp(
      r'^(?:const\s+)?(?:TextField|TextFormField|DropdownButtonFormField)\b',
    );
    final fieldInRow = RegExp(
      r'\b(?:TextField|TextFormField|DropdownButtonFormField)\b',
    );
    bool isField(String element) =>
        field.hasMatch(element) ||
        (element.startsWith('Row(') && fieldInRow.hasMatch(element));
    final wrong = <String>[];
    for (final file in files) {
      final blanked = blankLiterals(file.readAsStringSync());
      for (final open in childLists(blanked)) {
        final elements = [
          for (final (offset, text) in listElements(blanked, open))
            (offset, withoutCollectionIf(text)),
        ];
        for (var i = 1; i < elements.length; i++) {
          final (offset, element) = elements[i];
          if (!isField(element)) continue;
          final (_, before) = elements[i - 1];
          final line = lineOf(blanked, offset);
          if (isField(before)) {
            wrong.add('${file.path}:$line 和上一个输入框之间没有间隔');
          } else if (before.startsWith(RegExp(r'(?:const\s+)?SizedBox\('))) {
            final above = i >= 2 ? elements[i - 2].$2 : '';
            if (isField(above)) {
              wrong.add('${file.path}:$line 间隔写成了 $before');
            }
          }
        }
      }
    }
    expect(wrong, isEmpty,
        reason: '改成 const FormGap()（widgets/form_gap.dart）：\n'
            '${wrong.join('\n')}');
  });
}
