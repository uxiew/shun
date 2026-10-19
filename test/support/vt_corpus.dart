import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:flterm/flterm.dart';
import 'package:flutter/foundation.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'xterm_terminal_adapter.dart';

/// R20「同一字节素材对比两个引擎」的工具：读素材、按不同切法喂给引擎、取屏幕快照。
///
/// 素材和 tmux 裁判在 `test/fixtures/vt/`，录制脚本 `tool/vt-corpus/record.py`。

const vtFixtureDir = 'test/fixtures/vt';

/// 一段合成素材。
@immutable
class VtCase {
  const VtCase(this.name, this.description, this.bytes);
  final String name;
  final String description;
  final Uint8List bytes;
}

/// 把 `synthetic_cases.txt` 的转义写法变成字节。规则和 `tool/vt-corpus/record.py` 的 decode_escapes 一样：
/// `\e \r \n \t \b \a \\`、`\xHH`（一个原始字节，可以是非法 UTF-8）、`\x{HHHH}`（一个码点，按 UTF-8 编码）。
Uint8List decodeVtEscapes(String text) {
  final out = BytesBuilder();
  const simple = {
    'e': 0x1b,
    'r': 0x0d,
    'n': 0x0a,
    't': 0x09,
    'b': 0x08,
    'a': 0x07,
    r'\': 0x5c,
  };
  final runes = text.runes.toList();
  var i = 0;
  while (i < runes.length) {
    final ch = String.fromCharCode(runes[i]);
    if (ch != r'\') {
      out.add(utf8.encode(ch));
      i++;
      continue;
    }
    final next = String.fromCharCode(runes[i + 1]);
    if (simple.containsKey(next)) {
      out.addByte(simple[next]!);
      i += 2;
    } else if (next == 'x' && String.fromCharCode(runes[i + 2]) == '{') {
      final end = runes.indexOf('}'.codeUnitAt(0), i);
      final hex = String.fromCharCodes(runes.sublist(i + 3, end));
      out.add(utf8.encode(String.fromCharCode(int.parse(hex, radix: 16))));
      i = end + 1;
    } else if (next == 'x') {
      out.addByte(int.parse(String.fromCharCodes(runes.sublist(i + 2, i + 4)),
          radix: 16));
      i += 4;
    } else {
      throw FormatException('不认识的转义 \\$next', text, i);
    }
  }
  return out.toBytes();
}

List<VtCase> loadSyntheticCases() {
  final lines =
      File('$vtFixtureDir/synthetic_cases.txt').readAsStringSync().split('\n');
  final cases = <VtCase>[];
  String? name;
  var description = '';
  final text = StringBuffer();
  void flush() {
    if (name != null) {
      cases.add(VtCase(name, description, decodeVtEscapes(text.toString())));
    }
    text.clear();
  }

  for (final line in lines) {
    if (line.startsWith('=== ')) {
      flush();
      final parts = line.substring(4).split('|');
      name = parts.first.trim();
      description = parts.skip(1).join('|').trim();
    } else if (line.startsWith('#') || name == null) {
      continue;
    } else {
      text.write(line);
    }
  }
  flush();
  return cases;
}

String sha256Hex(List<int> bytes) => const DartSha256()
    .hashSync(bytes)
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();

/// tmux 裁判（`tool/vt-corpus/record.py` 录的 `tmux_oracle.json`）。
Map<String, Object?> loadTmuxOracle() =>
    jsonDecode(File('$vtFixtureDir/tmux_oracle.json').readAsStringSync())
        as Map<String, Object?>;

/// 终端某一刻的状态：可见区每行的字（去掉行尾空白）、光标（0 起算的行、列）、是否备用屏、光标是否显示，
/// 以及到这一刻为止终端回给远端的全部字节。
@immutable
class VtScreen {
  const VtScreen({
    required this.rows,
    required this.cursorRow,
    required this.cursorCol,
    required this.alt,
    required this.cursorVisible,
    this.replies = const [],
    this.wrapped,
    this.styles,
  });

