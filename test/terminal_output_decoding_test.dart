import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/infrastructure/terminal/xterm_terminal_adapter.dart';

import 'fixtures/vt/vt_samples.dart';

// TER01（xterm2 路径）：同一段 UTF-8/CJK/ANSI 字节无论怎么切包，经适配器进终端后的最终状态
// 都必须和整块输入一致。R16 起连接层只送原始字节，解码在 xterm2 适配器里、整条流共用一个解码器。
void main() {
  ({List<String> lines, int x, int y, bool alt, List<String> replies}) render(
    Iterable<Uint8List> chunks,
  ) {
    final replies = <String>[];
    final adapter = XtermTerminalAdapter(maxLines: 1000);
    adapter.bind((bytes) => replies.add(utf8.decode(bytes)));
    for (final chunk in chunks) {
      adapter.feed(chunk);
    }
    final terminal = adapter.terminal;
    final result = (
      lines: [for (final line in terminal.lines.toList()) line.getText()],
      x: terminal.buffer.cursorX,
      y: terminal.buffer.cursorY,
      alt: terminal.isUsingAltBuffer,
      replies: replies,
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
    test('${entry.key}：随机切包与整块输入的终端状态一致', () {
      final expected = render([entry.value]);
      expect(expected.lines.join(), isNot(contains('�')));
      for (final seed in List.generate(20, (i) => i)) {
        final actual = render(randomChunks(entry.value, seed));
        expect(actual.lines, expected.lines, reason: 'seed=$seed');
        expect(
          (actual.x, actual.y, actual.alt),
          (expected.x, expected.y, expected.alt),
          reason: 'seed=$seed',
        );
        expect(actual.replies, expected.replies,
            reason: '终端回应（如 DA）必须同样只出现一次，seed=$seed');
      }
      final bytewise = render(byteChunks(entry.value));
      expect(bytewise.lines, expected.lines, reason: '逐字节切包');
    });
  }

  test('前提：DA 查询确实会触发终端回应，上面"回应一致"的断言不是空对空', () {
    final replies = render([VtSamples.fullScreen]).replies;
    expect(replies, hasLength(1));
    expect(replies.single, startsWith('\x1b['));
  });

  test('真正的非法 UTF-8：替换符数量不随切包位置变化', () {
    String text(Iterable<Uint8List> chunks) => render(chunks).lines.join('\n');
    final whole = text([VtSamples.invalidUtf8]);
    expect('�'.allMatches(whole).length, 2);
    for (final seed in List.generate(20, (i) => i)) {
      expect(text(randomChunks(VtSamples.invalidUtf8, seed)), whole,
          reason: 'seed=$seed');
    }
  });

  test('对照：上游按 chunk 单独解码的写法在同样切包下会出现乱码', () {
    // 复现 495f5d31 里 ssh_service.dart 的旧写法，证明上面那组测试确实能抓到 A03。
    final chunks = randomChunks(VtSamples.cjkAndAnsi, 0);
    final perChunk =
        chunks.map((c) => utf8.decode(c, allowMalformed: true)).join();
    expect(perChunk, contains('�'));
  });
}
