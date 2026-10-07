// R18 真机复测（TER02）：所有者本人在真机上用自己的输入法（微信输入法）打拼音、说话，经真实的终端、SSH
// 发到远端，远端逐字节收下来，按行编辑的规矩还原成远端看到的那行字。
//
// 每一项的说明打在手机的终端里，人照着做、最后按键盘上的回车；回车后再收 3 秒，看有没有多发。
// 拼音几项字是确定的，自动核对；语音说什么不固定，测试只查回车前后有没有多发、有没有整段重复，
// 远端收到的字打在屏幕上和日志里，由说话的人确认是不是自己说的那句。
//
// 只用 Ghostty（xterm2 的整段重复 R04 已经在真机上看过）。跑法：tool/r18-real-device.sh。
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'r18_remote_capture.dart';

class _Step {
  const _Step(this.name, this.lines, this.check);

  final String name;

  /// 打在终端里给人看的说明，一行不超过 18 个汉字，手机竖屏放得下。
  final List<String> lines;

  /// 回车前那行字对不对；返回 null 是对，否则是哪里不对。语音的几项不知道会说什么，只查重复。
  final String? Function(String line, int deletes, List<int> beforeEnter) check;
}

String? _exact(String expected, String line) =>
    line == expected ? null : '应该是「$expected」';

/// 一段 4 个字以上的内容紧挨着出现两次，就当成整段重复（R04 里同一句话连发了 9 遍）。
String? _noRepeat(String line, int deletes, List<int> beforeEnter) {
  final runes = line.runes.toList();
  if (runes.isEmpty) return '什么都没收到';
  for (var size = 4; size * 2 <= runes.length; size++) {
    for (var i = 0; i + size * 2 <= runes.length; i++) {
      if (listEquals(
          runes.sublist(i, i + size), runes.sublist(i + size, i + size * 2))) {
        return '有一段紧挨着重复了：「${String.fromCharCodes(runes.sublist(i, i + size))}」';
      }
    }
  }
  return null;
}

final _steps = <_Step>[
  _Step('拼音候选', ['打 nihao 选「你好」', '再打 shijie 选「世界」', '按回车'],
      (line, _, __) => _exact('你好世界', line)),
  _Step(
      '拼音删字',
      ['打 jintian 选「今天」', '按键盘退格删掉一个字', '再打 ming 选「明」', '按回车'],
      (line, deletes, _) =>
          _exact('今明', line) ?? (deletes == 1 ? null : '应该只退格 1 次')),
  _Step('撤销拼音', ['打 zhongwen 先别选字', '按退格把拼音字母删光', '按回车'], (line, _, before) {
    // 多按几下退格会多发 DEL，不算错；拼音字母一个都不能发出去。
    final sent = before.where((b) => b != 0x7f).toList();
    return sent.isEmpty ? null : '撤销的拼音被发出去了';
  }),
  _Step(
      '中英混排',
      ['打 ceshi 选「测试」', '切到英文打 abc', '切回中文打 yixia 选「一下」', '按回车'],
      // 英文联想可能自动补空格，不算错。
      (line, _, __) => _exact('测试abc一下', line.replaceAll(' ', ''))),
  _Step('语音一句', ['用语音说一句话，十几个字', '比如：今天天气不错我们出去走走', '说完按回车'], _noRepeat),
  _Step('语音两句', ['用语音说两句话', '中间停一两秒', '说完按回车'], _noRepeat),
];

/// 放进 shell 单引号里：去掉控制字符，单引号换成 '\''。
String _quote(String text) =>
    "'${text.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').replaceAll("'", r"'\''")}'";

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final skip = r18Ssh.isEmpty ? '没给 R17_SSH，见 tool/r18-real-device.sh' : false;

  testWidgets('Ghostty：真人在真机上用输入法打拼音、说话，远端逐字节核对', (tester) async {
    final (session, controller) = await connectR18(tester);
    final terminal = session.terminal;
    terminal.sendText("clear; printf '%s\\n' 'R18 真机输入测试' '点一下这里叫出键盘'\r");
    await waitFor(tester, () => tester.view.viewInsets.bottom > 0,
        timeout: const Duration(minutes: 5), what: '键盘弹出');

    final failures = <String>[];
    var previous = <String>[];
    for (final (index, step) in _steps.indexed) {
      final lines = [
        ...previous,
        '第 ${index + 1}/${_steps.length} 项：${step.name}',
        ...step.lines,
      ];
      final bytes = await captureRemote(
        tester,
        terminal,
        () async => report('READY', step.name),
        end: CaptureEnd.enter,
        seconds: 180,
        prelude: "clear; printf '%s\\n' ${lines.map(_quote).join(' ')}; ",
      );
      final enter = bytes.indexOf(0x0d);
      final before = enter < 0 ? bytes : bytes.sublist(0, enter);
      final after = enter < 0 ? <int>[] : bytes.sublist(enter + 1);
      final result = replay(before);
      final line = result.lines.single;
      final problem = enter < 0
          ? '3 分钟内没收到回车'
          : after.isNotEmpty
              ? '回车后又收到 [${hex(after)}]'
              : step.check(line, result.deletes, before);
      report(
          'Ghostty.${step.name}',
          'line=「$line」 deletes=${result.deletes} bytes=[${hex(bytes)}] '
              '${problem ?? 'ok'}');
      if (problem != null) failures.add('${step.name}：$problem');
      previous = [
        '上一项远端收到：「$line」',
        if (problem != null) '不对：$problem' else '自动核对通过',
        '',
      ];
    }
    terminal.sendText("clear; printf '%s\\n' ${[
      ...previous,
      '测完了，可以放下手机'
    ].map(_quote).join(' ')}\r");
    await tester.pump(const Duration(seconds: 5));
    await controller.close(0);
    await tester.pump(const Duration(milliseconds: 300));
    expect(failures, isEmpty, reason: failures.join('\n'));
  }, skip: skip != false, timeout: const Timeout(Duration(minutes: 30)));
}