  factory VtScreen.fromTmux(Map<String, Object?> json) {
    final cursor = (json['cursor'] as List).cast<int>();
    final replies = json['replies'] as String?;
    return VtScreen(
      rows: (json['rows'] as List).cast<String>(),
      cursorRow: cursor[0],
      // tmux 在「行尾待折行」时报的列是 80（越过最后一列），两个引擎报最后一列。
      cursorCol: min(cursor[1], 79),
      alt: json['alt'] as bool,
      cursorVisible: json['cursorVisible'] as bool,
      replies: replies == null ? const [] : _hexToBytes(replies),
      // tmux 的 capture-pane -e 只在样式变了时写 SGR，跨行接着上一行的样式（vim 的「~」行开头不再写颜色），
      // 所以整屏当一条流来拆，不能每行从默认样式开始。
      styles: json['styled'] == null
          ? null
          : parseStyledRows((json['styled'] as List).cast<String>()),
    );
  }

  final List<String> rows;
  final int cursorRow;
  final int cursorCol;
  final bool alt;
  final bool cursorVisible;
  final List<int> replies;

  /// 每行是不是上一行自动折过来的。tmux 裁判没有这一项（null）。
  final List<bool>? wrapped;

  /// 每行每个码点看得见的样式（[parseStyledRow]）。xterm2 没有这一项（null）。
  final List<List<StyledChar>>? styles;

  /// 和 [other] 样式不一样的地方：只比两边文字相同的行，每行只报第一个不一样的字。
  List<String> styleDiff(VtScreen other) {
    final mine = styles;
    final theirs = other.styles;
    if (mine == null || theirs == null) return const [];
    final out = <String>[];
    for (var row = 0; row < min(mine.length, theirs.length); row++) {
      if (row < rows.length &&
          row < other.rows.length &&
          rows[row] != other.rows[row]) {
        continue;
      }
      final a = mine[row];
      final b = theirs[row];
      for (var i = 0; i < min(a.length, b.length); i++) {
        if (a[i].char != b[i].char) break;
        if (a[i].char != ' ' && a[i].style != b[i].style) {
          out.add(
              '第 $row 行第 $i 个字「${a[i].char}」样式 ${a[i].style} ≠ ${b[i].style}');
          break;
        }
      }
    }
    return out;
  }

  /// 和 [other] 不一样的地方，一条一句；一样时是空列表。[replies] 为 false 时不比回应。
  List<String> diff(VtScreen other,
      {bool replies = true, bool wrapped = true}) {
    final out = <String>[];
    for (var row = 0; row < max(rows.length, other.rows.length); row++) {
      final a = row < rows.length ? rows[row] : '<没有这一行>';
      final b = row < other.rows.length ? other.rows[row] : '<没有这一行>';
      if (a != b) out.add('第 $row 行：「${visible(a)}」≠「${visible(b)}」');
    }
    if ((cursorRow, cursorCol) != (other.cursorRow, other.cursorCol)) {
      out.add(
          '光标 ($cursorRow,$cursorCol) ≠ (${other.cursorRow},${other.cursorCol})');
    }
    if (alt != other.alt) out.add('备用屏 $alt ≠ ${other.alt}');
    if (cursorVisible != other.cursorVisible) {
      out.add('光标显示 $cursorVisible ≠ ${other.cursorVisible}');
    }
    if (replies && !listEquals(this.replies, other.replies)) {
      out.add(
          '回应 ${describeBytes(this.replies)} ≠ ${describeBytes(other.replies)}');
    }
    if (wrapped &&
        this.wrapped != null &&
        other.wrapped != null &&
        !listEquals(this.wrapped, other.wrapped)) {
      final rowsA = [
        for (var i = 0; i < this.wrapped!.length; i++)
          if (this.wrapped![i]) i
      ];
      final rowsB = [
        for (var i = 0; i < other.wrapped!.length; i++)
          if (other.wrapped![i]) i
      ];
      out.add('折行标记 $rowsA ≠ $rowsB');
    }
    return out;
  }
}

List<int> _hexToBytes(String hex) => [
      for (var i = 0; i + 1 < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16)
    ];

/// 回应字节写成人看得懂的样子，见 [visible]。
String describeBytes(List<int> bytes) =>
    '「${visible(utf8.decode(bytes, allowMalformed: true))}」';

