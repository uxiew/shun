import 'dart:math' as math;

import 'terminal_session_adapter.dart';

/// 画中画小窗显示的最近几行。
String terminalPictureInPictureText(
  TerminalSessionAdapter terminal, {
  int maxLines = 18,
  int maxColumns = 96,
}) {
  final total = terminal.lineCount;
  if (total == 0 || maxLines <= 0 || maxColumns <= 0) return '';
  final scanCount = math.max(terminal.viewRows, maxLines * 3);
  final start = math.max(0, total - scanCount);
  final result = <String>[];
  for (var index = start; index < total; index++) {
    var text = terminal.lineAt(index).text.trimRight();
    if (text.length > maxColumns) text = text.substring(0, maxColumns);
    result.add(text);
  }
  while (result.isNotEmpty && result.last.isEmpty) {
    result.removeLast();
  }
  if (result.length > maxLines) {
    result.removeRange(0, result.length - maxLines);
  }
  while (result.isNotEmpty && result.first.isEmpty) {
    result.removeAt(0);
  }
  return result.every((line) => line.isEmpty) ? '等待终端输出…' : result.join('\n');
}

/// Returns a bounded snapshot of recent terminal output for Catty Agent.
///
/// Physical lines that were soft-wrapped are joined back together. The
/// result intentionally excludes unlimited scrollback so a chat request cannot
/// accidentally upload the entire terminal history.
String terminalAiContextText(
  TerminalSessionAdapter terminal, {
  int maxLines = 80,
  int maxColumns = 240,
  int maxCharacters = 12000,
}) {
  final total = terminal.lineCount;
  if (total == 0 || maxLines <= 0 || maxColumns <= 0 || maxCharacters <= 0) {
    return '';
  }

  final scanCount = math.max(terminal.viewRows * 2, maxLines * 4);
  var start = math.max(0, total - scanCount);
  while (start > 0 && terminal.lineAt(start).wrapped) {
    start--;
  }

  final result = <String>[];
  for (var index = start; index < total; index++) {
    final line = terminal.lineAt(index);
    var text = line.text.trimRight();
    if (text.length > maxColumns) {
      text = text.substring(0, maxColumns);
    }
    if (line.wrapped && result.isNotEmpty) {
      result[result.length - 1] += text;
    } else {
      result.add(text);
    }
  }

  while (result.isNotEmpty && result.last.isEmpty) {
    result.removeLast();
  }
  while (result.isNotEmpty && result.first.isEmpty) {
    result.removeAt(0);
  }
  if (result.length > maxLines) {
    result.removeRange(0, result.length - maxLines);
  }

  final output = result.join('\n');
  if (output.length <= maxCharacters) return output;
  return output.substring(output.length - maxCharacters);
}
