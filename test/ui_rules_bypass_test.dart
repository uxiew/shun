import 'package:flutter_test/flutter_test.dart';

import 'support/ui_rules.dart';

/// UIM05：故意写一页超限的样例，看 UI 规则能不能被绕过（R84）。
///
/// 每条都是 R84 以前的扫描器查不到的写法：Prism 控件换个导入别名、本地包一层（再包一层）改个参数名、
/// 句子经 `localized(…)` 再交给 Text、输入框藏进包装类、用 Prism 自带却不关输入法学习的密码框。
/// 样例和真源码一起交给同一个扫描器，所以 HintTitle、Prism 这些真实的类也参与发现。
void main() {
  final long = '长' * 31; // 正文上限 30
  final over16 = '长' * 17; // 副标题、提示上限 16
  final page = '''
import 'package:flutter/material.dart';
import 'package:prism_ui/prism_ui.dart' as ui;

import '../widgets/hint.dart';

class Note extends StatelessWidget {
  const Note(this.words, {super.key});
  final String words;
  @override
  Widget build(BuildContext context) => Text(words);
}

class Remark extends StatelessWidget {
  const Remark({super.key, required this.body});
  final String body;
  @override
  Widget build(BuildContext context) =>
      Padding(padding: EdgeInsets.zero, child: Note(body));
}

class Box extends StatefulWidget {
  const Box({super.key, this.note});
  final String? note;
  @override
  State<Box> createState() => _BoxState();
}

class _BoxState extends State<Box> {
  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.zero,
        child: TextField(
          decoration: InputDecoration(helperText: widget.note),
        ),
      );
}

class Bypass extends StatelessWidget {
  const Bypass({super.key});
  @override
  Widget build(BuildContext context) => Column(children: [
        ui.ListRow(title: Text('a'), subtitle: Text('$over16')),
        ui.NullStatus(illustration: x, description: '$long'),
        Note('$long'),
        Remark(body: '$long'),
        Text(localized('$long')),
        HintTitle('$long'),
        Box(note: '$over16'),
        const FormGap(),
        TextField(decoration: InputDecoration(helperText: localized('$over16'))),
        Box(),
        const SizedBox(height: 8),
        ui.TextField(),
        const FormGap(),
        ui.SecretTextFormField(controller: c),
        const FormGap(),
        ui.TextField(obscureText: true),
      ]);
}

class Fine extends StatelessWidget {
  const Fine({super.key});
  @override
  Widget build(BuildContext context) => Column(children: [
        AlertDialog(content: Text('$long')),
        HintButton(title: 'a', message: '$long'),
        HintTitle('短', hint: '$long'),
        TextField(),
        const FormGap(),
        ui.TextField(),
        const FormGap(),
        Box(),
        const FormGap(),
        Row(children: [
          Expanded(child: TextField()),
          const SizedBox(width: 8),
          Expanded(child: ui.TextField()),
        ]),
        const FormGap(),
        ui.TextField(
          obscureText: true,
          enableIMEPersonalizedLearning: false,
          enableSuggestions: false,
          autocorrect: false,
        ),
      ]);
}
''';
  const path = 'lib/presentation/fixture/bypass.dart';
  final fixture = UiSource(path, page);
  final catalog = UiCatalog([
    fixture,
    ...presentationSources(),
    ...prismSources(),
  ]);
  int lineOf(String text) =>
      page.split('\n').indexWhere(
            (line) => line.contains(text),
          ) +
      1;

  test('Prism、本地包装和 localized() 里的长字都抓得到；确认框、ⓘ 里的不算', () {
    final found = {
      for (final item in catalog.longText())
        if (item.where.startsWith(path))
          '${item.where.substring(path.length + 1)} ${item.kind.name}',
    };
    expect(found, {
      '${lineOf('ui.ListRow')} subtitle',
      '${lineOf('ui.NullStatus')} paragraph',
      "${lineOf("Note('")} paragraph",
      '${lineOf('Remark(body')} paragraph',
      '${lineOf('Text(localized')} paragraph',
      "${lineOf("HintTitle('长")} paragraph",
      "${lineOf("Box(note:")} helper",
      '${lineOf('helperText: localized')} helper',
    });
  });

  test('包装过的输入框、Prism 输入框也要隔 FormGap；横排不算', () {
    final wrong = [
      for (final problem in catalog.formGapProblems())
        if (problem.startsWith(path)) problem.substring(path.length + 1),
    ];
    expect(wrong, [
      '${lineOf('        Box(),')} 和上一个输入框之间没有间隔',
      '${lineOf('        ui.TextField(),')} 间隔写成了 const SizedBox(height: 8)',
    ]);
  });

  test('Prism 的 SecretTextFormField 不关输入法学习：用了就报', () {
    final leaky = catalog.leakySecretClasses();
    expect(leaky, contains('prism.SecretTextFormField'));
    expect(
      catalog
          .callsTo(leaky)
          .where((call) => call.endsWith(' prism.SecretTextFormField')),
      ['$path:${lineOf('ui.SecretTextFormField')} prism.SecretTextFormField'],
    );
    // 自己写了不关学习的打码框的类，调用它也一样漏（这里是样例页 Bypass 本身）。
    expect(leaky, contains('Bypass'));
    expect(leaky, isNot(contains('Fine')));
  });

  test('Prism 的 TextField 打码时也要三个开关全关', () {
    final bypass = page.indexOf('class Bypass');
    final fine = page.indexOf('class Fine');
    expect(
      secretFieldProblems(page, from: bypass, to: fine),
      [
        'obscureText: true 的框 enableIMEPersonalizedLearning 是 null',
        'obscureText: true 的框 enableSuggestions 是 null',
        'obscureText: true 的框 autocorrect 是 null',
      ],
    );
    expect(secretFieldProblems(page, from: fine), isEmpty);
  });
}
