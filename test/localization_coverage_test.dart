import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';

import 'support/dart_strings.dart';

/// 源码里每句中文，在英文界面下都要翻得出来。
///
/// 按运行时的样子查：相邻字面量拼成一句，变量换成样例值。以前是逐行正则：
/// - 多行拼接的句子逐行查，英文表也就逐行写，可运行时查的是整句，对不上；
/// - `$error` 当字面查，运行时却是填好值的句子；
/// - 一行两个字符串（`'topLeft' => '左上'`）被当成一句，英文表里就出现了
///   `"topLeft' => '左上"` 这种键，而「左上」本身没人翻。
/// 这三种测试都过、英文界面却是中文或半中半英。
void main() {
  setUp(() => ShunLocalizations.use('en'));
  tearDown(() => ShunLocalizations.use('zh-CN'));

  test('every Chinese source message has an English rendering', () {
    final han = RegExp(r'[一-鿿]');
    final missing = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.contains(
          '${Platform.pathSeparator}localization${Platform.pathSeparator}')) {
        continue;
      }
      for (final literal in dartStrings(entity.readAsStringSync())) {
        if (!han.hasMatch(literal.sample)) continue;
        if (_notTranslated.any(literal.template.contains)) continue;
        final english = ShunLocalizations.text(literal.sample);
        if (han.hasMatch(english)) {
          missing.add('${entity.path}:${literal.line}\n'
              '  ${literal.template}\n  => $english');
        }
      }
    }
    missing.sort();
    expect(missing, isEmpty,
        reason: '英文表里按整句写一条（docs/dev/ui-text.md）：\n'
            '${missing.join('\n')}');
  });
}

/// 不走英文表的中文。加一条要写清楚为什么。
const _notTranslated = <String>[
  // MoshBootstrapResult.toString()：只进调试日志，为的是不把密钥打印出来。
  'MoshBootstrapResult(',
  // ssh_identity 认键盘交互提示用的正则，匹配服务器发来的中文问句，不显示。
  'new|verif|code|otp',
  // 写进终端的提示（showNotice）直接进终端，不经过 localized()：英文界面下也是中文。
  // 已知缺口，记在 plan/v3/evidence/ui-text-2026-10-24.md；接上翻译以后删掉这一条。
  '\x1b[',
];
