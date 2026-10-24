import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'translations_en.dart';

class ShunLocalizations {
  const ShunLocalizations._();

  static String _language = 'zh-CN';

  static String get language => _language;
  static bool get isEnglish => _language == 'en';

  static void use(String language) {
    _language = language == 'en' ? 'en' : 'zh-CN';
  }

  static String text(String source) {
    if (!isEnglish || source.isEmpty) return source;
    final whole = _whole(source);
    if (whole != null) return whole;
    var value = source;
    for (final replacement in englishReplacements) {
      value = value.replaceAll(replacement.$1, replacement.$2);
    }
    return value.trim();
  }
}

/// 整句查表：先精确，再按带变量的模板键。都没有返回 null，交给片段表。
String? _whole(String source) =>
    englishTranslations[source] ?? _matchTemplate(source);

/// 英文表里键写成源码原样的 `'删除 ${entry.name}？'` 这种，运行时拿到的却是填好值的句子，
/// 精确查表永远对不上，以前就落到片段表，逐词替换成「正in 切 to …」这种半中半英。
/// 这里把这类键当模板：中文部分逐字对上、变量处任意，对上了就把值原样填进英文的同名变量。
/// 值本身若也是一句有整句翻译的系统消息（比如 `$error`），顺带翻掉。
///
/// 值里有中文又翻不出来时不算对上：多半是模板太宽（「经$proxy」会把「经代理连接失败」整句吞掉）、
/// 或者只对上了前半句。退回片段表，和没有模板时一样。代价是用户起的中文名字（主机名
/// 「家里」）也走片段表，和以前一样，不会更差。
String? _matchTemplate(String source) {
  for (final template in _templates) {
    final values = template.match(source);
    if (values == null) continue;
    final rendered = <String>[];
    for (final value in values) {
      final translated = _whole(value);
      if (translated == null && LocalizationTemplate._han.hasMatch(value)) {
        break;
      }
      rendered.add(translated ?? value);
    }
    if (rendered.length < values.length) continue;
    return template.render(rendered);
  }
  return null;
}

final List<LocalizationTemplate> _templates = () {
  final templates = <LocalizationTemplate>[
    for (final entry in englishTranslations.entries)
      if (LocalizationTemplate.parse(entry.key, entry.value)
          case final template?)
        template,
  ];
  // 先试中文字面多的：「插件 ${id} 自己联网」要排在「插件 $id」前面，否则后者把整句吞掉。
  templates.sort((a, b) => b.literalLength.compareTo(a.literalLength));
  return templates;
}();

/// 一条带变量的整句翻译。`parse` 只认中文字面里有汉字的键：全是变量和标点的键
/// （比如 `'${a}：${b}'`）什么都能对上，不收。
class LocalizationTemplate {
  LocalizationTemplate._(this._pattern, this._names, this._english, this._head,
      this._tail, this.literalLength);

  static final _han = RegExp(r'[一-鿿]');

  final RegExp _pattern;
  final List<String> _names;
  final List<(bool, String)> _english;
  final String _head;
  final String _tail;
  final int literalLength;

  /// 中文键里的变量名（源码原样，比如 `${entry.name}`、`$error`）。
  List<String> get names => _names;

  /// 英文里出现、中文键里却没有的变量。不为空说明英文写错了，显示出来会是 `${…}` 原文。
  List<String> get unknownEnglishNames => [
        for (final (isName, text) in _english)
          if (isName && !_names.contains(text)) text,
      ];

  static LocalizationTemplate? parse(String chinese, String english) {
    final parts = splitPlaceholders(chinese);
    final names = [
      for (final (isName, text) in parts)
        if (isName) text
    ];
    if (names.isEmpty) return null;
    final literals = [
      for (final (isName, text) in parts)
        if (!isName) text
    ];
    if (!literals.any(_han.hasMatch)) return null;
    final pattern = StringBuffer('^');
    for (final (isName, text) in parts) {
      pattern.write(isName ? '(.*?)' : RegExp.escape(text));
    }
    pattern.write(r'$');
    return LocalizationTemplate._(
      RegExp(pattern.toString(), dotAll: true),
      names,
      splitPlaceholders(english),
      parts.first.$1 ? '' : parts.first.$2,
      parts.last.$1 ? '' : parts.last.$2,
      literals.fold(0, (sum, text) => sum + text.length),
    );
  }

  /// 对上了返回每个变量的值（和 [names] 一一对应），对不上返回 null。
  List<String>? match(String source) {
    if (!source.startsWith(_head) || !source.endsWith(_tail)) return null;
    final found = _pattern.firstMatch(source);
    if (found == null) return null;
    return [for (var i = 1; i <= found.groupCount; i++) found.group(i)!];
  }

  String render(List<String> values) {
    final out = StringBuffer();
    for (final (isName, text) in _english) {
      final index = isName ? _names.indexOf(text) : -1;
      out.write(index < 0 ? text : values[index]);
    }
    return out.toString();
  }
}

/// 按 Dart 插值的写法切开：`$name`、`${表达式}`（里面可以再有括号和引号）算变量，其余是字面。
/// 返回 (是不是变量, 原文)。
List<(bool, String)> splitPlaceholders(String text) {
  final parts = <(bool, String)>[];
  final literal = StringBuffer();
  var i = 0;
  void flush() {
    if (literal.isEmpty) return;
    parts.add((false, literal.toString()));
    literal.clear();
  }

  while (i < text.length) {
    if (text[i] == r'$' && i + 1 < text.length) {
      if (text[i + 1] == '{') {
        final end = _closingBrace(text, i + 2);
        if (end > 0) {
          flush();
          parts.add((true, text.substring(i, end + 1)));
          i = end + 1;
          continue;
        }
      }
      final name = _identifier.matchAsPrefix(text, i + 1);
      if (name != null) {
        flush();
        parts.add((true, text.substring(i, name.end)));
        i = name.end;
        continue;
      }
    }
    literal.write(text[i]);
    i++;
  }
  flush();
  return parts;
}

