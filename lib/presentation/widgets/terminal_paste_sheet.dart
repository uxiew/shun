import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/session_controller.dart';
import '../../domain/terminal_paste.dart';
import '../../infrastructure/ssh/ssh_service.dart';
import '../localization/localized_widgets.dart';

/// 快捷键栏的「粘贴」、硬件键盘的粘贴快捷键（R19，SEC10、TER09）。
///
/// 目标在用户动手那一刻定下：[target] 是那条连接本身。读剪贴板要等一下，期间切了标签、断了线，
/// 也只认原来那条，发不了就说明，不改发给别的标签。
/// 一行、没有控制字符、不长的直接粘贴；多行、末尾带换行、有控制字符的先打开预览（可以改）。
Future<void> pasteClipboardInto(
  BuildContext context,
  WidgetRef ref,
  ActiveTerminalSession target,
) async {
  target.terminal.input.clearModifiers();
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  final clipboard = data?.text ?? '';
  if (!context.mounted || clipboard.isEmpty) return;
  final review = PasteReview.of(clipboard);
  if (review.needsReview) {
    await showTerminalPasteSheet(context, target: target, text: clipboard);
    return;
  }
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    ref.read(sessionControllerProvider.notifier).pasteInto(target, review.text);
  } on TerminalTargetChangedException catch (error) {
    messenger?.showSnackBar(SnackBar(content: LText(error.toString())));
  }
}

