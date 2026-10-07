import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'support/vt_corpus.dart';

// R20：同一份字节素材喂给 Ghostty（App 的终端引擎）和旧引擎 xterm2，再和 tmux 自己的屏幕比（docs/06 D 步，docs/09）。
//
// 素材两类，都在 test/fixtures/vt/：
// - 合成素材 synthetic_cases.txt：CJK、emoji、组合字符、光标移动、滚动区、备用屏、字符集、非法 UTF-8、各种查询。
// - 真实程序 recorded/*.bin：vim、less、htop、tmux 客户端、bash 行编辑在 80x24 的 tmux 窗格里跑，录下程序写进窗格的原始字节。
// 裁判 tmux_oracle.json 是 tmux 3.5a 在同一时刻的屏幕、光标、备用屏、光标显示（tool/vt-corpus/record.py 录）。
//
// 硬要求：Ghostty 整块、逐字节、随机切块喂进去，屏幕、光标、备用屏、回应完全一样（TER01 的 Ghostty 部分）。
// Ghostty 和 tmux 不一样的地方逐条钉在下面的 [ghosttyVsTmux] 里，写明谁对、为什么可以接受；
// 没钉的差异、或者钉了却不再出现，测试都失败——引擎或素材变了要有人重新看一遍。
// xterm2 只做对照：差异写进报告（build/vt_corpus_report.md），不断言。

