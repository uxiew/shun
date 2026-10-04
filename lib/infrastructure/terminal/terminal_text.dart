import 'dart:math' as math;

import 'terminal_session_adapter.dart';

/// 画中画小窗显示的最近几行。
String terminalPictureInPictureText(
  TerminalSessionAdapter terminal, {
  int maxLines = 18,
  int maxColumns = 96,
}) {
  if (maxLines <= 0 || maxColumns <= 0) return '';
  final lines = terminal.recentLines(math.max(terminal.viewRows, maxLines * 3));
  if (lines.isEmpty) return '';
  final result = <String>[];
  for (final line in lines) {
    var text = line.text.trimRight();
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

const _wrapLookBehind = 64;

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
  if (maxLines <= 0 || maxColumns <= 0 || maxCharacters <= 0) return '';

  final scanCount = math.max(terminal.viewRows * 2, maxLines * 4);
  // 多取一些：窗口第一行可能是一个长行折下来的后半截，往前补到这一长行的开头。
  // 补的行数有上限，超长的一行（比如几千列的 JSON）就从窗口里能看到的部分开始。
  final lines = terminal.recentLines(scanCount + _wrapLookBehind);
  if (lines.isEmpty) return '';
  var start = math.max(0, lines.length - scanCount);
  while (start > 0 && lines[start].wrapped) {
    start--;
  }

  final result = <String>[];
  for (final line in lines.skip(start)) {
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
