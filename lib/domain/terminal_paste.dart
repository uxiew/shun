/// 粘贴前看一眼（R19，SEC10、TER09）：剪贴板里的东西发到终端前先算出风险，界面据此决定直接粘贴还是先让用户看。
///
/// 这里只做两件事：把内容整理成「预览里看到的就是要发的」，以及数出需要提醒的地方。
/// 它不判断远端会不会执行——那取决于远端程序（有没有开 bracketed paste、怎么处理粘贴），App 保证不了。
class PasteReview {
  PasteReview._({
    required this.text,
    required this.trailingNewlines,
    required this.removedControls,
    required this.invisibleFormatting,
    required this.tabs,
  });

  /// 整理剪贴板内容：
  /// - `\r\n`、单独的 `\r` 统一成 `\n`（Windows 复制来的文字不会变成双回车）；
  /// - 末尾的换行去掉（多数「复制命令」带一个，没开 bracketed paste 时它就是回车，粘贴即执行）；
  /// - 控制字符（换行、Tab 以外的 C0、DEL、C1）去掉：在终端里它们是按键（Ctrl-C、Esc、Ctrl-P 翻历史……），
  ///   不是文字。引擎粘贴时也会清掉一部分，但各引擎清的范围不同（Ghostty 不清 Ctrl-P、Ctrl-A），这里统一先去掉。
  factory PasteReview.of(String clipboard) {
    final normalized =
        clipboard.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final kept = StringBuffer();
    final removed = <String, int>{};
    var invisible = 0;
    var tabs = 0;
    for (final rune in normalized.runes) {
      if (rune == 0x0a) {
        kept.writeCharCode(rune);
      } else if (rune == 0x09) {
        tabs++;
        kept.writeCharCode(rune);
      } else if (rune < 0x20 ||
          rune == 0x7f ||
          (rune >= 0x80 && rune <= 0x9f)) {
        final name = controlName(rune);
        removed[name] = (removed[name] ?? 0) + 1;
      } else {
        if (_invisibleFormatting(rune)) invisible++;
        kept.writeCharCode(rune);
      }
    }
    var text = kept.toString();
    var trailing = 0;
    while (text.endsWith('\n')) {
      text = text.substring(0, text.length - 1);
      trailing++;
    }
    return PasteReview._(
      text: text,
      trailingNewlines: trailing,
      removedControls: Map.unmodifiable(removed),
      invisibleFormatting: invisible,
      tabs: tabs,
    );
  }

  /// 要粘贴的文字（已整理）。
  final String text;

  /// 末尾去掉了几个换行。
  final int trailingNewlines;

  /// 去掉的控制字符，按名字计数（「Esc」「Ctrl-C」……）。
  final Map<String, int> removedControls;

  /// 看不见、却能改显示顺序的排版字符个数（零宽字符、从右到左覆盖等）。
  /// 它们能让预览里看到的顺序和实际发出去的不一样，所以要提醒。
  final int invisibleFormatting;

  final int tabs;

  /// 超过这么多字也先给用户看：一眼看不完的内容不该默默发出去。
  static const longText = 4096;

  int get lines => text.isEmpty ? 0 : '\n'.allMatches(text).length + 1;

  bool get multiline => lines > 1;

  /// 一行、没去掉任何东西、不长：直接粘贴，不打扰。
  bool get needsReview =>
      multiline ||
      trailingNewlines > 0 ||
      removedControls.isNotEmpty ||
      invisibleFormatting > 0 ||
      text.length > longText;

  /// 控制字符在终端里的叫法：0x03 是 Ctrl-C，0x1b 是 Esc。
  static String controlName(int rune) => switch (rune) {
        0x00 => 'NUL',
        0x08 => 'Backspace',
        0x1b => 'Esc',
        0x7f => 'Delete',
        < 0x20 => 'Ctrl-${String.fromCharCode(rune + 0x40)}',
        _ => 'C1 0x${rune.toRadixString(16).toUpperCase()}',
      };

  static bool _invisibleFormatting(int rune) =>
      (rune >= 0x200b && rune <= 0x200f) || // 零宽空格/连接符、左右标记
      (rune >= 0x202a && rune <= 0x202e) || // 方向嵌入、覆盖
      (rune >= 0x2066 && rune <= 0x2069) || // 方向隔离
      rune == 0x061c ||
      rune == 0xfeff;
}