/// 看不见的字写出来：ESC 写成 `␛`，其余 C0、DEL、C1 控制字符写成 `‹7f›` 这样的十六进制。
/// 差异说明要钉进测试源码，原样写这些字符在源码里看不见，也容易被编辑器吞掉。
String visible(String text) {
  final out = StringBuffer();
  for (final rune in text.runes) {
    if (rune == 0x1b) {
      out.write('␛');
    } else if (rune < 0x20 || (rune >= 0x7f && rune <= 0x9f)) {
      out.write('‹${rune.toRadixString(16).padLeft(2, '0')}›');
    } else {
      out.writeCharCode(rune);
    }
  }
  return out.toString();
}

/// 一个被对比的引擎：从一个全新的 [cols]x[rows] 终端开始，按块喂字节，最后取快照。
abstract interface class VtEngine {
  String get name;
  VtScreen render(Iterable<Uint8List> chunks, {int cols, int rows});
}

/// App 里实际用的 Ghostty 适配器和配置（滚动区上限、模式都和 App 一样），只改尺寸。
GhosttyTerminalAdapter newGhosttyCorpusAdapter(
        {int cols = 80, int rows = 24}) =>
    GhosttyTerminalAdapter(
      config: ghosttyTerminalConfig.copyWith(cols: cols, rows: rows),
    );

XtermTerminalAdapter newXtermCorpusAdapter({int cols = 80, int rows = 24}) {
  final adapter = XtermTerminalAdapter(maxLines: 1000);
  if (cols != 80 || rows != 24) adapter.terminal.resize(cols, rows);
  return adapter;
}

/// App 里实际用的 Ghostty 适配器（生产配置：滚动区上限、模式都和 App 一样）。
class GhosttyVtEngine implements VtEngine {
  const GhosttyVtEngine();

  @override
  String get name => 'Ghostty';

  @override
  VtScreen render(Iterable<Uint8List> chunks, {int cols = 80, int rows = 24}) {
    final adapter = newGhosttyCorpusAdapter(cols: cols, rows: rows);
    final replies = BytesBuilder();
    adapter.bind(replies.add);
    try {
      for (final chunk in chunks) {
        adapter.feed(chunk);
      }
      return ghosttyScreen(adapter, replies.toBytes(), rows: rows);
    } finally {
      adapter.dispose();
    }
  }
}

final _cup = RegExp(r'\x1b\[(\d+);(\d+)H');

/// 读 Ghostty 当前的屏幕。可见区是活动屏最后 [rows] 个物理行；光标从 VT 格式化输出末尾的 CUP 读
/// （flterm 不直接给光标位置）。
VtScreen ghosttyScreen(GhosttyTerminalAdapter adapter, List<int> replies,
    {int rows = 24}) {
  final controller = adapter.controller;
  final tail = controller.tailRows(rows);
  final formatter = controller.createFormatter(
    format: FormatterFormat.vt,
    extra: const FormatterExtra(cursor: true),
  );
  final String vt;
  try {
    vt = formatter.format();
  } finally {
    formatter.dispose();
  }
  final cup = _cup.allMatches(vt).last;
  final cols = controller.config.cols;
  final styles = <List<StyledChar>>[];
  for (var row = 0; row < rows; row++) {
    // 一行一行选出来要 VT 格式：整屏格式化时自动折行的行会被接成一行，对不上行号。
    controller.selectRange(
      start: Position(row: row, col: 0),
      end: Position(row: row, col: cols - 1),
      pointTag: PointTag.active,
    );
    styles.add(
        parseStyledRow(controller.selectedText(format: FormatterFormat.vt)));
  }
  controller.clearSelection();
  return VtScreen(
    rows: [for (final row in tail) row.text.trimRight()],
    wrapped: [for (final row in tail) row.wrapped],
    cursorRow: int.parse(cup.group(1)!) - 1,
    cursorCol: int.parse(cup.group(2)!) - 1,
    alt: controller.activeScreen == TerminalScreen.alternate,
    cursorVisible: controller.modeGet(const TerminalMode.cursorVisible()),
    replies: replies,
    styles: styles,
  );
}

/// 旧引擎 xterm2（对照基线）。
class XtermVtEngine implements VtEngine {
  const XtermVtEngine();

  @override
  String get name => 'xterm2';

  @override
  VtScreen render(Iterable<Uint8List> chunks, {int cols = 80, int rows = 24}) {
    final adapter = newXtermCorpusAdapter(cols: cols, rows: rows);
    final replies = BytesBuilder();
    adapter.bind(replies.add);
    try {
      for (final chunk in chunks) {
        adapter.feed(chunk);
      }
      return xtermScreen(adapter, replies.toBytes(), cols: cols);
    } finally {
      adapter.dispose();
    }
  }
}

