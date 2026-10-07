import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/infrastructure/terminal/ghostty_terminal_adapter.dart';

import 'fixtures/vt/vt_samples.dart';

// TER01：同一段 UTF-8/CJK/ANSI 字节无论怎么切包，经适配器进终端后的最终状态都必须和整块输入一致。
// R16 起连接层只送原始字节；R20 起安装包里只有 Ghostty，它直接吃字节，网络块切在字符中间也不先转字符串。
// 原版 xterm2 吃同一份素材的对照在 terminal_vt_corpus_test.dart。
void main() {
  ({String screen, String cursor, bool alt, List<String> replies}) render(
    Iterable<Uint8List> chunks,
  ) {
    final replies = <String>[];
    final adapter = GhosttyTerminalAdapter();
    adapter.bind((bytes) => replies.add(utf8.decode(bytes)));
    for (final chunk in chunks) {
      adapter.feed(chunk);
    }
    final screen = adapter.allText();
    final alt = adapter.isAlternateScreen;
    final answered = [...replies];
    // 光标在哪由终端自己报（DSR 6 → CPR），和用户手机上远端程序问的是同一个问题。
    replies.clear();
    adapter.feed(Uint8List.fromList(utf8.encode('\x1b[6n')));
    final result = (
      screen: screen,
      cursor: replies.join(),
      alt: alt,
      replies: answered,
    );
    adapter.dispose();
    return result;
  }

  final samples = {
    'CJK+ANSI': VtSamples.cjkAndAnsi,
    'emoji+组合字符': VtSamples.emojiAndCombining,
    '全屏+DA 查询': VtSamples.fullScreen,
    '全部拼接': VtSamples.all,
  };

  for (final entry in samples.entries) {
    test('${entry.key}：随机切包、逐字节和整块输入的终端状态一致', () {
      final expected = render([entry.value]);
      expect(expected.screen, isNot(contains('�')));
      expect(expected.cursor, matches(RegExp(r'^\x1b\[\d+;\d+R$')),
          reason: '光标位置报告要有，下面的比较才不是空对空');
      for (final seed in List.generate(20, (i) => i)) {
        final actual = render(randomChunks(entry.value, seed));
        expect(actual.screen, expected.screen, reason: 'seed=$seed');
        expect((actual.cursor, actual.alt), (expected.cursor, expected.alt),
            reason: 'seed=$seed');
        expect(actual.replies, expected.replies,
            reason: '终端回应（如 DA）必须同样只出现一次，seed=$seed');
      }
      final bytewise = render(byteChunks(entry.value));
      expect(bytewise.screen, expected.screen, reason: '逐字节切包');
      expect(bytewise.cursor, expected.cursor, reason: '逐字节切包');
      expect(bytewise.replies, expected.replies, reason: '逐字节切包');
    });
  }

  test('前提：DA 查询确实会触发终端回应，上面"回应一致"的断言不是空对空', () {
    final replies = render([VtSamples.fullScreen]).replies;
    expect(replies, hasLength(1));
    expect(replies.single, startsWith('\x1b['));
  });

  test('真正的非法 UTF-8：替换符数量不随切包位置变化', () {
    final whole = render([VtSamples.invalidUtf8]).screen;
    expect('�'.allMatches(whole), isNotEmpty, reason: '非法字节要显示成替换符，不能悄悄吞掉');
    for (final seed in List.generate(20, (i) => i)) {
      expect(render(randomChunks(VtSamples.invalidUtf8, seed)).screen, whole,
          reason: 'seed=$seed');
    }
    expect(render(byteChunks(VtSamples.invalidUtf8)).screen, whole,
        reason: '逐字节切包');
  });

  test('对照：上游按 chunk 单独解码的写法在同样切包下会出现乱码', () {
    // 复现 495f5d31 里 ssh_service.dart 的旧写法，证明上面那组测试确实能抓到 A03。
    final chunks = randomChunks(VtSamples.cjkAndAnsi, 0);
    final perChunk =
        chunks.map((c) => utf8.decode(c, allowMalformed: true)).join();
    expect(perChunk, contains('�'));
  });
}
