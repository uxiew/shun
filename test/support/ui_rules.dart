/// UI 硬规矩（docs/dev/ui-text.md）的扫描引擎，给 test/ui_rules_test.dart、
/// test/ui_rules_bypass_test.dart、test/secret_content_test.dart 用（R84）。
///
/// 以前只认写死的 TextField / LText 这几个名字：换成 `prism.ListRow`、或者本地包一层改个名，
/// 字再长、框再挤都查不到。现在从源码里**发现**：
/// - 哪些类把自己的 String 参数画成正文、副标题或输入框提示（本地类和固定版本的 Prism 源码都看，
///   包了几层也一路追下去）；
/// - 哪些类里面就是一个输入框（FormGap 规则按输入框对待）；
/// - 哪些类里有打码输入框却没关输入法学习（调用它就算漏）。
/// 上限、目录范围一个不放宽。不是完整的语法分析，只靠括号、字面量和注释，误差见各函数说明。
library;

import 'dart:convert';
import 'dart:io';

import 'dart_strings.dart';
import 'dart_ui_scan.dart';

/// 一句常驻文字落在哪种位置。上限：正文 30 个汉字，副标题和输入框提示 16 个。
enum TextKind {
  helper(16),
  subtitle(16),
  paragraph(30);

  const TextKind(this.limit);
  final int limit;

  TextKind stricter(TextKind? other) =>
      other == null || other.limit > limit ? this : other;
}

class UiSource {
  UiSource(this.path, this.source, {this.prism = false})
      : blanked = blankLiterals(source);

  /// 用来报错的路径。
  final String path;
  final String source;
  final String blanked;

  /// 这是 prism_ui 自己的源码：里面的类名一律记成 `prism.X`。
  final bool prism;

  /// 本文件给 prism_ui 起的别名（`as prism`）；不带别名导入时，裸类名也可能是 Prism 的。
  late final Set<String> prismAliases = {
    for (final match in RegExp(
      r'''import\s+['"]package:prism_ui/[^'"]+['"]\s+as\s+(\w+)''',
    ).allMatches(source))
      match.group(1)!,
  };
  late final bool prismBare = RegExp(
    r'''import\s+['"]package:prism_ui/[^'"]+['"]\s*(?:show[^;]*|hide[^;]*)?;''',
  ).hasMatch(source);
}

/// lib/presentation 下除本地化表以外的源码，按路径排序。
List<UiSource> presentationSources() => [
      for (final entity
          in Directory('lib/presentation').listSync(recursive: true))
        if (entity is File &&
            entity.path.endsWith('.dart') &&
            !entity.path.contains('/localization/'))
          UiSource(entity.path, entity.readAsStringSync()),
    ]..sort((a, b) => a.path.compareTo(b.path));