/// Ghostty 和 tmux 裁判已知不一样的地方：素材名（真实程序是「名字/检查点」）→ 差异原文（左边 Ghostty、右边 tmux）。
/// 真实程序（vim、less、htop、tmux 客户端、bash）一条都没有：文字、光标、备用屏、光标显示、字的样式全一样。
const ghosttyVsTmux = <String, List<String>>{
  // 在宽字的右半格写字、在宽字上删字：Ghostty 把整个宽字擦成空白（xterm2 一样，xterm 也是这么做的）；
  // tmux 的 capture-pane 还留着原来的宽字。远端程序不会故意这样写，可接受。
  'cjk-overwrite': [
    '第 0 行：「 x文」≠「中x文」',
    '第 3 行：「ab cd」≠「ab中cd」',
  ],
  // tmux 不认 HPR（CSI a）、VPR（CSI e），M、N 直接接着写；Ghostty（和 xterm2）按 ECMA-48 移动。Ghostty 对。
  'cursor-moves': [
    '第 6 行：「     K                                 L   M」≠「     K                                 LMN」',
    '第 8 行：「                                            N」≠「」',
  ],
  // 清掉全部制表位后 CHT：Ghostty（和 xterm2）照 VT 规矩跳到最右一列，tmux 原地不动。Ghostty 对。
  'tabs': [
    '第 3 行：「                                                                               1」≠「32」',
  ],
  // 「行尾待折行」状态下的 BS、EL、CUB、LF：Ghostty 照 xterm 的做法——光标停在最后一列、记一个待折行标记，
  // BS/CUB 从最后一列往左挪一格，EL、LF 清掉标记。tmux（和 xterm2）把光标当成停在第 81 列，于是 BS/CUB
  // 只退回最后一列、LF 之后下一个字还会折行。ncurses 按 xterm-256color 的 xenl 能力就是照 xterm 算的；
  // 真实程序的素材里两边没有任何不同。Ghostty 对（xterm 的结论来自读它的源码，没在真 xterm 上跑）。
  'autowrap': [
    '第 8 行：「                                                                              cb」≠「                                                                              ac」',
    '第 9 行：「                                                                               e」≠「                                                                               d」',
    '第 10 行：「」≠「e」',
    '第 11 行：「                                                                              rq」≠「                                                                               r」',
    '第 14 行：「                                                                               t」≠「」',
    '第 15 行：「」≠「t」',
    '光标 (14,79) ≠ (15,1)',
  ],
  // 同上：待折行时 BS。
  'bs-cr-lf': [
    '第 1 行：「012345678901234567890123456789012345678901234567890123456789012345678901234567RQ」≠「0123456789012345678901234567890123456789012345678901234567890123456789012345678R」',
  ],
  // tmux 的 capture-pane 吐的是 DEC 画框字符集里的原字母（它内部就这么存），屏幕上画的是框线；
  // Ghostty（和 xterm2）存的就是转换后的框线字。裁判的表示问题，Ghostty 对。
  'dec-graphics': [
    '第 0 行：「┌───┐」≠「lqqqk」',
    '第 1 行：「│  │」≠「x  x」',
    '第 2 行：「└───┘」≠「mqqqj」',
    '第 3 行：「┌─┐abc▒▒◆」≠「lqkabcaa`」',
    '第 4 行：「├─┼─┤·ok」≠「tqnqu~ok」',
  ],
  // UTF-8 编码的 C1（U+009B、U+0085）：Ghostty 丢掉，tmux 当普通字存，xterm2 当控制执行（换了颜色、换了行）。
  // 丢掉和 VTE 一样，远端也没法借 C1 绕过 ESC 过滤。原始字节 0x9B 不是合法 UTF-8：Ghostty 画替换符，tmux 丢掉。可接受。
  'c1-controls': [
    '第 0 行：「A31mBC」≠「A‹9b›31mBC」',
    '第 1 行：「D�31mEF」≠「D31mEF」',
    '第 2 行：「GH」≠「G‹85›H」',
  ],
  // 非法 UTF-8：Ghostty（和 xterm2）按 Unicode「最大合法前缀」规则画替换符（超长编码 2 个、代理区 3 个、
  // 超范围 4 个），tmux 直接丢掉。看得出这里有坏字节更好。Ghostty 对。
  'invalid-utf8': [
    '第 0 行：「a�b」≠「ab」',
    '第 1 行：「c�d」≠「cd」',
    '第 2 行：「e��g」≠「eg」',
    '第 3 行：「h���i」≠「hi」',
    '第 4 行：「j����k」≠「jk」',
    '第 5 行：「l��m」≠「lm」',
  ],
  // 裸 DEL（R04 问题 9）原来也在这里：Ghostty 把 0x7F 存进格子。fork 的 libghostty 写入前去掉了它，现在和 tmux 一样。
  // 换行后马上 REP：Ghostty（和 xterm2）重复上一行最后打印的字，tmux 不重复。ncurses 只在同一行里用 REP，可接受。
  'rep': [
    '第 2 行：「|||」≠「|」',
    '光标 (2,3) ≠ (2,1)',
  ],
  // 20 位数的参数：Ghostty（和 xterm2）当成最大值、下移到底，tmux 整条丢掉。可接受。
  'long-params': [
    '第 23 行：「down」≠「」',
  ],
  // tmux 不支持左右边距（DECSLRM，?69）；Ghostty 和 xterm2 支持。Ghostty 对。
  'slrm': [
    '第 0 行：「abcdefghij」≠「abcdefghijklmnop」',
    '第 1 行：「    xyznop」≠「    xyz」',
  ],
  // 一串查询都不该挪光标：Ghostty、xterm2 都在原地，tmux 的光标下移了 3 行。tmux 的问题。
  'responses': [
    '光标 (0,0) ≠ (3,0)',
  ],
  // 原点模式下设滚动区，光标回到滚动区左上角（第 5 行）：Ghostty、xterm2 都是这样；tmux 报 (0,0)。Ghostty 对。
  'responses-after-modes': [
    '光标 (4,0) ≠ (0,0)',
  ],
};

/// Ghostty 和 tmux 字的样式（颜色、粗体、反显等，见 parseStyledRow）已知不一样的地方。现在一条都没有。
const ghosttyStylesVsTmux = <String, List<String>>{};

