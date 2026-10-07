import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/session_controller.dart';
import '../../application/terminal_compose.dart';
import '../../domain/terminal_paste.dart';
import '../../infrastructure/ssh/ssh_service.dart';
import '../localization/localized_widgets.dart';
import 'terminal_paste_sheet.dart';

/// 大输入框（R25 第一部分）：普通的多行文本框，用系统输入法打字、说话，打完了再发给终端。
///
/// 输入法的组字、改写、语音一边听一边改，都在这个普通文本框里完成，不经过终端的输入连接：
/// R04 那种「输入法改写已上屏的字，终端只能整段重发」的问题在这里不会有（字在框里，还没发出去）。
///
/// 发法照 R19 的粘贴：内容去掉末尾换行和控制字符（[PasteReview]），远端开着 bracketed paste 就包上粘贴标记，
/// 没开时换行就是回车。「发送」= 内容 + 回车，是用户明确按的执行动作（docs/02「需要执行时用户明确发送」）；
/// 「只填入」只发内容、不回车。发给谁、什么时候不发，见 [TerminalComposeDrafts]。
class TerminalComposeBox extends ConsumerStatefulWidget {
  const TerminalComposeBox({
    super.key,
    required this.session,
    required this.drafts,
    required this.focusNode,
    this.secureKeyboard = false,
    this.dense = false,
  });

  /// 这个输入框现在对着的标签（分屏时是用户点过的那一格）的当前连接。
  final ActiveTerminalSession session;
  final TerminalComposeDrafts drafts;
  final FocusNode focusNode;

  /// 设置里的「系统安全键盘」：输入法不联想、不学习（框里可能是密码）。
  final bool secureKeyboard;

  /// 横屏弹着键盘、地方很小：只留一行输入框和「发送」，别的收进「…」。
  final bool dense;

  @override
  ConsumerState<TerminalComposeBox> createState() => _TerminalComposeBoxState();
}

class _TerminalComposeBoxState extends ConsumerState<TerminalComposeBox> {
  late final _editor =
      TextEditingController(text: widget.drafts.textOf(_tabId));
  String? _error;

  String get _tabId => widget.session.id;

  @override
  void initState() {
    super.initState();
    _editor.addListener(_onEdited);
    widget.drafts.addListener(_onDraftsChanged);
  }