/// pubspec.lock 固定的那份 prism_ui 源码（.dart_tool/package_config.json 指到的目录）。
/// 找不到就抛错：扫不到 Prism 时不能悄悄当成「没有 Prism 控件」。
List<UiSource> prismSources() {
  final config = jsonDecode(
    File('.dart_tool/package_config.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final package = (config['packages'] as List)
      .cast<Map<String, dynamic>>()
      .singleWhere((package) => package['name'] == 'prism_ui');
  final root = Uri.parse(package['rootUri'] as String)
      .resolve(package['packageUri'] as String);
  final dir = Directory.fromUri(root);
  final files = [
    for (final entity in dir.listSync(recursive: true))
      if (entity is File && entity.path.endsWith('.dart'))
        UiSource(entity.path, entity.readAsStringSync(), prism: true),
  ]..sort((a, b) => a.path.compareTo(b.path));
  if (files.length < 50) {
    throw StateError('prism_ui 源码只找到 ${files.length} 个文件：${dir.path}');
  }
  return files;
}

/// 输入框本身。Material 的和 Prism 的同名，分开记。
const _baseFields = {
  'TextField',
  'TextFormField',
  'DropdownButtonFormField',
  'prism.TextField',
  'prism.TextFormField',
};

/// 把一句字画出来的调用（字是第一个位置参数）。`localized(…)` 这类只是换个语言，透明。
const _textCalls = {
  'Text',
  'LText',
  'SelectableText',
  'LSelectableText',
  'catalogLine',
};
const _transparentCalls = {'', 'localized'};

/// 这些调用里的字是点了才看到、或者只闪一下的，不算常驻。
const _transientCalls = {
  'AlertDialog',
  'SimpleDialog',
  'SnackBar',
  'showHint',
  'HintButton',
  'Tooltip',
};

/// 读屏和悬停提示用的参数：不画在页面上。
const _transientArguments = {'tooltip', 'semanticsLabel'};

/// 画在列表行副标题那一格的参数。
const _subtitleArguments = {'subtitle', 'details'};

/// 只包一层、不改变「这是个输入框」的部件：`Padding(child: TextField(…))` 还是输入框。
const _passThrough = {
  'Row',
  'Padding',
  'SecretContent',
  'Semantics',
  'Expanded',
  'Flexible',
  'Focus',
  'KeyedSubtree',
};

final _callName = RegExp(r'([A-Za-z_][\w.]*)(?:<[^()]*>)?\s*\(');

class _WidgetClass {
  _WidgetClass(this.name, this.source);

  final String name;
  final UiSource source;

  /// 类体（含它的 State 类体）在 [UiSource.blanked] 里的 [start, end)。
  final bodies = <(int, int)>[];
  final stringFields = <String>{};
  String? firstPositional;
}

class UiCatalog {
  UiCatalog(List<UiSource> sources) : _sources = sources {
    for (final source in sources) {
      if (source.prism) _prismClasses.addAll(_declaredClasses(source));
    }
    for (final source in sources) {
      _collectClasses(source);
    }
    _discover();
  }

  final List<UiSource> _sources;
  final _prismClasses = <String>{};
  final _classes = <String, _WidgetClass>{};

  /// 类名 → 参数名 → 这个参数会画成哪种字。
  final roles = <String, Map<String, TextKind>>{};

  /// 里面就是一个输入框的类（含 Material / Prism 输入框本身）。
  final fields = <String>{..._baseFields};

  /// 规则用的类名：Prism 的记成 `prism.X`，命名构造和别的导入别名去掉。
  String canonical(String call, UiSource in_) {
    final parts = call.split('.');
    var i = 0;
    var prism = in_.prism;
    while (i < parts.length - 1 && !_isType(parts[i])) {
      if (in_.prismAliases.contains(parts[i])) prism = true;
      i++;
    }
    final name = parts[i];
    if (!_isType(name)) return name;
    if (prism && _prismClasses.contains(name)) return 'prism.$name';
    if (in_.prismBare &&
        _prismClasses.contains(name) &&
        !_classes.containsKey(name)) {
      return 'prism.$name';
    }
    return name;
  }

  static bool _isType(String name) => RegExp(r'^_?[A-Z]').hasMatch(name);

  static String _bare(String name) =>
      name.startsWith('prism.') ? name.substring(6) : name;

  Iterable<String> _declaredClasses(UiSource source) => RegExp(
        r'\bclass\s+(\w+)',
      ).allMatches(source.blanked).map((match) => match.group(1)!);

  void _collectClasses(UiSource source) {
    final declaration = RegExp(
      r'\bclass\s+(\w+)(?:\s*<[^{]*?>)?\s+extends\s+([^{]+?)\s*\{',
    );
    for (final match in declaration.allMatches(source.blanked)) {
      final open = match.end - 1;
      final close = _matching(source.blanked, open);
      final extendsClause = match.group(2)!;
      final state =
          RegExp(r'^(?:\w+\.)?(?:Consumer)?State<\s*(\w+)').firstMatch(
        extendsClause,
      );
      final owner = state?.group(1) ?? match.group(1)!;
      final name = source.prism && _prismClasses.contains(owner)
          ? 'prism.$owner'
          : owner;
      final cls = _classes.putIfAbsent(name, () => _WidgetClass(name, source));
      if (!identical(cls.source, source)) continue; // 重名的类：只认第一个文件
      cls.bodies.add((open + 1, close));
      if (state != null) continue;
      final body = source.blanked.substring(open + 1, close);
      for (final field
          in RegExp(r'\bfinal\s+String\??\s+(\w+)\s*;').allMatches(body)) {
        cls.stringFields.add(field.group(1)!);
      }
      final ctor = RegExp('\\b${RegExp.escape(owner)}\\s*\\(\\s*this\\.(\\w+)')
          .firstMatch(body);
      cls.firstPositional = ctor?.group(1);
    }
  }

  static int _matching(String text, int open) {
    var depth = 0;
    for (var i = open; i < text.length; i++) {
      if ('([{'.contains(text[i])) depth++;
      if (')]}'.contains(text[i]) && --depth == 0) return i;
    }
    return text.length;
  }

  /// [chain] 末端那一层（跳过 `localized(…)`、括号）落在什么位置；不是常驻文字时为 null。
  TextKind? kindAt(
    List<({String call, String? argument})> chain,
    UiSource source,
  ) {
    for (final frame in chain) {
      if (_transientCalls.contains(_bare(canonical(frame.call, source))) ||
          _transientArguments.contains(frame.argument)) {
        return null;
      }
    }
    var index = chain.length - 1;
    while (index >= 0 &&
        chain[index].argument == null &&
        _transparentCalls.contains(chain[index].call)) {
      index--;
    }
    if (index < 0) return null;
    final inner = chain[index];
    final name = canonical(inner.call, source);
    TextKind? kind;
    if (inner.argument == 'helperText') kind = TextKind.helper.stricter(kind);
    // ShunListRow 的 details 画在副标题那一格（R87 把首页、目录的状态行从 subtitle 挪进了 details）：
    // 不算进来，挪一下位置上限就从 16 变成 30。
    if (chain.any((frame) => _subtitleArguments.contains(frame.argument))) {
      kind = TextKind.subtitle.stricter(kind);
    }
    if (inner.argument == null && _textCalls.contains(_bare(name))) {
      kind = TextKind.paragraph.stricter(kind);
    }
    final parameter = inner.argument ?? _classes[name]?.firstPositional;
    final role = roles[name]?[parameter];
    if (role != null) kind = role.stricter(kind);
    return kind;
  }

  void _discover() {
    for (var round = 0; round < 20; round++) {
      var changed = false;
      for (final cls in _classes.values) {
        final source = cls.source;
        for (final field in cls.stringFields) {
          final use = RegExp(
            '(?:(?<=widget\\.)|(?<![\\w.\$]))${RegExp.escape(field)}\\b',
          );
          for (final (start, end) in cls.bodies) {
            final body = source.blanked.substring(start, end);
            for (final match in use.allMatches(body)) {
              final before = body.substring(0, match.start);
              final after = body.substring(match.end);
              // 声明、构造参数、命名参数的名字本身（`hint: hint` 前一个）都不是在用这个值。
              if (before.endsWith('this.') ||
                  RegExp(r'String\??\s+$').hasMatch(before) ||
                  RegExp(r'[(,\[{]\s*$').hasMatch(before) &&
                      RegExp(r'^\s*:(?!:)').hasMatch(after)) {
                continue;
              }
              final kind = kindAt(callChain(body, match.start), source);
              if (kind == null) continue;
              final known = roles[cls.name]?[field];
              final next = kind.stricter(known);
              if (next != known) {
                (roles[cls.name] ??= {})[field] = next;
                changed = true;
              }
            }
          }
        }
        if (!fields.contains(cls.name) && _containsField(cls)) {
          fields.add(cls.name);
          changed = true;
        }
      }
      if (!changed) return;
    }
    throw StateError('UI 规则的发现 20 轮没收敛');
  }

  /// 包装输入框：类体里恰好一个输入框，自己不是对话框、面板或整页。
  /// 整页（HostEditor、HomeShell）里也有输入框，但它们不会和输入框并排放在一张表单里。
  bool _containsField(_WidgetClass cls) {
    var count = 0;
    for (final (start, end) in cls.bodies) {
      final body = cls.source.blanked.substring(start, end);
      if (RegExp(
              r'\b(?:Scaffold|AlertDialog|Dialog|SimpleDialog|BottomSheet)\(|'
              r'\bshow\w*(?:Dialog|Sheet)\b')
          .hasMatch(body)) {
        return false;
      }
      for (final match in _callName.allMatches(body)) {
        final name = canonical(match.group(1)!, cls.source);
        if (name != cls.name && fields.contains(name)) count++;
      }
    }
    return count == 1;
  }

  /// [element] 开头的调用名（去掉 const），没有就是 null。
  String? _leading(String element, UiSource source) {
    final match = RegExp(r'^(?:const\s+)?([A-Za-z_][\w.]*)(?:<[^()]*>)?\s*\(')
        .firstMatch(element);
    return match == null ? null : canonical(match.group(1)!, source);
  }

  bool isField(String element, UiSource source) {
    final leading = _leading(element, source);
    if (leading == null) return false;
    if (fields.contains(leading)) return true;
    if (!_passThrough.contains(_bare(leading))) return false;
    return _callName.allMatches(element).any(
          (match) => fields.contains(canonical(match.group(1)!, source)),
        );
  }

  /// 上下相邻的输入框之间不是 FormGap（直接挨着，或写成了 SizedBox）。
  List<String> formGapProblems() {
    final wrong = <String>[];
    for (final source in _sources) {
      if (source.prism) continue;
      final blanked = source.blanked;
      for (final open in childLists(blanked)) {
        // 横排（Row、Wrap）里并排的框之间是左右间距，不归 FormGap 管。
        final owner = callChain(blanked, open).lastOrNull?.call ?? '';
        if (const {'Row', 'Wrap'}.contains(_bare(canonical(owner, source)))) {
          continue;
        }
        final elements = [
          for (final (offset, text) in listElements(blanked, open))
            (offset, withoutCollectionIf(text)),
        ];
        for (var i = 1; i < elements.length; i++) {
          final (offset, element) = elements[i];
          if (!isField(element, source)) continue;
          final (_, before) = elements[i - 1];
          final line = lineOf(blanked, offset);
          if (isField(before, source)) {
            wrong.add('${source.path}:$line 和上一个输入框之间没有间隔');
          } else if (before.startsWith(RegExp(r'(?:const\s+)?SizedBox\('))) {
            final above = i >= 2 ? elements[i - 2].$2 : '';
            if (isField(above, source)) {
              wrong.add('${source.path}:$line 间隔写成了 $before');
            }
          }
        }
      }
    }
    return wrong;
  }

  /// 超过上限的常驻文字。
  Iterable<({String where, TextKind kind, int count, String text})>
      longText() sync* {
    final han = RegExp(r'[一-鿿]');
    for (final source in _sources) {
      if (source.prism) continue;
      for (final string in dartStrings(source.source)) {
        final count = han.allMatches(string.sample).length;
        if (count <= TextKind.helper.limit) continue;
        final kind = kindAt(callChain(source.blanked, string.offset), source);
        if (kind == null || count <= kind.limit) continue;
        yield (
          where: '${source.path}:${string.line}',
          kind: kind,
          count: count,
          text: string.template,
        );
      }
    }
  }

  /// 里面有打码输入框、却没把输入法学习 / 联想 / 自动更正全关掉的类（Prism 的也算）。
  /// lib 里调用它们，就等于用了一个会让输入法记住密码的框。
  /// 输入框本身（TextField 等）不算：它们把开关原样交给调用处，调用处由 [secretFieldProblems] 查。
  Set<String> leakySecretClasses() => {
        for (final cls in _classes.values)
          if (!_baseFields.contains(cls.name) &&
              cls.bodies.any((body) => secretFieldProblems(cls.source.source,
                      from: body.$1, to: body.$2)
                  .isNotEmpty))
            cls.name,
      };

  /// lib 里对 [leaky] 这些类的调用。
  List<String> callsTo(Set<String> leaky) => [
        for (final source in _sources)
          if (!source.prism)
            for (final match in _callName.allMatches(source.blanked))
              if (leaky.contains(canonical(match.group(1)!, source)))
                '${source.path}:${lineOf(source.blanked, match.start)} '
                    '${canonical(match.group(1)!, source)}',
      ];

  /// 类体里写了 `obscureText:` 的类：放在页面上就是秘密输入。
  /// 自己包了 SecretContent 的不算进 [uncovered]。
  ({Set<String> secret, Set<String> covered}) secretClasses() {
    final secret = <String>{};
    final covered = <String>{};
    for (final cls in _classes.values) {
      for (final (start, end) in cls.bodies) {
        final body = cls.source.source.substring(start, end);
        if (body.contains('obscureText:') ||
            body.contains('SecretTextFormField(')) {
          secret.add(cls.name);
        }
        if (body.contains('SecretContent(')) covered.add(cls.name);
      }
    }
    return (secret: secret, covered: covered);
  }

  /// [source] 里调用了 [names] 中的类就为真。
  bool calls(UiSource source, Set<String> names) => _callName
      .allMatches(source.blanked)
      .any((match) => names.contains(canonical(match.group(1)!, source)));
}

/// 命名参数的值：到逗号、换行或右括号为止。
RegExp argument(String name) => RegExp('\\b$name:\\s*([^,\\n)]+)');

/// [source] 的 [from, to) 里每个带 `obscureText:` 的 TextField / TextFormField（Material 或 Prism），
/// 三个输入法开关不是 false（或「打码时才是秘密」的 `!obscured`）的，各报一条。
List<String> secretFieldProblems(String source, {int from = 0, int? to}) {
  final end = to ?? source.length;
  final problems = <String>[];
  for (final match in argument('obscureText').allMatches(source, from)) {
    if (match.start >= end) break;
    final call = fieldCall(source, match.start);
    if (call == null) {
      problems.add('obscureText 不在 TextField/TextFormField 里');
      continue;
    }
    // 只有「打码时才是秘密」的框（Tailscale 目录的通用对话框）可以写成取反。
    final obscured = match.group(1)!.trim();
    for (final name in const [
      'enableIMEPersonalizedLearning',
      'enableSuggestions',
      'autocorrect',
    ]) {
      final value = argument(name).firstMatch(call)?.group(1)?.trim();
      if (value != 'false' && value != '!$obscured') {
        problems.add('obscureText: $obscured 的框 $name 是 $value');
      }
    }
  }
  return problems;
}

/// [at] 所在的那个 TextField(...) / TextFormField(...) 调用的整段源码；不在里面时为 null。
/// 往前找最近的构造调用，再往后配括号，跳过字符串里的括号。
String? fieldCall(String source, int at) {
  final starts = RegExp(r'\b(?:TextField|TextFormField)\(')
      .allMatches(source.substring(0, at))
      .toList();
  if (starts.isEmpty) return null;
  final open = starts.last.end - 1;
  var depth = 0;
  String? quote;
  for (var i = open; i < source.length; i++) {
    final c = source[i];
    if (quote != null) {
      if (c == r'\') {
        i++;
      } else if (c == quote) {
        quote = null;
      }
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
    } else if (c == '(') {
      depth++;
    } else if (c == ')' && --depth == 0) {
      return i > at ? source.substring(open, i + 1) : null;
    }
  }
  return null;
}
