/// 从 Dart 源码里看界面树的形状，给 test/ui_rules_test.dart 用。
///
/// 不是完整的语法分析，只认括号、字面量、注释：够分出 `children: [...]` 里的兄弟，
/// 和一句字所在的调用链（比如 AlertDialog → LText）。
library;

/// 把注释和字面量的内容换成同样长度的占位，换行不动，所以偏移和行号都还对得上。
String blankLiterals(String source) {
  final out = StringBuffer();
  var i = 0;
  void blank(int end, String fill) {
    for (var j = i; j < end; j++) {
      out.write(source[j] == '\n' ? '\n' : fill);
    }
    i = end;
  }

  while (i < source.length) {
    if (source.startsWith('//', i)) {
      final end = source.indexOf('\n', i);
      blank(end < 0 ? source.length : end, ' ');
      continue;
    }
    if (source.startsWith('/*', i)) {
      final end = source.indexOf('*/', i);
      blank(end < 0 ? source.length : end + 2, ' ');
      continue;
    }
    final c = source[i];
    if (c == "'" || c == '"') {
      final raw = i > 0 && source[i - 1] == 'r';
      final quote = source.startsWith(c * 3, i) ? c * 3 : c;
      var j = i + quote.length;
      while (j < source.length) {
        if (!raw && source[j] == r'\') {
          j += 2;
          continue;
        }
        if (source.startsWith(quote, j)) break;
        j++;
      }
      out.write(quote);
      i += quote.length;
      blank(j, '_');
      out.write(quote);
      i += quote.length;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

int lineOf(String source, int offset) =>
    '\n'.allMatches(source.substring(0, offset)).length + 1;

/// `[` 后面一层的元素：(在源码里的偏移, 文字)。[open] 指向 `[`。
List<(int, String)> listElements(String blanked, int open) {
  final out = <(int, String)>[];
  var depth = 0;
  var start = open + 1;
  void flush(int end) {
    final text = blanked.substring(start, end);
    if (text.trim().isEmpty) return;
    out.add((start + text.length - text.trimLeft().length, text.trim()));
  }

  for (var i = open; i < blanked.length; i++) {
    final c = blanked[i];
    if ('([{'.contains(c)) depth++;
    if (')]}'.contains(c)) {
      depth--;
      if (depth == 0) {
        flush(i);
        return out;
      }
    }
    if (c == ',' && depth == 1) {
      flush(i);
      start = i + 1;
    }
  }
  return out;
}

/// 所有 `children: [` 和 `...[` 列表的 `[` 的位置。
Iterable<int> childLists(String blanked) => RegExp(
      r'(?:children\s*:\s*(?:<[^>]*>)?|\.\.\.)\[',
    ).allMatches(blanked).map((match) => match.end - 1);

/// 去掉元素开头的 `if (…)`：`if (a) TextField(…)` 算 TextField。
String withoutCollectionIf(String element) {
  var text = element;
  while (text.startsWith(RegExp(r'if\s*\('))) {
    var depth = 0;
    var i = text.indexOf('(');
    for (; i < text.length; i++) {
      if (text[i] == '(') depth++;
      if (text[i] == ')') {
        depth--;
        if (depth == 0) break;
      }
    }
    text = text.substring(i + 1).trimLeft();
  }
  return text;
}

/// [offset] 处开着的调用，外层在前。每一层是括号前的名字（没有就是空串）和这一层这会儿在填的命名参数。
List<({String call, String? argument})> callChain(String blanked, int offset) {
  final frames = <({String call, String? argument, String bracket})>[];
  final label = RegExp(r'(?:^|[(,\[{]\s*)([A-Za-z_]\w*)\s*:\s*$');
  final name = RegExp(r'([A-Za-z_][\w.]*)(?:<[^()]*>)?\s*$');
  var segment = 0;
  for (var i = 0; i < offset && i < blanked.length; i++) {
    final c = blanked[i];
    if (c == '(' || c == '[' || c == '{') {
      final before = blanked.substring(i < 80 ? 0 : i - 80, i);
      frames.add((
        call: c == '(' ? (name.firstMatch(before)?.group(1) ?? '') : '',
        argument: null,
        bracket: c,
      ));
      segment = i;
    } else if (c == ')' || c == ']' || c == '}') {
      if (frames.isNotEmpty) frames.removeLast();
      segment = i;
    } else if (c == ':' && frames.isNotEmpty) {
      final before = blanked.substring(segment, i + 1);
      final match = label.firstMatch(before);
      if (match != null) {
        final top = frames.removeLast();
        frames.add((
          call: top.call,
          argument: match.group(1),
          bracket: top.bracket,
        ));
      }
    } else if (c == ',') {
      segment = i;
      if (frames.isNotEmpty) {
        final top = frames.removeLast();
        frames.add((call: top.call, argument: null, bracket: top.bracket));
      }
    }
  }
  return [
    for (final frame in frames)
      if (frame.bracket == '(') (call: frame.call, argument: frame.argument),
  ];
}