/// 读 xterm2 当前的屏幕。xterm2 的 `getText` 跳过空格子（光标定位过去写的字前面不补空格），
/// 所以逐格拼：空格子写空格，宽字后面那个占位格跳过。
VtScreen xtermScreen(XtermTerminalAdapter adapter, List<int> replies,
    {int cols = 80}) {
  final terminal = adapter.terminal;
  final buffer = terminal.buffer;
  final first = buffer.height - terminal.viewHeight;
  final rows = <String>[];
  final wrapped = <bool>[];
  for (var index = first; index < buffer.height; index++) {
    final line = buffer.lines[index];
    final text = StringBuffer();
    for (var col = 0; col < min(cols, line.length); col++) {
      final width = line.getWidth(col);
      if (width == 0 && col > 0 && line.getWidth(col - 1) == 2) continue;
      if (line.getCodePoint(col) == 0) {
        text.write(' ');
      } else {
        text.write(line.getText(col, col + 1));
      }
    }
    rows.add(text.toString().trimRight());
    wrapped.add(line.isWrapped);
  }
  return VtScreen(
    rows: rows,
    wrapped: wrapped,
    cursorRow: buffer.cursorY,
    cursorCol: buffer.cursorX,
    alt: terminal.isUsingAltBuffer,
    cursorVisible: terminal.cursorVisibleMode,
    replies: replies,
  );
}

/// 按固定种子随机切块，块大小 1..[maxChunk]。
List<Uint8List> randomChunksOf(Uint8List bytes, int seed, {int maxChunk = 7}) {
  final random = Random(seed);
  final chunks = <Uint8List>[];
  var offset = 0;
  while (offset < bytes.length) {
    final size = min(1 + random.nextInt(maxChunk), bytes.length - offset);
    chunks.add(Uint8List.sublistView(bytes, offset, offset + size));
    offset += size;
  }
  return chunks;
}

List<Uint8List> byteChunksOf(Uint8List bytes) => [
      for (var i = 0; i < bytes.length; i++)
        Uint8List.sublistView(bytes, i, i + 1)
    ];

/// 三种喂法：整块、逐字节、两种随机切法（小块 1–7 字节、大块 1–4096 字节）。
Map<String, List<Uint8List>> feedings(Uint8List bytes) => {
      '整块': [bytes],
      '逐字节': byteChunksOf(bytes),
      '随机小块(seed 1)': randomChunksOf(bytes, 1),
      '随机大块(seed 2)': randomChunksOf(bytes, 2, maxChunk: 4096),
    };

/// 一个码点和它看得见的样式。
@immutable
class StyledChar {
  const StyledChar(this.char, this.style);
  final String char;
  final String style;
}

/// 把一行带 SGR 的 VT 文本（tmux `capture-pane -e`、Ghostty 的 VT 格式化输出）拆成每个码点的样式。
///
/// 只比字（空格不比）：前景色、背景色、粗、淡、斜、下划线（不分样式）、反显、删除线。闪烁、隐藏、上划线、
/// 下划线颜色不比。颜色统一成调色板序号（30–37、90–97、38;5;n 都是序号）或 RGB。字符集切换、OSC 8 链接跳过。
///
/// 空格不比的原因：Ghostty 的 VT 格式化输出给从没写过的格子补空格时不切回默认样式（`ab␛[103m中文␛[m␛[1;20Hx`
/// 输出成 `␛[48;5;11m中文             ␛[0mx`），看起来像是那些空格带了背景色，其实格子是空的。
/// 所以背景色擦除（BCE）、反显的空白状态栏这类「空格上的样式」这里比不出来。
List<StyledChar> parseStyledRow(String vt) => _parseStyledRow(vt, _Sgr());

/// 几行连着拆，样式从上一行末尾接着往下（tmux `capture-pane -e` 的写法）。
List<List<StyledChar>> parseStyledRows(List<String> rows) {
  final sgr = _Sgr();
  return [for (final row in rows) _parseStyledRow(row, sgr)];
}

