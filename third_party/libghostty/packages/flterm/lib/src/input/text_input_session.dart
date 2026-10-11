import 'dart:async';

import 'package:flutter/services.dart';
import 'package:meta/meta.dart';

/// Publishes editable-box geometry and its root transform for text input.
typedef TextInputGeometryChanged =
    void Function({
      required Size editableSize,
      required Matrix4 transform,
      required Rect caretRect,
      required Rect composingRect,
    });

/// Flutter text input connection for terminal editing.
///
/// The terminal has no editable text buffer, so this client keeps a sentinel
/// editing value only to give platform IMEs an anchor for composing ranges.
/// It turns platform edits into terminal events: committed text, newlines,
/// deletions, and visible preedit text.
///
/// The sentinel never becomes terminal content. Some platforms report Enter
/// through both an action and a delta; the short-lived dedupe counters ensure
/// one terminal newline while leaving later input untouched.
///
/// shun: 上游每次提交后立刻把编辑区清回哨兵，输入法就没法改写已经出现的字。微信输入法语音每次
/// 更新识别结果都会先短暂结束组字、再把组字区圈回刚出现的那段字继续改，每一版都被当成新提交，
/// 一句话整段重复发出去（R04 问题 8）。现在提交后编辑区原样留着，记下哪些字已经发给了终端；
/// 每次编辑完按「已发」和「编辑区里确定的字」的差异补发：先发退格删掉变了的部分，再发新的尾巴。
/// 只在远端那一行已经对不上（终端从别的路收到了输入）、编辑区出现换行、留得太长、焦点离开时清空。
@internal
final class TextInputSession with DeltaTextInputClient {
  static const _newlineActionDedupeWindow = Duration(milliseconds: 100);
  static const _sentinel = TextEditingValue(
    selection: .collapsed(offset: 1),
    text: ' ',
  );

  /// shun: 编辑区里留着的已发文字超过这么多（UTF-16 码元）就在不组字时清空。
  /// 每次编辑都要和它比一遍；太小又会在长句语音中途清空，那一刻输入法回头改字就又重复了。
  static const _retainedTextLimit = 4096;
  static final _newlinePattern = RegExp(r'\r\n|[\n\r]');
  static final _onlyNewlinesPattern = RegExp(r'^(?:\r\n|[\n\r])+$');

  _CommittedCompositionEdit _committedCompositionEdit = .none;
  TextInputConnection? _connection;
  var _hadVisiblePreeditText = false;
  Brightness _keyboardAppearance = .dark;
  var _newlineActionsToSuppress = 0;
  Timer? _newlineActionDedupeTimer;
  var _newlineDeltasToSuppress = 0;
  VoidCallback? _onNewline;
  ValueChanged<int>? _onDelete;
  ValueChanged<String>? _onPreeditChanged;
  ValueChanged<String>? _onTextCommitted;
  TextEditingValue _value = _sentinel;
  int? _viewId;

  /// shun: 已经发给终端、编辑区里也还留着的文字（哨兵之后、组字区之外）。
  var _sent = '';

  /// shun: 平台编辑区现在是否以哨兵开头。被输入法删掉或整段替换后为 false，直到清空编辑区；
  /// 这期间编辑区从第 0 个字起都是终端的字。
  var _hasSentinel = true;
  var _resetRequested = false;

  /// shun: 这边刚把编辑区清回哨兵、平台还没确认。这期间输入法发来的编辑可能是按它自己旧的编辑区
  /// 算的（平台先处理了它，后处理我们的清空），见 [_applyStaleDelta]。
  var _awaitingPlatformReset = false;
  var _secure = false;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  TextEditingValue get currentTextEditingValue => _value;

  /// Whether the platform owns a composing range, even when no visible
  /// preedit text should be rendered.
  bool get hasActiveComposition => _value.hasTerminalComposingRange;

