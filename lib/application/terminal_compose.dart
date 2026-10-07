import 'package:flutter/foundation.dart';

import '../infrastructure/ssh/ssh_service.dart';

/// 大输入框的草稿（R25 第一部分，所有者 10-07 提的「大输入框」）。
///
/// 每个标签一份：切标签各看各的，切到按键面板再切回来、收起面板再打开都还在。只放内存，不落盘：
/// 框里可能是密码（sudo 提示时用它打），App 被杀就没了。
///
/// 发给谁照 R19 的规矩：草稿从空变成有字那一刻，记下这个标签当时的连接对象；点「发送」时那条连接
/// 还在、还连着才发。断线了、断线后恢复成了新连接（同一个标签、新的 shell，原来那个目录、环境都没了）、
/// 标签关了，都不发，也不等恢复了补发，框里的字留着。恢复成新连接后要发，用户得点「改发到新连接」。
class TerminalComposeDrafts extends ChangeNotifier {
  final _drafts = <String, _Draft>{};

  /// 关掉的标签留下的、还没发的草稿。标签没了，字不能跟着丢：放在这里，等用户在别的标签的输入框里
  /// 决定放进来、复制还是丢掉。只留最近一份。
  ComposeOrphan? get orphan => _orphan;
  ComposeOrphan? _orphan;

  String textOf(String tabId) => _drafts[tabId]?.text ?? '';

  /// 这份草稿认的连接；空草稿不认任何连接，跟着标签现在的连接走。
  ActiveTerminalSession? boundTargetOf(String tabId) => _drafts[tabId]?.target;

  /// 用户改了 [tabId] 的草稿。[current] 是这个标签现在的连接：只在草稿从空变成有字时记下。
  void edit(String tabId, String text, ActiveTerminalSession current) {
    final draft = _drafts[tabId];
    if (text.isEmpty) {
      if (_drafts.remove(tabId) != null) notifyListeners();
      return;
    }
    if (draft == null) {
      _drafts[tabId] = _Draft(text, current);
      notifyListeners();
      return;
    }
    if (draft.text == text) return;
    draft.text = text;
    notifyListeners();
  }

  /// 用户明确点了「改发到新连接」：草稿改认 [live]（同一个标签恢复出来的新连接）。
  void retarget(String tabId, ActiveTerminalSession live) {
    final draft = _drafts[tabId];
    if (draft == null || identical(draft.target, live)) return;
    draft.target = live;
    notifyListeners();
  }

  /// 发出去了：清掉。只有发送成功才调。
  void clear(String tabId) {
    if (_drafts.remove(tabId) != null) notifyListeners();
  }

  /// 标签列表变了：已经关掉的标签的草稿挪进 [orphan]（有字的才挪）。
  void forgetClosedTabs(Iterable<String> openTabIds) {
    final open = openTabIds.toSet();
    final closed = [
      for (final MapEntry(:key, :value) in _drafts.entries)
        if (!open.contains(key)) (key, value),
    ];
    if (closed.isEmpty) return;
    for (final (tabId, draft) in closed) {
      _drafts.remove(tabId);
      _orphan = ComposeOrphan(draft.target.host.label, draft.text);
    }
    notifyListeners();
  }

  /// 用户处理了关掉的标签留下的草稿（放进了输入框、复制了或丢掉了）。
  void dismissOrphan() {
    if (_orphan == null) return;
    _orphan = null;
    notifyListeners();
  }
}

class _Draft {
  _Draft(this.text, this.target);

  String text;
  ActiveTerminalSession target;
}

/// 关掉的标签留下的草稿。
@immutable
class ComposeOrphan {
  const ComposeOrphan(this.hostLabel, this.text);

  final String hostLabel;
  final String text;
}
