/// 从 Dart 源码里挑出字符串字面量，给本地化测试用。
///
/// 和逐行正则不同：相邻的字面量（`'第一行，' '第二行'`）拼成一句，和运行时一样；
/// `${…}` 里嵌的引号不会把一句切成两段；嵌在里面的字面量也单独返回。
/// 只认引号、原始串、三引号、注释这些足够分辨字面量的语法，不是完整的 Dart 词法分析。
class DartString {
  DartString(
      this.line, this.template, this.sample, this.interpolated, this.pieces);

  /// 第一段所在的行号，从 1 起。
  final int line;

  /// 运行时的文字，变量保留源码原样（`${entry.name}`），转义已展开。用来对英文表的键。
  final String template;

  /// 变量换成样例值 [sampleValue] 的样子，等于运行时拿到的句子。
  final String sample;

  final bool interpolated;

  /// 拼成这一句的每个字面量各自的 [template]。
  final List<String> pieces;
}

const sampleValue = 'Q7';

List<DartString> dartStrings(String source) {
  final out = <DartString>[];
  _Scanner(source, out).run();
  return out;
}

class _Scanner {
  _Scanner(this.s, this.out);
  final String s;
  final List<DartString> out;
  var i = 0;

  late final _lineStarts = [
    0,
    for (final m in '\n'.allMatches(s)) m.end,
  ];

  int lineAt(int offset) {
    var line = 0;
    while (line + 1 < _lineStarts.length && _lineStarts[line + 1] <= offset) {
      line++;
    }
    return line + 1;
  }

  void run() {
    while (i < s.length) {
      if (_skipComment()) continue;
      if (_atString()) {
        _group();
        continue;
      }
      i++;
    }
  }

  bool _skipComment() {
    if (s.startsWith('//', i)) {
      final end = s.indexOf('\n', i);
      i = end < 0 ? s.length : end + 1;
      return true;
    }
    if (s.startsWith('/*', i)) {
      final end = s.indexOf('*/', i + 2);
      i = end < 0 ? s.length : end + 2;
      return true;
    }
    return false;
  }

  bool _atString() {
    final c = s[i];
    if (c == "'" || c == '"') return true;
    // r'...'，但不是标识符结尾的 r（`bar'` 不会出现在合法代码里，保险起见还是看前一个字符）。
    if (c == 'r' && i + 1 < s.length && (s[i + 1] == "'" || s[i + 1] == '"')) {
      return i == 0 || !RegExp(r'[A-Za-z0-9_$]').hasMatch(s[i - 1]);
    }
    return false;
  }

  /// 一串相邻的字面量，拼成一句。
  void _group() {
    final start = i;
    final template = StringBuffer();
    final sample = StringBuffer();
    var interpolated = false;
    final pieces = <String>[];
    while (true) {
      final piece = _literal();
      pieces.add(piece.$1);
      template.write(piece.$1);
      sample.write(piece.$2);
      interpolated |= piece.$3;
      final save = i;
      while (i < s.length) {
        if (_skipComment()) continue;
        if (' \t\r\n'.contains(s[i])) {
          i++;
          continue;
        }
        break;
      }
      if (i < s.length && _atString()) continue;
      i = save;
      break;
    }
    out.add(DartString(lineAt(start), template.toString(), sample.toString(),
        interpolated, pieces));
  }

  /// 读一个字面量，返回 (模板, 样例, 有没有变量)。
  (String, String, bool) _literal() {
    var raw = false;
    if (s[i] == 'r') {
      raw = true;
      i++;
    }
    final q = s[i];
    final triple = s.startsWith(q * 3, i);
    final close = triple ? q * 3 : q;
    i += close.length;
    final template = StringBuffer();
    final sample = StringBuffer();
    var interpolated = false;
    while (i < s.length) {
      if (s.startsWith(close, i)) {
        i += close.length;
        break;
      }
      final c = s[i];
      if (!raw && c == r'\' && i + 1 < s.length) {
        final n = s[i + 1];
        final text = switch (n) {
          'n' => '\n',
          'r' => '\r',
          't' => '\t',
          _ => null,
        };
        if (text != null) {
          i += 2;
        } else if (n == 'x' && i + 3 < s.length) {
          template
              .writeCharCode(int.parse(s.substring(i + 2, i + 4), radix: 16));
          sample.writeCharCode(int.parse(s.substring(i + 2, i + 4), radix: 16));
          i += 4;
          continue;
        } else if (n == 'u' && i + 2 < s.length && s[i + 2] == '{') {
          final end = s.indexOf('}', i);
          final code = int.parse(s.substring(i + 3, end), radix: 16);
          template.writeCharCode(code);
          sample.writeCharCode(code);
          i = end + 1;
          continue;
        } else if (n == 'u') {
          final code = int.parse(s.substring(i + 2, i + 6), radix: 16);
          template.writeCharCode(code);
          sample.writeCharCode(code);
          i += 6;
          continue;
        } else {
          i += 2;
        }
        template.write(text ?? n);
        sample.write(text ?? n);
        continue;
      }
      if (!raw && c == r'$' && i + 1 < s.length) {
        if (s[i + 1] == '{') {
          final start = i;
          i += 2;
          var depth = 1;
          while (i < s.length && depth > 0) {
            if (_atString()) {
              _group();
              continue;
            }
            if (s[i] == '{') depth++;
            if (s[i] == '}') depth--;
            i++;
          }
          template.write(s.substring(start, i));
          sample.write(sampleValue);
          interpolated = true;
          continue;
        }
        final name = RegExp(r'[A-Za-z_][A-Za-z0-9_]*').matchAsPrefix(s, i + 1);
        if (name != null) {
          template.write(s.substring(i, name.end));
          sample.write(sampleValue);
          interpolated = true;
          i = name.end;
          continue;
        }
      }
      template.write(c);
      sample.write(c);
      i++;
    }
    return (template.toString(), sample.toString(), interpolated);
  }
}