  /// Whether this client owns the platform text input connection.
  ///
  /// Text input accepts one client at a time. Another client can replace this
  /// connection without invoking [connectionClosed], so non-nullness alone
  /// does not prove ownership.
  bool get isAttached => _connection?.attached ?? false;

  set keyboardAppearance(Brightness value) {
    if (_keyboardAppearance == value) return;
    _keyboardAppearance = value;
    final connection = _connection;
    if (connection != null && connection.attached) {
      connection.updateConfig(_configuration);
    }
  }

  set onDelete(ValueChanged<int>? callback) => _onDelete = callback;

  /// shun: 敏感输入，输入框类型改成可见密码。已连上的输入法立即换配置。
  set secure(bool value) {
    if (_secure == value) return;
    _secure = value;
    final connection = _connection;
    if (connection != null && connection.attached) {
      connection.updateConfig(_configuration);
    }
  }

  set onNewline(VoidCallback? callback) => _onNewline = callback;

  set onPreeditChanged(ValueChanged<String>? callback) {
    _onPreeditChanged = callback;
  }

  set onTextCommitted(ValueChanged<String>? callback) {
    _onTextCommitted = callback;
  }

  /// Replaces an active connection because platform text input is view-bound.
  set viewId(int value) {
    if (_viewId == value) return;
    final wasAttached = _connection != null;
    if (wasAttached) _closeConnection();
    _viewId = value;
    if (wasAttached) _openConnection();
  }

  TextInputConfiguration get _configuration {
    final viewId = _viewId;
    if (viewId == null) {
      throw StateError(
        'Text input requires an owning Flutter view before attachment.',
      );
    }
    return TextInputConfiguration(
      viewId: viewId,
      autocorrect: false,
      // shun: multiline 加关掉建议，会被 Flutter 引擎标成「可见密码」，Gboard 只给英文键盘、
      // 微信输入法每次弹出都回到英文；emailAddress 落成 Filter 类型，两种输入法都直接给中文（R04 问题 4）。
      // 用户要的就是「可见密码」时（安全键盘）才用它。
      inputType: _secure ? .visiblePassword : .emailAddress,
      inputAction: .newline,
      smartDashesType: .disabled,
      smartQuotesType: .disabled,
      enableDeltaModel: true,
      enableSuggestions: false,
      enableInlinePrediction: false,
      enableInteractiveSelection: false,
      enableIMEPersonalizedLearning: false,
      keyboardAppearance: _keyboardAppearance,
    );
  }

  @override
  void connectionClosed() {
    _connection = null;
    _resetInputState();
  }

  /// Lets one plain desktop Backspace/Delete reach the platform IME after a
  /// candidate commit, while arming suppression for the matching edit delta.
  bool consumeCommittedCompositionEdit() {
    if (_committedCompositionEdit != .pending) return false;
    _committedCompositionEdit = .suppressNextDeletionDelta;
    return true;
  }

  void detach() => _closeConnection();

  /// shun: 终端从编辑区以外的路收到了输入（硬件键盘、快捷键栏、粘贴，或者输入法的字被虚拟
  /// 修饰键变成了控制键），远端那一行和编辑区里留着的字对不上了，清空编辑区。不清的话，输入法回头
  /// 改字时按差异补发的退格会删到别的字上。
  ///
  /// 组字中不动：清空会打断输入法正在组的字。记下来，等组字结束再清。
  void discardRetainedText() {
    if (hasActiveComposition) {
      _resetRequested = true;
      return;
    }
    if (_hasSentinel && _sent.isEmpty && _value == _sentinel) return;
    _resetEditingState();
  }

  /// shun: 软键盘发来的按键（删除、方向键）被终端处理了：清空编辑区，并且一定让输入法重新对齐。
  ///
  /// R04 问题 4：这类键被终端吞掉后编辑区不变，平台不会通知输入法光标位置，Gboard 按「已删一个字」
  /// 估算，之后组字区间错一位、删拼音时漏发字母。编辑区本来就是哨兵时推两次不同的状态，逼平台发
  /// updateSelection（R04 实测 A/B：去掉 3/3 漏发，加上 0/3）。组字中同样不动。
  void resyncAfterKeyEdit() {
    if (hasActiveComposition) {
      _resetRequested = true;
      return;
    }
    _resetEditingState();
  }