/// Ghostty 对各种查询的回应，钉住：远端程序靠这些判断终端能力，变了要知道。和 xterm2 的对比见报告。
///
/// - DA1 `?62c`（VT220、不报任何扩展）；DA2 `>1;0;0c`；XTVERSION `libghostty`。
/// - **ANSI 模式的 DECRQM（`CSI 4 $ p`、`CSI 20 $ p`）不回**：上游 Ghostty 的 stream.zig 在 `'p'` 分支只认
///   两个中间字节（`? $`），一个 `$` 的走进了「未实现」。私有模式（`CSI ? n $ p`）都回。等程序问 IRM/LNM 的会等到超时。
/// - DECXCPR（`CSI ? 6 n`）不回（tmux 也不回）；DECRQSS 问 DECSCA（`"q`）回 `P0$r`（不支持，合法回答）。
/// - XTGETTCAP 问 `Co` 回 256，问 `TN` 什么都不回（xterm2 回 xterm-256color）。
/// - **OSC 10/11/12（前景、背景、光标色）不回**：flterm 只在视图挂上时才把主题色交给 Ghostty（`applyColorDefaults`），
///   这里没有视图，Ghostty 不知道默认色。OSC 4 调色板照回。
/// - `CSI 21 t`（回报标题）不回，`CSI 20 t` 也不回（SEC08）。
const ghosttyReplies = <String, String>{
  'responses':
      '「␛[?62c␛[?62c␛[>1;0;0c␛[>1;0;0c␛P!|00000000␛\\␛[0n␛[1;1R␛[?1;2\$y␛[?6;2\$y␛[?7;1\$y␛[?25;1\$y␛[?47;2\$y␛[?1000;2\$y␛[?1006;2\$y␛[?1049;2\$y␛[?2004;2\$y␛[?2026;2\$y␛[?2027;1\$y␛[?9999;0\$y␛P>|libghostty␛\\␛P>|libghostty␛\\␛P1\$r0m␛\\␛P1\$r1;24r␛\\␛P0\$r␛\\␛P1\$r2 q␛\\␛P1+r436F=323536␛\\␛[8;24;80t␛[4;0;0t␛[6;0;0t␛]4;1;rgb:cccc/6666/6666‹07›␛[?0u␛[?997;1n」',
  'responses-after-modes':
      '「␛[?1;1\$y␛[?2004;1\$y␛[?1000;1\$y␛[?1006;1\$y␛[?25;2\$y␛[3;7R␛[1;1R」',
};

