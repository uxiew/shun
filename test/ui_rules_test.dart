import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_strings.dart';
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

  group('常驻页面上的字有上限', () {
    /// 这些调用里的字是点了才看到、或者只闪一下的，不算常驻。
    const transient = {
      'AlertDialog',
      'SimpleDialog',
      'SnackBar',
      'showHint',
      'HintButton',
      'HintTitle',
      'Tooltip',
    };
    final han = RegExp(r'[\u4e00-\u9fff]');

    /// 一句字算几个汉字。变量写在 `${...}` 里，不算。
    int length(DartString string) => han.allMatches(string.sample).length;

    Iterable<({String where, int count, String text})> found(
      int limit,
      bool Function(List<({String call, String? argument})> chain) applies,
    ) sync* {
      for (final file in files) {
        final source = file.readAsStringSync();
        final blanked = blankLiterals(source);
        for (final string in dartStrings(source)) {
          if (length(string) <= limit) continue;
          final chain = callChain(blanked, string.offset);
          if (chain.any((frame) => transient.contains(frame.call))) continue;
          if (!applies(chain)) continue;
          yield (
            where: '${file.path}:${string.line}',
            count: length(string),
            text: string.template,
          );
        }
      }
    }

    void expectNone(
      Iterable<({String where, int count, String text})> wrong,
      String advice,
    ) {
      final lines = [
        for (final item in wrong)
          if (!_longTextAllowed.contains(item.text))
            '${item.where} ${item.count} 字：${item.text}',
      ];
      expect(lines, isEmpty, reason: '$advice\n${lines.join('\n')}');
    }

    test('输入框下面的提示不超过 16 个字', () {
      expectNone(
        found(16, (chain) => chain.lastOrNull?.argument == 'helperText'),
        '改短，解释放进 ⓘ（docs/dev/ui-text.md）：',
      );
    });

    test('列表行的副标题不超过 16 个字', () {
      expectNone(
        found(
          16,
          (chain) => chain.any((frame) => frame.argument == 'subtitle'),
        ),
        '副标题只写状态，解释放进 ⓘ（docs/dev/ui-text.md）：',
      );
    });

    test('页面上的一段字不超过 30 个字', () {
      const text = {
        'LText',
        'Text',
        'LSelectableText',
        'SelectableText',
        'catalogLine',
      };
      expectNone(
        found(30, (chain) => text.contains(chain.lastOrNull?.call)),
        '页面只放名字和状态。解释放进 ⓘ，要动手前才需要知道的放确认框'
        '（docs/dev/ui-text.md）：',
      );
    });
  });
}

/// 确实要常驻、又短不下来的字。加之前先试试改短或放进 ⓘ；写明原因。
const _longTextAllowed = <String>{};
