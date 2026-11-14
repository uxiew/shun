import 'package:flutter_test/flutter_test.dart';

import 'support/ui_rules.dart';

/// 界面的硬规矩（docs/dev/ui-text.md）。报错时按提示改界面，别改这里的上限。
///
/// 规则认的不只是 TextField / LText 这几个名字：Prism 控件（`prism.X`）和本地包了几层的控件，
/// 从源码里发现它们把哪个参数画成字、里面是不是输入框（test/support/ui_rules.dart）。
/// 能不能被绕过，看 test/ui_rules_bypass_test.dart。
void main() {
  final catalog = UiCatalog([...presentationSources(), ...prismSources()]);

  test('上下相邻的输入框之间必须是 FormGap', () {
    final wrong = catalog.formGapProblems();
    expect(wrong, isEmpty,
        reason: '改成 const FormGap()（widgets/form_gap.dart）：\n'
            '${wrong.join('\n')}');
  });

  group('常驻页面上的字有上限', () {
    final found = catalog.longText().toList();

    void expectNone(TextKind kind, String advice) {
      final lines = [
        for (final item in found)
          if (item.kind == kind && !_longTextAllowed.contains(item.text))
            '${item.where} ${item.count} 字：${item.text}',
      ];
      expect(lines, isEmpty, reason: '$advice\n${lines.join('\n')}');
    }

    test('输入框下面的提示不超过 16 个字', () {
      expectNone(TextKind.helper, '改短，解释放进 ⓘ（docs/dev/ui-text.md）：');
    });

    test('列表行的副标题不超过 16 个字', () {
      expectNone(TextKind.subtitle, '副标题只写状态，解释放进 ⓘ（docs/dev/ui-text.md）：');
    });

    test('页面上的一段字不超过 30 个字', () {
      expectNone(
        TextKind.paragraph,
        '页面只放名字和状态。解释放进 ⓘ，要动手前才需要知道的放确认框'
        '（docs/dev/ui-text.md）：',
      );
    });
  });
}

/// 确实要常驻、又短不下来的字。加之前先试试改短或放进 ⓘ；写明原因。
const _longTextAllowed = <String>{};
