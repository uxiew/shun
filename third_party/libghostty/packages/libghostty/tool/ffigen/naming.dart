/// Naming utilities for C-to-Dart identifier renaming.
library;

const dartKeywords = {
  'true',
  'false',
  'null',
  'this',
  'super',
  'new',
  'const',
  'var',
  'void',
  'if',
  'else',
  'for',
  'while',
  'do',
  'switch',
  'case',
  'default',
  'break',
  'continue',
  'return',
  'throw',
  'try',
  'catch',
  'finally',
  'class',
  'enum',
  'extends',
  'implements',
  'with',
  'abstract',
  'static',
  'final',
  'import',
  'export',
  'library',
  'part',
  'in',
  'is',
  'as',
};

/// Finds the longest SCREAMING_SNAKE prefix shared by all [names], ending
/// at an underscore boundary.
String longestCommonPrefix(List<String> names) {
  if (names.isEmpty) return '';
  if (names.length == 1) {
    final i = names[0].lastIndexOf('_');
    return i >= 0 ? names[0].substring(0, i + 1) : '';
  }
  var prefix = names[0];
  for (var i = 1; i < names.length; i++) {
    while (!names[i].startsWith(prefix)) {
      prefix = prefix.substring(0, prefix.length - 1);
      if (prefix.isEmpty) return '';
    }
  }
  final i = prefix.lastIndexOf('_');
  return i >= 0 ? prefix.substring(0, i + 1) : '';
}

/// Returns [name] escaped if it clashes with a Dart keyword.
String safeName(String name) {
  if (name.isEmpty) return 'arg';
  return dartKeywords.contains(name) ? '${name}_' : name;
}

/// Converts SCREAMING_SNAKE_CASE to camelCase, escaping Dart keywords.
String toCamelCase(String s) {
  if (s.isEmpty) return s;
  final parts = s.split('_');
  final buf = StringBuffer(parts.first.toLowerCase());
  for (var i = 1; i < parts.length; i++) {
    final p = parts[i];
    if (p.isEmpty) continue;
    buf.write(p[0].toUpperCase());
    if (p.length > 1) buf.write(p.substring(1).toLowerCase());
  }
  final result = buf.toString();
  return dartKeywords.contains(result) ? '$result\$' : result;
}