List<StyledChar> _parseStyledRow(String vt, _Sgr sgr) {
  final out = <StyledChar>[];
  final runes = vt.runes.toList();
  var i = 0;
  while (i < runes.length) {
    final r = runes[i];
    if (r == 0x1b && i + 1 < runes.length) {
      final kind = runes[i + 1];
      if (kind == 0x5b) {
        var j = i + 2;
        while (j < runes.length && (runes[j] < 0x40 || runes[j] > 0x7e)) {
          j++;
        }
        if (j < runes.length && runes[j] == 0x6d) {
          sgr.apply(String.fromCharCodes(runes.sublist(i + 2, j)));
        }
        i = j + 1;
      } else if (kind == 0x5d) {
        var j = i + 2;
        while (j < runes.length &&
            runes[j] != 0x07 &&
            !(runes[j] == 0x1b &&
                j + 1 < runes.length &&
                runes[j + 1] == 0x5c)) {
          j++;
        }
        i = j < runes.length && runes[j] == 0x07 ? j + 1 : j + 2;
      } else if (kind >= 0x28 && kind <= 0x2b) {
        i += 3;
      } else {
        i += 2;
      }
    } else if (r < 0x20 || r == 0x7f) {
      i++;
    } else {
      out.add(StyledChar(String.fromCharCode(r), sgr.key(blank: r == 0x20)));
      i++;
    }
  }
  return out;
}

class _Sgr {
  String fg = '';
  String bg = '';
  bool bold = false;
  bool dim = false;
  bool italic = false;
  bool underline = false;
  bool reverse = false;
  bool strike = false;

  void reset() {
    fg = '';
    bg = '';
    bold = dim = italic = underline = reverse = strike = false;
  }

  String key({required bool blank}) => blank
      ? '[bg=$bg${reverse ? ' 反' : ''}${underline ? ' 下' : ''}'
          '${strike ? ' 删' : ''}]'
      : '[fg=$fg bg=$bg${bold ? ' 粗' : ''}${dim ? ' 淡' : ''}'
          '${italic ? ' 斜' : ''}${underline ? ' 下' : ''}'
          '${reverse ? ' 反' : ''}${strike ? ' 删' : ''}]';

  void apply(String text) {
    final params = [
      for (final part in (text.isEmpty ? '0' : text).split(';'))
        [for (final sub in part.split(':')) int.tryParse(sub) ?? 0]
    ];
    var i = 0;
    String? color(List<int> param) {
      if (param.length > 1) {
        // 冒号写法：38:5:n、38:2::r:g:b（色彩空间那一格可以空着）。
        final sub = param.sublist(1);
        if (sub.first == 5 && sub.length >= 2) return 'i${sub[1]}';
        if (sub.first == 2 && sub.length >= 4) {
          return sub.sublist(sub.length - 3).join(',');
        }
        return null;
      }
      if (i + 2 < params.length && params[i + 1].first == 5) {
        i += 2;
        return 'i${params[i].first}';
      }
      if (i + 4 < params.length && params[i + 1].first == 2) {
        final rgb = [
          params[i + 2].first,
          params[i + 3].first,
          params[i + 4].first
        ];
        i += 4;
        return rgb.join(',');
      }
      return null;
    }

    while (i < params.length) {
      final param = params[i];
      final p = param.first;
      switch (p) {
        case 0:
          reset();
        case 1:
          bold = true;
        case 2:
          dim = true;
        case 3:
          italic = true;
        case 4:
          underline = param.length < 2 || param[1] != 0;
        case 21:
          underline = true;
        case 22:
          bold = false;
          dim = false;
        case 23:
          italic = false;
        case 24:
          underline = false;
        case 7:
          reverse = true;
        case 27:
          reverse = false;
        case 9:
          strike = true;
        case 29:
          strike = false;
        case >= 30 && <= 37:
          fg = 'i${p - 30}';
        case 39:
          fg = '';
        case >= 90 && <= 97:
          fg = 'i${p - 90 + 8}';
        case >= 40 && <= 47:
          bg = 'i${p - 40}';
        case 49:
          bg = '';
        case >= 100 && <= 107:
          bg = 'i${p - 100 + 8}';
        case 38:
          fg = color(param) ?? fg;
        case 48:
          bg = color(param) ?? bg;
        case 58:
          color(param);
      }
      i++;
    }
  }
}