void main() {
  final cases = loadSyntheticCases();
  final oracle = loadTmuxOracle();
  final synthetic = (oracle['synthetic'] as Map).cast<String, Object?>();
  final recorded = (oracle['recorded'] as Map).cast<String, Object?>();
  const ghostty = GhosttyVtEngine();
  const xterm = XtermVtEngine();
  final report = _Report(oracle);
  final seen = <String>{};

  tearDownAll(() => report.write('build/vt_corpus_report.md'));

  test('素材和裁判对得上：每段合成素材都有这一版录的 tmux 裁判', () {
    for (final c in cases) {
      final judge = synthetic[c.name] as Map?;
      expect(judge, isNotNull, reason: '${c.name} 没有裁判：python3 tool/vt-corpus/record.py');
      expect(judge!['sha256'], sha256Hex(c.bytes),
          reason: '${c.name} 改过，裁判是旧的：python3 tool/vt-corpus/record.py --only synthetic');
    }
  });

  group('合成素材', () {
    for (final c in cases) {
      test('${c.name}：${c.description}', () {
        final whole = ghostty.render([c.bytes]);
        for (final MapEntry(key: label, value: chunks)
            in feedings(c.bytes).entries) {
          final other = ghostty.render(chunks);
          expect([...other.diff(whole), ...other.styleDiff(whole)], isEmpty,
              reason: 'Ghostty $label 和整块不一样');
        }
        final judge = VtScreen.fromTmux(
            (synthetic[c.name] as Map).cast<String, Object?>());
        final old = xterm.render([c.bytes]);
        report.add(c.name, c.description, whole, old, judge);

        seen.add(c.name);
        expect(whole.diff(judge, replies: false, wrapped: false),
            ghosttyVsTmux[c.name] ?? const <String>[],
            reason: '和 tmux 不一样的地方变了（${c.name}）');
        expect(whole.styleDiff(judge),
            ghosttyStylesVsTmux[c.name] ?? const <String>[],
            reason: '和 tmux 样式不一样的地方变了（${c.name}）');
        final pinned = ghosttyReplies[c.name];
        if (pinned != null) {
          expect(describeBytes(whole.replies), pinned,
              reason: 'Ghostty 的回应变了（${c.name}）');
        }
      });
    }
  });

  group('真实程序', () {
    for (final MapEntry(key: name, value: entry) in recorded.entries) {
      final spec = (entry as Map).cast<String, Object?>();
      test('$name（${spec['command']}）', () {
        final bytes = File('$vtFixtureDir/${spec['file']}').readAsBytesSync();
        expect(sha256Hex(bytes), spec['sha256'], reason: '录的文件和裁判对不上');
        final checkpoints = [
          for (final cp in spec['checkpoints'] as List)
            (cp as Map).cast<String, Object?>()
        ];
        final offsets = [for (final cp in checkpoints) cp['offset'] as int];

        // 同一个终端一路喂下去，到每个检查点取一次快照；三种切法各来一遍。
        final runs = {
          '分段整块': _incremental(bytes, offsets, (b) => [b]),
          '逐字节': _incremental(bytes, offsets, byteChunksOf),
          '随机小块': _incremental(bytes, offsets, (b) => randomChunksOf(b, 3)),
        };
        final xtermRun = _incrementalXterm(bytes, offsets);
        final base = runs['分段整块']!;
        for (final MapEntry(key: label, value: run) in runs.entries) {
          for (var i = 0; i < checkpoints.length; i++) {
            expect([...run[i].diff(base[i]), ...run[i].styleDiff(base[i])],
                isEmpty,
                reason: 'Ghostty $label 在 ${checkpoints[i]['label']} 和整块不一样');
          }
        }
        for (var i = 0; i < checkpoints.length; i++) {
          final label = '$name/${checkpoints[i]['label']}';
          final judge = VtScreen.fromTmux(checkpoints[i]);
          report.add(label, '${spec['command']}', base[i], xtermRun[i], judge);
          seen.add(label);
          expect(base[i].diff(judge, replies: false, wrapped: false),
              ghosttyVsTmux[label] ?? const <String>[],
              reason: '和 tmux 不一样的地方变了（$label）');
          expect(base[i].styleDiff(judge),
              ghosttyStylesVsTmux[label] ?? const <String>[],
              reason: '和 tmux 样式不一样的地方变了（$label）');
          styledGlyphs += _styled(judge);
          expect(_styled(base[i]), _styled(judge),
              reason: '带颜色、粗体等样式的字数不一样（$label）');
        }
      });
    }
  });

  test('钉住的差异都还对应着素材（删了素材要一起删钉子）', () {
    expect(ghosttyVsTmux.keys.where((k) => !seen.contains(k)), isEmpty);
    expect(ghosttyStylesVsTmux.keys.where((k) => !seen.contains(k)), isEmpty);
  });

  test('前提：样式真的比了，不是空对空', () {
    // 真实程序的检查点里带样式（非默认颜色、粗体、反显……）的字，tmux 那边加起来有上千个。
    expect(styledGlyphs, greaterThan(1000));
    // 拆样式的规矩：颜色写法不同算同一种，跨行接着上一行（tmux 的写法），换了颜色能比出来。
    expect(parseStyledRow('\x1b[31mA').single.style,
        parseStyledRow('\x1b[38;5;1mA').single.style);
    expect(parseStyledRow('\x1b[38;2;1;2;3mA').single.style,
        parseStyledRow('\x1b[38:2::1:2:3mA').single.style);
    expect(parseStyledRows(['\x1b[94mx', 'y']).last.single.style,
        contains('fg=i12'));
    const plain = VtScreen(
        rows: ['ab'], cursorRow: 0, cursorCol: 0, alt: false, cursorVisible: true);
    final red = VtScreen(
        rows: plain.rows,
        cursorRow: 0,
        cursorCol: 0,
        alt: false,
        cursorVisible: true,
        styles: [parseStyledRow('\x1b[31mab')]);
    final green = VtScreen(
        rows: plain.rows,
        cursorRow: 0,
        cursorCol: 0,
        alt: false,
        cursorVisible: true,
        styles: [parseStyledRow('\x1b[32mab')]);
    expect(red.styleDiff(green), hasLength(1));
  });

  test('本机耗时参考（VT_BENCH=1 才跑，不是门禁）', () {
    report.bench = _bench(recorded);
  }, skip: Platform.environment['VT_BENCH'] == null ? '要量耗时时 VT_BENCH=1' : false);
}