  @override
  void didChangeInputControl(TextInputControl? _, TextInputControl? _) {}

  void ensureAttached({Brightness? keyboardAppearance}) {
    if (keyboardAppearance != null) _keyboardAppearance = keyboardAppearance;
    final connection = _connection;
    if (connection == null) return _openConnection();
    if (!connection.attached) {
      _closeConnection();
      return _openConnection();
    }
    connection.updateConfig(_configuration);
  }

  void hide() => _closeConnection();

  @override
  void insertContent(KeyboardInsertedContent content) {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  bool onFocusReceived() => false;

  @override
  void performAction(TextInputAction action) {
    if (action != .newline) return;
    if (_newlineActionsToSuppress > 0) {
      _newlineActionsToSuppress--;
      _finishNewlineDedupeIfIdle();
      return;
    }
    // shun: 这里不清空编辑区。有的输入法先报回车动作、再补一个换行的编辑，那个编辑是相对于它自己
    // 还留着字的编辑区算的；这时已经清空的话，留着的字会被当成新字再发一遍。
    _onNewline?.call();
    _newlineDeltasToSuppress++;
    _armNewlineActionDedupeTimer();
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void performSelector(String selectorName) {}

  @override
  void removeTextPlaceholder() {}

  void show() {
    ensureAttached();
    _connection?.show();
  }

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void showToolbar() {}

  @override
  void updateEditingValue(TextEditingValue value) {
    final previous = _value;
    final wasComposing = _hadVisiblePreeditText || hasActiveComposition;
    _value = value;
    // 整值更新看不到是哪种编辑。哨兵没了、文字变短：当成退格删过了头。
    final deletedPastStart =
        previous.text.startsWith(_sentinel.text) &&
            !value.text.startsWith(_sentinel.text) &&
            value.text.length < previous.text.length
        ? 1
        : 0;
    _reconcile(deletedPastStart: deletedPastStart, wasComposing: wasComposing);
  }

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> deltas) {
    final wasComposing = _hadVisiblePreeditText || hasActiveComposition;
    if (deltas.isEmpty) {
      // shun: Flutter Android 的 delta 模式只为改文字（replace）和加 span（setSpan）记编辑。
      // 输入法用 finishComposingText 结束组字时只是删掉组字 span，平台照样通知框架，带的编辑却是空的
      // （engine/.../ListenableEditingState.java，R18 在模拟器上用回放输入法核实）。不处理的话组字区
      // 里的字要等下一次改文字才提交，用户这时按的回车会被当成组字中的键吞掉。
      // 删 span 能改的只有组字区和选区，选区的改动走 setSpan、有编辑记录；所以组字中收到空编辑，
      // 就是组字结束了。
      if (!hasActiveComposition) return;
      _value = _value.copyWith(composing: .empty);
      _reconcile(deletedPastStart: 0, wasComposing: true);
      return;
    }
    var deletedPastStart = 0;
    for (final delta in deltas) {
      if (_awaitingPlatformReset) {
        if (delta.oldText != _value.text) {
          _applyStaleDelta(delta);
          continue;
        }
        _awaitingPlatformReset = false;
      }
      deletedPastStart += _deletedSentinel(delta);
      _value = delta.apply(_value);
    }
    _reconcile(deletedPastStart: deletedPastStart, wasComposing: wasComposing);
  }

  /// shun: 平台上「输入法的编辑」排在「我们的清空」前面：这条编辑是按输入法旧的编辑区算的，之后平台
  /// 又被我们清回哨兵。不能拿它的结果和已发的字比（已发的已经清零，会把旧编辑区里的字整段重发，
  /// 模拟器上回车键后紧跟一次提交就把整条命令发了两遍），只按它自己的增量处理，和上游一样：
  /// 不在组字的插入、替换发新字，删除发同样个数的退格，组字中的编辑丢掉（输入法会按清空后的状态重来）。
  void _applyStaleDelta(TextEditingDelta delta) {
    final composing = delta.composing;
    if (composing.isValid && !composing.isCollapsed) return;
    switch (delta) {
      case TextEditingDeltaInsertion(:final textInserted)
          when textInserted.isNotEmpty:
        _commitText(textInserted);
      case TextEditingDeltaReplacement(:final replacementText)
          when replacementText.isNotEmpty:
        _commitText(replacementText);
      case TextEditingDeltaDeletion(:final textDeleted)
          when textDeleted.isNotEmpty:
        // 桌面输入法提交候选后的第一个退格已经由按键那条路发过了（consumeCommittedCompositionEdit）。
        if (_committedCompositionEdit == .suppressNextDeletionDelta) {
          _clearCommittedCompositionEdit();
          return;
        }
        _clearNewlineActionSuppression();
        _onDelete?.call(textDeleted.runes.length);
      default:
        break;
    }
  }

  /// shun: 软键盘发来的回车键已经由按键那条路发出去了。有的输入法随后还补一个换行编辑，
  /// 和回车动作一样去重，一次回车只发一个。
  void noteNewlineKey() {
    _newlineDeltasToSuppress++;
    _armNewlineActionDedupeTimer();
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  /// Anchors native composing and candidate UI to the terminal cursor cell.
  void updateGeometry({
    required Size editableSize,
    required Matrix4 transform,
    required Rect caretRect,
    required Rect composingRect,
  }) {
    final connection = _connection;
    if (connection == null || !connection.attached) return;
    connection
      ..setEditableSizeAndTransform(editableSize, transform)
      ..setCaretRect(caretRect)
      ..setComposingRect(composingRect);
  }

  void _armNewlineActionDedupeTimer() {
    _newlineActionDedupeTimer?.cancel();
    _newlineActionDedupeTimer = Timer(
      _newlineActionDedupeWindow,
      _clearNewlineActionSuppression,
    );
  }

  void _clearCommittedCompositionEdit() {
    _committedCompositionEdit = .none;
  }

  void _clearNewlineActionSuppression() {
    _newlineActionDedupeTimer?.cancel();
    _newlineActionDedupeTimer = null;
    _newlineActionsToSuppress = 0;
    _newlineDeltasToSuppress = 0;
  }

  void _closeConnection() {
    _connection?.close();
    _connection = null;
    _resetInputState();
  }

  void _commitNewlines(int count) {
    final suppressed = count < _newlineDeltasToSuppress
        ? count
        : _newlineDeltasToSuppress;
    _newlineDeltasToSuppress -= suppressed;
    final emitted = count - suppressed;
    for (var i = 0; i < emitted; i++) {
      _onNewline?.call();
    }
    _newlineActionsToSuppress += emitted;
    if (_newlineActionsToSuppress > 0 || _newlineDeltasToSuppress > 0) {
      _armNewlineActionDedupeTimer();
    } else {
      _finishNewlineDedupeIfIdle();
    }
  }

  void _commitText(String text) {
    if (_onlyNewlinesPattern.hasMatch(text)) {
      _commitNewlines(_newlinePattern.allMatches(text).length);
      return;
    }

    _clearNewlineActionSuppression();

    var offset = 0;
    for (final match in _newlinePattern.allMatches(text)) {
      final chunk = text.substring(offset, match.start);
      if (chunk.isNotEmpty) _onTextCommitted?.call(chunk);
      _onNewline?.call();
      offset = match.end;
    }

    final tail = text.substring(offset);
    if (tail.isNotEmpty) _onTextCommitted?.call(tail);
  }

  /// shun: 这次编辑删掉了哨兵（编辑区只剩哨兵时按退格）：远端要多删一个字。
  /// 输入法整段替换掉哨兵不算，那是它重写编辑区，不是用户删字。
  int _deletedSentinel(TextEditingDelta delta) {
    if (delta is! TextEditingDeltaDeletion) return 0;
    if (!delta.oldText.startsWith(_sentinel.text)) return 0;
    return delta.deletedRange.start < _sentinel.text.length ? 1 : 0;
  }

  void _finishNewlineDedupeIfIdle() {
    if (_newlineActionsToSuppress == 0 && _newlineDeltasToSuppress == 0) {
      _clearNewlineActionSuppression();
    }
  }

  void _openConnection() {
    final connection = TextInput.attach(this, _configuration);
    _connection = connection;
    _value = _sentinel;
    _sent = '';
    _hasSentinel = true;
    _resetRequested = false;
    _awaitingPlatformReset = false;
    connection.setEditingState(_value);
  }

  /// shun: 把编辑区和已发的字对一遍，补发差异。
  ///
  /// 从头找编辑区和已发的字相同的前缀，已发的字里前缀之后的部分发退格删掉。不在组字：再发编辑区
  /// 前缀之后的部分。在组字：组字区之前确定了的字照发；组字区里和已发相同的那段留在远端不动，
  /// 剩下的只当预编辑显示、不发（微信语音把刚发的字圈回组字区接着改，远端保留没变的部分，只删真的
  /// 改了的字）。哨兵被删了或被整段替换：已发的字全删（加上删哨兵那几下），从头再来，然后清空。
  void _reconcile({required int deletedPastStart, required bool wasComposing}) {
    final expireSuppression =
        _committedCompositionEdit == .suppressNextDeletionDelta;
    final hadVisiblePreeditText = _hadVisiblePreeditText;
    final sentinelLost =
        _hasSentinel &&
        (deletedPastStart > 0 || !_value.text.startsWith(_sentinel.text));
    if (sentinelLost) _hasSentinel = false;
    final edit = _value.terminalEdit(
      start: _hasSentinel ? _sentinel.text.length : 0,
    );
    final full = edit.before + edit.preedit + edit.after;

    var common = 0;
    var deletions = 0;
    if (sentinelLost) {
      deletions = _sent.runes.length + deletedPastStart;
    } else {
      common = _commonPrefixLength(_sent, full);
      deletions = _sent.substring(common).runes.length;
    }

    final String tail;
    final String preedit;
    final String sent;
    final composedEnd = edit.before.length + edit.preedit.length;
    if (!edit.composing) {
      tail = full.substring(common);
      preedit = '';
      sent = full;
    } else if (common < edit.before.length) {
      tail = edit.before.substring(common);
      preedit = edit.preedit;
      sent = edit.before;
    } else {
      // 组字区（有的输入法只圈住哨兵）后面的字也和已发的一样时，没有要显示的预编辑。
      tail = '';
      preedit = common < composedEnd
          ? edit.preedit.substring(common - edit.before.length)
          : '';
      sent = full.substring(0, common);
    }

    // 桌面输入法提交候选后的第一个退格，按键那条路已经发过了（见 consumeCommittedCompositionEdit），
    // 输入法随后报的删除只记账、不再发。
    if (deletions > 0 &&
        tail.isEmpty &&
        !edit.composing &&
        !hadVisiblePreeditText &&
        _committedCompositionEdit == .suppressNextDeletionDelta) {
      _clearCommittedCompositionEdit();
      deletions = 0;
    }

    _sent = sent;
    if (deletions > 0) {
      _clearNewlineActionSuppression();
      _clearCommittedCompositionEdit();
      _onDelete?.call(deletions);
    }
    if (tail.isNotEmpty) {
      _commitText(tail);
      _committedCompositionEdit = wasComposing || tail.isImeLikeCommit
          ? .pending
          : .none;
    }

    if (preedit.isNotEmpty) {
      _clearCommittedCompositionEdit();
      _onPreeditChanged?.call(preedit);
    } else if (hadVisiblePreeditText) {
      _onPreeditChanged?.call('');
    }
    _hadVisiblePreeditText = preedit.isNotEmpty;

    if (expireSuppression &&
        _committedCompositionEdit == .suppressNextDeletionDelta) {
      _clearCommittedCompositionEdit();
    }

    if (edit.composing) return;
    if (_resetRequested ||
        !_hasSentinel ||
        _newlinePattern.hasMatch(full) ||
        full.length > _retainedTextLimit) {
      _resetEditingState();
    }
  }

  /// shun: 编辑区清回哨兵，忘掉已发的字。编辑区本来就是哨兵时推两次不同的状态，
  /// 不然平台看值没变，不会把光标位置告诉输入法（见 [resyncAfterKeyEdit]）。
  void _resetEditingState() {
    _resetRequested = false;
    _sent = '';
    _hasSentinel = true;
    final unchanged = _value == _sentinel;
    _value = _sentinel;
    final connection = _connection;
    if (connection == null || !connection.attached) return;
    _awaitingPlatformReset = !unchanged;
    if (unchanged) {
      connection.setEditingState(
        const TextEditingValue(text: ' ', selection: .collapsed(offset: 0)),
      );
    }
    connection.setEditingState(_value);
  }

  void _resetInputState() {
    final hadVisiblePreeditText =
        _hadVisiblePreeditText ||
        _value.terminalEdit(start: _hasSentinel ? 1 : 0).preedit.isNotEmpty;
    _value = _sentinel;
    _sent = '';
    _hasSentinel = true;
    _resetRequested = false;
    _awaitingPlatformReset = false;
    _clearNewlineActionSuppression();
    _clearCommittedCompositionEdit();
    _hadVisiblePreeditText = false;
    if (hadVisiblePreeditText) _onPreeditChanged?.call('');
  }

  /// 相同前缀的长度（UTF-16 码元），不切开代理对。
  static int _commonPrefixLength(String a, String b) {
    final limit = a.length < b.length ? a.length : b.length;
    var index = 0;
    while (index < limit && a.codeUnitAt(index) == b.codeUnitAt(index)) {
      index++;
    }
    if (index > 0 &&
        index < limit &&
        _isHighSurrogate(a.codeUnitAt(index - 1))) {
      index--;
    }
    return index;
  }

  static bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xD800 && codeUnit <= 0xDBFF;
}

enum _CommittedCompositionEdit { none, pending, suppressNextDeletionDelta }

/// shun: 哨兵之后的编辑区按组字区拆成三段。不在组字时整段都在 [before] 里。
typedef _TerminalEdit = ({
  String before,
  String preedit,
  String after,
  bool composing,
});

/// Extracts terminal-owned text from Flutter's sentinel editing value.
extension _EditingValue on TextEditingValue {
  bool get hasTerminalComposingRange {
    final composing = this.composing;
    return composing.isValid &&
        !composing.isCollapsed &&
        composing.start >= 0 &&
        composing.end <= text.length;
  }

  /// [start] 之前是哨兵，不算终端的字。
  _TerminalEdit terminalEdit({required int start}) {
    final from = start > text.length ? text.length : start;
    if (!hasTerminalComposingRange) {
      return (
        before: text.substring(from),
        preedit: '',
        after: '',
        composing: false,
      );
    }
    final composingStart = composing.start < from ? from : composing.start;
    final composingEnd = composing.end < from ? from : composing.end;
    return (
      before: text.substring(from, composingStart),
      preedit: text.substring(composingStart, composingEnd),
      after: text.substring(composingEnd),
      composing: true,
    );
  }
}

extension _InputString on String {
  bool get isImeLikeCommit => codeUnits.any((codeUnit) => codeUnit > 0x7f);
}