  @override
  void didUpdateWidget(covariant TerminalComposeBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.drafts, widget.drafts)) {
      oldWidget.drafts.removeListener(_onDraftsChanged);
      widget.drafts.addListener(_onDraftsChanged);
    }
    if (oldWidget.session.id != widget.session.id) {
      // 换了标签（或分屏换了一格）：各标签的草稿各自留着，框里换成这一格的。
      _error = null;
      _editor.value = TextEditingValue(
        text: widget.drafts.textOf(_tabId),
        selection: TextSelection.collapsed(
          offset: widget.drafts.textOf(_tabId).length,
        ),
      );
    }
  }

  @override
  void dispose() {
    widget.drafts.removeListener(_onDraftsChanged);
    _editor.dispose();
    super.dispose();
  }

  void _onEdited() {
    widget.drafts.edit(_tabId, _editor.text, widget.session);
    if (_error != null) setState(() => _error = null);
  }

  void _onDraftsChanged() {
    if (!mounted) return;
    // 别处清掉了草稿（发送成功、放进了关掉的标签留下的字）：框里跟上。
    final text = widget.drafts.textOf(_tabId);
    if (text != _editor.text) {
      _editor.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
    setState(() {});
  }

  /// 发给谁：草稿认的那条连接；空草稿跟着标签现在的连接。
  ActiveTerminalSession get _target =>
      widget.drafts.boundTargetOf(_tabId) ?? widget.session;

  void _send({required bool enter}) {
    final text = PasteReview.of(_editor.text).text;
    final target = _target;
    final announce = MediaQuery.maybeOf(context)?.accessibleNavigation ?? false;
    try {
      ref
          .read(sessionControllerProvider.notifier)
          .pasteInto(target, text, enter: enter);
    } on TerminalTargetChangedException catch (error) {
      setState(() => _error = error.toString());
      return;
    }
    // 发出去了才清空；断线、换了连接时上面已经返回，字留在框里。
    widget.drafts.clear(_tabId);
    if (announce) {
      SemanticsService.sendAnnouncement(
        View.of(context),
        localized(enter ? '已发送' : '已填入，没有回车'),
        Directionality.of(context),
      );
    }
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: LText('已复制，没有发送')),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 断线、恢复、关标签都会改会话状态：跟着重建，按钮和提示跟上。
    ref.watch(sessionControllerProvider);
    final controller = ref.read(sessionControllerProvider.notifier);
    final target = _target;
    final problem = controller.targetProblem(target);
    final live = problem == TerminalTargetProblem.replaced
        ? controller.liveSessionFor(target)
        : null;
    final review = PasteReview.of(_editor.text);
    final scheme = Theme.of(context).colorScheme;
    final canSend = problem == null;
    final canFill = canSend && review.text.isNotEmpty;
    final orphan = widget.drafts.orphan;

    final notices = <Widget>[
      if (problem != null)
        TerminalPasteNotice(
          key: const ValueKey('terminal-compose-target-problem'),
          color: scheme.errorContainer,
          onColor: scheme.onErrorContainer,
          icon: Icons.link_off,
          text: switch (problem) {
            TerminalTargetProblem.disconnected =>
              '连接已断开：不会发送，恢复后也不会自动补发。框里的字留着。',
            TerminalTargetProblem.replaced =>
              '连接已经恢复成新的 shell：这段字是对着原来那条写的，不会自动改发。要发到新连接请点「改发到新连接」。',
            TerminalTargetProblem.closed => '标签已经关了：不会发送。框里的字留着，可以复制。',
          },
          action: live == null
              ? null
              : TextButton(
                  key: const ValueKey('terminal-compose-retarget'),
                  onPressed: () => widget.drafts.retarget(_tabId, live),
                  child: const LText('改发到新连接'),
                ),
        ),
      if (orphan != null)
        TerminalPasteNotice(
          key: const ValueKey('terminal-compose-orphan'),
          color: scheme.surfaceContainerHighest,
          icon: Icons.tab_unselected,
          text: '关掉的标签还有一段没发的字（没有发送）：',
          detail: '${orphan.hostLabel}：${orphan.text}',
          action: Wrap(
            spacing: 4,
            children: [
              if (_editor.text.isEmpty)
                TextButton(
                  key: const ValueKey('terminal-compose-orphan-take'),
                  onPressed: () {
                    widget.drafts.dismissOrphan();
                    _editor.text = orphan.text;
                  },
                  child: const LText('放进这个输入框'),
                ),
              TextButton(
                onPressed: () {
                  widget.drafts.dismissOrphan();
                  _copy(orphan.text);
                },
                child: const LText('复制'),
              ),
              TextButton(
                onPressed: widget.drafts.dismissOrphan,
                child: const LText('丢掉'),
              ),
            ],
          ),
        ),
      if (review.multiline)
        // 远端的粘贴模式会变（进出 vim），跟着终端重建。
        ListenableBuilder(
          listenable: target.terminal,
          builder: (context, _) {
            final bracketed = target.terminal.bracketedPasteMode;
            return TerminalPasteNotice(
              key: ValueKey(bracketed
                  ? 'terminal-compose-risk-bracketed'
                  : 'terminal-compose-risk-lines-run'),
              color: bracketed
                  ? scheme.surfaceContainerHighest
                  : scheme.errorContainer,
              onColor: bracketed ? scheme.onSurface : scheme.onErrorContainer,
              icon: Icons.warning_amber_outlined,
              text: multilinePasteRisk(bracketed: bracketed),
            );
          },
        ),
      if (_error != null)
        TerminalPasteNotice(
          key: const ValueKey('terminal-compose-error'),
          icon: Icons.error_outline,
          onColor: scheme.error,
          text: _error!,
        ),
    ];

    final field = TextField(
      key: const ValueKey('terminal-compose-editor'),
      controller: _editor,
      focusNode: widget.focusNode,
      expands: !widget.dense,
      minLines: widget.dense ? 1 : null,
      maxLines: widget.dense ? 3 : null,
      textAlignVertical: TextAlignVertical.top,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      // 框里可能是密码：开了「系统安全键盘」就不联想、不学习。
      enableSuggestions: !widget.secureKeyboard,
      autocorrect: !widget.secureKeyboard,
      enableIMEPersonalizedLearning: !widget.secureKeyboard,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
      decoration: LInputDecoration(
        isDense: true,
        border: const OutlineInputBorder(),
        hintText: '在这里打字或说话，回车只是换行；点「发送」才发到终端',
      ),
    );

    final send = FilledButton(
      key: const ValueKey('terminal-compose-send'),
      onPressed: canSend ? () => _send(enter: true) : null,
      child: const LText('发送'),
    );
    final fill = OutlinedButton(
      key: const ValueKey('terminal-compose-fill'),
      onPressed: canFill ? () => _send(enter: false) : null,
      child: const LText('只填入'),
    );
    final clear = TextButton(
      key: const ValueKey('terminal-compose-clear'),
      onPressed: _editor.text.isEmpty ? null : _editor.clear,
      child: const LText('清空'),
    );

    if (widget.dense) {
      // 地方只够一行：提醒缩成一句短话放在框上面（照样写清会不会逐行执行），按钮只留「发送」，别的进「…」。
      // 远端的粘贴模式会变（进出 vim），这一句跟着终端重建。
      String? shortNotice() => switch ((problem, review.multiline)) {
            (TerminalTargetProblem.disconnected, _) => '连接已断开：不会发送，字留着',
            (TerminalTargetProblem.replaced, _) => '已恢复成新连接：不会自动改发',
            (TerminalTargetProblem.closed, _) => '标签已经关了：不会发送',
            (null, true) => target.terminal.bracketedPasteMode
                ? '多行：远端开着粘贴标记，多数 shell 等回车才执行（App 保证不了）'
                : '多行：远端没开粘贴标记，每个换行都是回车，前面各行会立刻执行',
            _ => null,
          };
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 2, 4, 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (problem != null || review.multiline)
              ListenableBuilder(
                listenable: target.terminal,
                builder: (context, _) => LText(
                  shortNotice() ?? '',
                  key: const ValueKey('terminal-compose-short-notice'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.error),
                ),
              ),
            Row(
              children: [
                Expanded(child: field),
                const SizedBox(width: 4),
                send,
                if (live != null)
                  IconButton(
                    key: const ValueKey('terminal-compose-retarget'),
                    tooltip: localized('改发到新连接'),
                    onPressed: () => widget.drafts.retarget(_tabId, live),
                    icon: const Icon(Icons.swap_horiz),
                  ),
                PopupMenuButton<VoidCallback>(
                  key: const ValueKey('terminal-compose-more'),
                  tooltip: localized('更多'),
                  onSelected: (action) => action(),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      enabled: canFill,
                      value: () => _send(enter: false),
                      child: const LText('只填入'),
                    ),
                    PopupMenuItem(
                      enabled: _editor.text.isNotEmpty,
                      value: _editor.clear,
                      child: const LText('清空'),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (notices.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 96),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: notices,
                ),
              ),
            ),
          Expanded(child: field),
          const SizedBox(height: 4),
          SizedBox(
            height: 48,
            child: Row(
              children: [
                clear,
                const Spacer(),
                fill,
                const SizedBox(width: 8),
                send,
              ],
            ),
          ),
        ],
      ),
    );
  }
}