/// 粘贴预览，也是多行编辑框：[text] 为空时就是空白的编辑框（长按快捷键栏的「粘贴」打开）。
///
/// 在框里按回车只是换行，什么都不发；只有点「粘贴」或「粘贴并回车」才发，默认的「粘贴」不加回车。
Future<void> showTerminalPasteSheet(
  BuildContext context, {
  required ActiveTerminalSession target,
  String text = '',
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => TerminalPasteSheet(target: target, text: text),
    );

class TerminalPasteSheet extends ConsumerStatefulWidget {
  const TerminalPasteSheet({
    super.key,
    required this.target,
    required this.text,
  });

  final ActiveTerminalSession target;
  final String text;

  @override
  ConsumerState<TerminalPasteSheet> createState() => _TerminalPasteSheetState();
}

class _TerminalPasteSheetState extends ConsumerState<TerminalPasteSheet> {
  late ActiveTerminalSession _target = widget.target;

  /// 剪贴板原文整理时去掉的东西（控制字符、末尾换行）。编辑框里只放整理后的文字，
  /// 所以这些提醒要从原文算，不能从编辑框算。
  late final _original = PasteReview.of(widget.text);
  late final _editor = TextEditingController(text: _original.text);
  String? _error;

  @override
  void initState() {
    super.initState();
    _editor.addListener(_onEdited);
  }

  @override
  void dispose() {
    _editor.dispose();
    super.dispose();
  }

  void _onEdited() => setState(() => _error = null);

  @override
  Widget build(BuildContext context) {
    // 连接断开、恢复、标签关闭都会改会话状态，跟着重建，按钮和提示跟上。
    ref.watch(sessionControllerProvider);
    final controller = ref.read(sessionControllerProvider.notifier);
    final problem = controller.targetProblem(_target);
    final live = problem == TerminalTargetProblem.replaced
        ? controller.liveSessionFor(_target)
        : null;
    final review = PasteReview.of(_editor.text);
    final bracketed = _target.terminal.bracketedPasteMode;
    final removed = {..._original.removedControls};
    review.removedControls.forEach(
      (name, count) => removed[name] = (removed[name] ?? 0) + count,
    );
    final runsLines = review.multiline && !bracketed;
    final scheme = Theme.of(context).colorScheme;
    final canSend = problem == null && review.text.isNotEmpty;
    // 单独一行取译文：本地化覆盖检查按引号抓中文，插值里套引号会被抓成半截。
    final linesUnit = localized('行');
    final charsUnit = localized('字');

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${localized('粘贴到')} ${_target.host.label}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              '${_target.host.username}@${_target.host.hostname} · '
              '${review.lines} $linesUnit · '
              '${review.text.runes.length} $charsUnit',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (problem != null) ...[
              const SizedBox(height: 10),
              _Notice(
                key: const ValueKey('terminal-paste-target-problem'),
                color: scheme.errorContainer,
                onColor: scheme.onErrorContainer,
                icon: Icons.link_off,
                text: switch (problem) {
                  TerminalTargetProblem.disconnected =>
                    '连接已断开：不会发送，恢复后也不会自动补发。内容留在这里，可以复制。',
                  TerminalTargetProblem.replaced =>
                    '连接已经恢复成新的 shell：原来那条收不到了，不会自动改发。要发到新连接请点「改发到新连接」。',
                  TerminalTargetProblem.closed => '标签已经关了：不会发送。内容留在这里，可以复制。',
                },
                action: live == null
                    ? null
                    : TextButton(
                        key: const ValueKey('terminal-paste-retarget'),
                        onPressed: () => setState(() => _target = live),
                        child: const LText('改发到新连接'),
                      ),
              ),
            ],
            const SizedBox(height: 10),
            if (review.multiline)
              _Notice(
                key: ValueKey(bracketed
                    ? 'terminal-paste-risk-bracketed'
                    : 'terminal-paste-risk-lines-run'),
                color: runsLines
                    ? scheme.errorContainer
                    : scheme.surfaceContainerHighest,
                onColor: runsLines ? scheme.onErrorContainer : scheme.onSurface,
                icon: Icons.warning_amber_outlined,
                text: bracketed
                    ? '多行。远端程序现在开着 bracketed paste（粘贴标记）：多数新版 shell 会把整段放进输入行，等你按回车才执行。但这是远端程序自己的约定，App 保证不了，有的程序照样逐行执行。'
                    : '多行。远端程序现在没开 bracketed paste：每个换行都等于按一次回车，除了最后一行，前面各行会在粘贴的同时执行。',
              ),
            if (_original.trailingNewlines > 0 || review.trailingNewlines > 0)
              const _Notice(
                key: ValueKey('terminal-paste-trailing-newline'),
                icon: Icons.keyboard_return,
                text: '末尾的换行不会发出去：粘贴完不会自动执行最后一行。要执行就点「粘贴并回车」，或者回到终端自己按回车。',
              ),
            if (removed.isNotEmpty)
              _Notice(
                key: const ValueKey('terminal-paste-controls'),
                icon: Icons.block,
                text: '去掉了控制字符（在终端里它们是按键，不是文字）：',
                detail: [
                  for (final MapEntry(:key, :value) in removed.entries)
                    '$key ×$value',
                ].join('、'),
              ),
            if (_original.invisibleFormatting > 0 ||
                review.invisibleFormatting > 0)
              const _Notice(
                key: ValueKey('terminal-paste-invisible'),
                icon: Icons.visibility_off_outlined,
                text: '有看不见的排版字符（零宽字符、改变文字方向的字符）：屏幕上看到的顺序可能和实际发出去的不一样。',
              ),
            if (review.tabs > 0 && !bracketed)
              const _Notice(
                icon: Icons.keyboard_tab,
                text: '含 Tab：远端没开 bracketed paste 时，shell 会把它当补全键。',
              ),
            if (review.text.length > PasteReview.longText)
              const _Notice(
                icon: Icons.notes,
                text: '内容很长，请确认整段都是你要发的。',
              ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .4,
              ),
              child: TextField(
                key: const ValueKey('terminal-paste-editor'),
                controller: _editor,
                minLines: 3,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: LInputDecoration(
                  border: const OutlineInputBorder(),
                  hintText: '在这里编辑。按回车只是换行，不会发送',
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              LText(_error!, style: TextStyle(color: scheme.error)),
            ],
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton(
                  key: const ValueKey('terminal-paste-cancel'),
                  onPressed: () => Navigator.pop(context),
                  child: const LText('取消'),
                ),
                if (problem != null)
                  TextButton(
                    key: const ValueKey('terminal-paste-copy'),
                    onPressed: review.text.isEmpty ? null : _copy,
                    child: const LText('复制内容'),
                  ),
                OutlinedButton(
                  key: const ValueKey('terminal-paste-enter'),
                  onPressed: canSend ? () => _send(enter: true) : null,
                  child: const LText('粘贴并回车'),
                ),
                // 没开 bracketed paste 的多行粘贴本身就会执行前面各行：这时不给它「默认动作」的样子，
                // 文字直接说会发生什么（UX03「危险动作不是默认动作」）。
                if (runsLines)
                  OutlinedButton(
                    key: const ValueKey('terminal-paste-send'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: scheme.error,
                    ),
                    onPressed: canSend ? () => _send(enter: false) : null,
                    child: const LText('粘贴（会逐行执行）'),
                  )
                else
                  FilledButton(
                    key: const ValueKey('terminal-paste-send'),
                    onPressed: canSend ? () => _send(enter: false) : null,
                    child: const LText('粘贴'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _send({required bool enter}) {
    final text = PasteReview.of(_editor.text).text;
    try {
      ref
          .read(sessionControllerProvider.notifier)
          .pasteInto(_target, text, enter: enter);
    } on TerminalTargetChangedException catch (error) {
      setState(() => _error = error.toString());
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    final label = _target.host.label;
    final done = enter ? localized('已粘贴并发送回车到') : localized('已粘贴到（没有回车）');
    Navigator.pop(context);
    messenger?.showSnackBar(SnackBar(
      duration: const Duration(seconds: 2),
      content: Text('$done $label'),
    ));
  }

  Future<void> _copy() async {
    await Clipboard.setData(
      ClipboardData(text: PasteReview.of(_editor.text).text),
    );
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: LText('已复制，没有发送')),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    super.key,
    required this.icon,
    required this.text,
    this.detail,
    this.color,
    this.onColor,
    this.action,
  });

  final IconData icon;
  final String text;
  final String? detail;
  final Color? color;
  final Color? onColor;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final foreground = onColor ?? Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: EdgeInsets.all(color == null ? 0 : 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: foreground),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LText(text, style: TextStyle(color: foreground)),
                    if (detail != null)
                      Text(
                        detail!,
                        style: TextStyle(
                          color: foreground,
                          fontFamily: 'monospace',
                        ),
                      ),
                    if (action != null) action!,
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