var styledGlyphs = 0;

int _styled(VtScreen screen) => screen.styles!
    .expand((row) => row)
    .where((c) => c.char != ' ' && c.style != '[fg= bg=]')
    .length;

/// 两个引擎吃同一份素材的耗时（本机 macOS、Debug 模式的 flutter test，只做参考）。
/// 5 MiB 合成素材 = 中文 + 颜色 + 换行（R04 冻结的那种），16 KiB 一块；真实素材 = 5 份录像拼起来重复到约 5 MiB。
List<String> _bench(Map<String, Object?> recorded) {
  final synthetic = BytesBuilder();
  var n = 0;
  while (synthetic.length < 5 * 1024 * 1024) {
    synthetic.add(utf8.encode(
        '\x1b[3${n % 8}m第 $n 行 中文混排 the quick brown fox 0123456789\x1b[0m\r\n'));
    n++;
  }
  final real = BytesBuilder();
  final files = [
    for (final entry in recorded.values)
      File('$vtFixtureDir/${(entry as Map)['file']}').readAsBytesSync()
  ];
  while (real.length < 5 * 1024 * 1024) {
    for (final file in files) {
      real.add(file);
      real.add(utf8.encode('\x1b[?1049l\x1b[!p\x1b[2J\x1b[H'));
    }
  }
  final out = <String>[];
  for (final MapEntry(key: label, value: bytes) in {
    '5 MiB 合成（中文+颜色）': synthetic.toBytes(),
    '约 5 MiB 真实程序录像（重复拼接）': real.toBytes(),
  }.entries) {
    final chunks = [
      for (var i = 0; i < bytes.length; i += 16384)
        Uint8List.sublistView(bytes, i, min(i + 16384, bytes.length))
    ];
    for (final engine in ['Ghostty', 'xterm2']) {
      final times = <int>[];
      for (var round = 0; round < 3; round++) {
        final adapter = engine == 'Ghostty'
            ? newGhosttyCorpusAdapter()
            : newXtermCorpusAdapter();
        adapter.bind((_) {});
        final watch = Stopwatch()..start();
        for (final chunk in chunks) {
          adapter.feed(chunk);
        }
        watch.stop();
        times.add(watch.elapsedMilliseconds);
        adapter.dispose();
      }
      out.add('$label，$engine：${times.join(' / ')} ms（${bytes.length} 字节，三轮）');
    }
  }
  return out;
}

