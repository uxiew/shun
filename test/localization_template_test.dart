import 'package:flutter_test/flutter_test.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';
import 'package:shun/presentation/localization/translations_en.dart';

/// 英文表里带变量的整句键（`'删除 ${entry.name}？'`）按模板匹配：localized_widgets.dart。
/// 源码里每句中文翻不翻得出来，由 localization_coverage_test 查。
void main() {
  setUp(() => ShunLocalizations.use('en'));
  tearDown(() => ShunLocalizations.use('zh-CN'));

  test('模板键的英文只用中文键里有的变量', () {
    final wrong = <String>[];
    for (final entry in englishTranslations.entries) {
      final template = LocalizationTemplate.parse(entry.key, entry.value);
      if (template != null && template.unknownEnglishNames.isNotEmpty) {
        wrong.add('${entry.key}\n  => ${template.unknownEnglishNames}');
      }
    }
    expect(wrong, isEmpty, reason: wrong.join('\n'));
  });

  test('模板：值原样填回英文，顺序可以和中文不同', () {
    final template = LocalizationTemplate.parse(
        r'把 ${option.transport.label} 设为这台主机的默认',
        r'Make ${option.transport.label} the default for this host')!;
    expect(template.match('把 Mosh 设为这台主机的默认'), ['Mosh']);
    expect(template.match('把 Mosh 设为这台主机的'), isNull);
    final swapped = LocalizationTemplate.parse(r'${a} 里的 $b', r'$b in ${a}')!;
    expect(swapped.render(swapped.match('X 里的 Y')!), 'Y in X');
  });

  test('只有变量和标点的键不当模板：它什么都能对上', () {
    expect(LocalizationTemplate.parse(r'${a}：${b}', r'${a}: ${b}'), isNull);
    expect(LocalizationTemplate.parse('没有变量', 'No variables'), isNull);
  });

  test('字面多的模板先对；值是有整句翻译的系统消息就一起翻，用户起的名字不动', () {
    // 「插件 $id」和「插件 ${entry.pluginId} 自己联网」都在英文表里；后者更具体，得它赢。
    expect(localized('插件 top.example 自己联网'), isNot(contains('自己联网')));
    // 值是有整句翻译的系统消息：一起翻。
    expect(localized('服务操作失败：连接已断开。'), 'Service action failed: Disconnected.');
  });

  test('值里有翻不出来的中文就不算对上，退回片段表（模板太宽会吞掉整句）', () {
    // 「经$proxy」能对上任何「经」开头的句子；「经代理连接失败」有自己的片段翻译。
    expect(localized('经代理连接失败'), 'connecting through the proxy failed');
  });
}