final _identifier = RegExp(r'[A-Za-z_][A-Za-z0-9_]*');

int _closingBrace(String text, int from) {
  var depth = 1;
  String? quote;
  for (var i = from; i < text.length; i++) {
    final c = text[i];
    if (quote != null) {
      if (c == quote) quote = null;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
    } else if (c == '{') {
      depth++;
    } else if (c == '}' && --depth == 0) {
      return i;
    }
  }
  return -1;
}

String localized(String source) => ShunLocalizations.text(source);

class LText extends StatelessWidget {
  const LText(
    this.data, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  });

  final String data;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final Locale? locale;
  final bool? softWrap;
  final TextOverflow? overflow;
  final TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final TextWidthBasis? textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final Color? selectionColor;

  @override
  Widget build(BuildContext context) => Text(
        localized(data),
        style: style,
        strutStyle: strutStyle,
        textAlign: textAlign,
        textDirection: textDirection,
        locale: locale,
        softWrap: softWrap,
        overflow: overflow,
        textScaler: textScaler,
        maxLines: maxLines,
        semanticsLabel:
            semanticsLabel == null ? null : localized(semanticsLabel!),
        textWidthBasis: textWidthBasis,
        textHeightBehavior: textHeightBehavior,
        selectionColor: selectionColor,
      );
}

class LSelectableText extends StatelessWidget {
  const LSelectableText(
    this.data, {
    super.key,
    this.focusNode,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.textScaler,
    this.showCursor = false,
    this.autofocus = false,
    this.minLines,
    this.maxLines,
    this.cursorWidth = 2,
    this.cursorHeight,
    this.cursorRadius,
    this.cursorColor,
    this.enableInteractiveSelection = true,
    this.onTap,
    this.scrollPhysics,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.contextMenuBuilder,
    this.magnifierConfiguration,
    this.dragStartBehavior = DragStartBehavior.start,
  });

  final String data;
  final FocusNode? focusNode;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final TextScaler? textScaler;
  final bool showCursor;
  final bool autofocus;
  final int? minLines;
  final int? maxLines;
  final double cursorWidth;
  final double? cursorHeight;
  final Radius? cursorRadius;
  final Color? cursorColor;
  final bool enableInteractiveSelection;
  final GestureTapCallback? onTap;
  final ScrollPhysics? scrollPhysics;
  final TextWidthBasis? textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final EditableTextContextMenuBuilder? contextMenuBuilder;
  final TextMagnifierConfiguration? magnifierConfiguration;
  final DragStartBehavior dragStartBehavior;

  @override
  Widget build(BuildContext context) => SelectableText(
        localized(data),
        focusNode: focusNode,
        style: style,
        strutStyle: strutStyle,
        textAlign: textAlign,
        textDirection: textDirection,
        textScaler: textScaler,
        showCursor: showCursor,
        autofocus: autofocus,
        minLines: minLines,
        maxLines: maxLines,
        cursorWidth: cursorWidth,
        cursorHeight: cursorHeight,
        cursorRadius: cursorRadius,
        cursorColor: cursorColor,
        enableInteractiveSelection: enableInteractiveSelection,
        onTap: onTap,
        scrollPhysics: scrollPhysics,
        textWidthBasis: textWidthBasis,
        textHeightBehavior: textHeightBehavior,
        contextMenuBuilder: contextMenuBuilder,
        magnifierConfiguration: magnifierConfiguration,
        dragStartBehavior: dragStartBehavior,
      );
}

class LInputDecoration extends InputDecoration {
  LInputDecoration({
    super.icon,
    super.label,
    String? labelText,
    super.labelStyle,
    super.floatingLabelStyle,
    String? helperText,
    super.helperStyle,
    super.helperMaxLines,
    String? hintText,
    super.hintStyle,
    super.hintTextDirection,
    super.hintMaxLines,
    String? errorText,
    super.errorStyle,
    super.errorMaxLines,
    super.floatingLabelBehavior,
    super.floatingLabelAlignment,
    super.isCollapsed,
    super.isDense,
    super.contentPadding,
    super.prefixIcon,
    super.prefixIconConstraints,
    super.prefix,
    String? prefixText,
    super.prefixStyle,
    super.prefixIconColor,
    super.suffixIcon,
    super.suffix,
    String? suffixText,
    super.suffixStyle,
    super.suffixIconColor,
    String? counterText,
    super.counter,
    super.counterStyle,
    super.filled,
    super.fillColor,
    super.focusColor,
    super.hoverColor,
    super.error,
    super.errorBorder,
    super.focusedBorder,
    super.focusedErrorBorder,
    super.disabledBorder,
    super.enabledBorder,
    super.border,
    super.enabled,
    super.semanticCounterText,
    super.alignLabelWithHint,
    super.constraints,
  }) : super(
          labelText: labelText == null ? null : localized(labelText),
          helperText: helperText == null ? null : localized(helperText),
          hintText: hintText == null ? null : localized(hintText),
          errorText: errorText == null ? null : localized(errorText),
          prefixText: prefixText == null ? null : localized(prefixText),
          suffixText: suffixText == null ? null : localized(suffixText),
          counterText: counterText == null ? null : localized(counterText),
        );
}
