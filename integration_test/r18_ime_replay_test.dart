// R18 设备验证（TER02 的模拟器部分）：用「回放输入法」（plugins/fixture-replayime）按真实输入法的调用顺序
// 操作输入连接，经真实的 Flutter 引擎、终端、SSH 发到远端；远端用 dd 逐字节收下来，核对发了什么。
//
// 这不是 CI 测试，也不能代替真机上真的微信输入法语音（回放的是 R04 真机日志里记下的调用顺序）。
// 跑法：tool/ime-replay.sh（装回放输入法、设成默认、按测试的提示发广播、收尾换回原输入法并卸载）。
// 测试每准备好一段脚本就打印 "R18 READY=<脚本名>"，脚本跑完由回放输入法提交一个 Ctrl-C 结束远端的 dd。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'r18_remote_capture.dart';

/// 按 PTY 行编辑的规矩还原远端看到的行：退格删一个字（码点），回车换行。
({List<String> lines, int deletes}) replay(List<int> bytes) {
  final lines = <String>[''];
  var deletes = 0;
  final pending = <int>[];
  void flush() {
    if (pending.isEmpty) return;
    lines.last += utf8.decode(pending, allowMalformed: true);
    pending.clear();
  }

  for (final byte in bytes) {
    if (byte == 0x7f) {
      flush();
      deletes++;
      final runes = lines.last.runes.toList();
      if (runes.isNotEmpty) {
        lines.last = String.fromCharCodes(runes.take(runes.length - 1));
      }
    } else if (byte == 0x0d) {
      flush();
      lines.add('');
    } else {
      pending.add(byte);
    }
  }
  flush();
  return (lines: lines, deletes: deletes);
}

/// 每段脚本远端应该得到什么。
final _expectations = <String, void Function(List<int> bytes)>{
  // 「，你谁」→「啊，你谁」删 3 个，「你谁」→「你是谁？」删 1 个；没有整句重发。
  'wechat_voice': (bytes) {
    final r = replay(bytes);
    expect(r.lines, ['你好啊，你是谁？在一']);
    expect(r.deletes, 4);
    expect(utf8.decode(bytes.where((b) => b != 0x7f).toList()),
        '你好，你谁啊，你谁是谁？在一');
  },
  'pinyin': (bytes) {
    final r = replay(bytes);
    expect(r.lines, ['你 ok']);
    expect(r.deletes, 1);
  },
  'rewrite': (bytes) => expect(bytes, [...utf8.encode('ab'), 0x7f, 0x63]),
  'emoji': (bytes) {
    expect(bytes, [...utf8.encode('a👍'), 0x7f]);
  },
  'empty_backspace': (bytes) => expect(bytes, [0x7f, 0x7f]),
  // finishComposingText 在 Flutter 的 delta 模式下只带来空的编辑列表，也要提交。
  'finish_only': (bytes) => expect(bytes, utf8.encode('你好')),
  // 回车键之后紧接着的提交按输入法旧的编辑区算，整行不能再发一遍。
  'enter': (bytes) =>
      expect(bytes, [...utf8.encode('echo R18-ENTER'), 0x0d, 0x78]),
  'enter_newline': (bytes) =>
      expect(bytes, [...utf8.encode('echo R18-N'), 0x0d]),
};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final skip = r18Ssh.isEmpty ? '没给 R17_SSH，见 tool/ime-replay.sh' : false;

  for (final engine in ['Ghostty', 'xterm2']) {
    if (r18Engine.isNotEmpty && r18Engine != engine) continue;
    testWidgets('$engine：回放输入法的调用，远端逐字节核对', (tester) async {
      final (session, controller) = await connectR18(tester, engine);
      final terminal = session.terminal;
      await waitFor(tester, () => tester.view.viewInsets.bottom > 0,
          what: '输入法弹出');

      final failures = <String>[];
      for (final MapEntry(key: script, value: check) in _expectations.entries) {
        final bytes = await captureRemote(
          tester,
          terminal,
          () async => report('READY', script),
        );
        final result = replay(bytes);
        report('$engine.$script',
            'bytes=[${hex(bytes)}] lines=${result.lines} deletes=${result.deletes}');
        // xterm2 是要被换掉的旧引擎，只作对照：报告它收到了什么，不断言（R18 模拟器上：语音整段重复、
        // 改字时重发、回车后补的换行多发一个 \n，和 R04 真机上的症状一样）。
        if (engine == 'xterm2') continue;
        try {
          check(bytes);
        } on TestFailure catch (error) {
          failures.add('$script: $error');
        }
      }
      await controller.close(0);
      await tester.pump(const Duration(milliseconds: 300));
      expect(failures, isEmpty, reason: failures.join('\n'));
    }, skip: skip != false, timeout: const Timeout(Duration(minutes: 6)));
  }
}