/// 一个 Ghostty 终端从头喂到尾，每到 [offsets] 里的位置取一次快照。每一段用 [split] 切块。
List<VtScreen> _incremental(Uint8List bytes, List<int> offsets,
    List<Uint8List> Function(Uint8List segment) split) {
  return _withGhostty((feed, snapshot) {
    var at = 0;
    return [
      for (final offset in offsets)
        () {
          for (final chunk in split(Uint8List.sublistView(bytes, at, offset))) {
            feed(chunk);
          }
          at = offset;
          return snapshot();
        }(),
    ];
  });
}

List<VtScreen> _withGhostty(
    List<VtScreen> Function(
            void Function(Uint8List) feed, VtScreen Function() snapshot)
        body) {
  final probe = _GhosttySession();
  try {
    return body(probe.feed, probe.snapshot);
  } finally {
    probe.dispose();
  }
}

class _GhosttySession {
  _GhosttySession() {
    adapter.bind(_replies.add);
  }
  final adapter = newGhosttyCorpusAdapter();
  final _replies = BytesBuilder(copy: true);

  void feed(Uint8List chunk) => adapter.feed(chunk);
  VtScreen snapshot() => ghosttyScreen(adapter, _replies.toBytes());
  void dispose() => adapter.dispose();
}

List<VtScreen> _incrementalXterm(Uint8List bytes, List<int> offsets) {
  final adapter = newXtermCorpusAdapter();
  final replies = BytesBuilder(copy: true);
  adapter.bind(replies.add);
  try {
    var at = 0;
    return [
      for (final offset in offsets)
        () {
          adapter.feed(Uint8List.sublistView(bytes, at, offset));
          at = offset;
          return xtermScreen(adapter, replies.toBytes());
        }(),
    ];
  } finally {
    adapter.dispose();
  }
}

/// 对比报告：每段素材 Ghostty、xterm2 各和 tmux 差在哪，两个引擎的回应。只给人看，不断言。
class _Report {
  _Report(this.oracle);
  final Map<String, Object?> oracle;
  final _sections = <String>[];
  List<String> bench = const [];
  var _same = 0;
  var _ghosttyDiff = 0;
  var _xtermDiff = 0;

  void add(String name, String description, VtScreen ghostty, VtScreen xterm,
      VtScreen tmux) {
    final g = [
      ...ghostty.diff(tmux, replies: false, wrapped: false),
      ...ghostty.styleDiff(tmux),
    ];
    final x = xterm.diff(tmux, replies: false, wrapped: false);
    final gx = ghostty.diff(xterm, replies: true, wrapped: true)
        .where((line) => line.startsWith('回应') || line.startsWith('折行'))
        .toList();
    if (g.isEmpty && x.isEmpty && gx.isEmpty) {
      _same++;
      return;
    }
    if (g.isNotEmpty) _ghosttyDiff++;
    if (x.isNotEmpty) _xtermDiff++;
    _sections.add([
      '### $name',
      '',
      description,
      '',
      '- Ghostty vs tmux：${g.isEmpty ? '一样' : ''}',
      for (final line in g) '  - $line',
      '- xterm2 vs tmux：${x.isEmpty ? '一样' : ''}',
      for (final line in x) '  - $line',
      if (gx.isNotEmpty) '- Ghostty vs xterm2（回应、折行标记）：',
      for (final line in gx) '  - $line',
      if (tmux.replies.isNotEmpty) '- tmux 的回应：${describeBytes(tmux.replies)}',
      '',
    ].join('\n'));
  }

  void write(String path) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync([
      '# R20 同素材两引擎对比报告（测试自动生成）',
      '',
      '裁判：${oracle['tmux']}（${oracle['image']}，录于 ${oracle['recordedAt']}）',
      '',
      '全部一样：$_same 段；Ghostty 和 tmux 不一样：$_ghosttyDiff 段；xterm2 和 tmux 不一样：$_xtermDiff 段。',
      '',
      if (bench.isNotEmpty) ...['## 本机耗时（参考）', '', for (final line in bench) '- $line', ''],
      ..._sections,
    ].join('\n'));
  }
}
