import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/terminal_compose.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:netcatty_mobile/infrastructure/terminal/ghostty_terminal_adapter.dart';

// R25：大输入框的草稿。每个标签一份；从空变成有字时记下当时的连接；只有用户点「改发到新连接」才改认；
// 关掉的标签留下的字挪到一边，不丢。

ActiveTerminalSession _session(String id) {
  final terminal = GhosttyTerminalAdapter();
  addTearDown(terminal.dispose);
  return ActiveTerminalSession(
    id: id,
    host: HostProfile.create(
        id: id, label: 'host-$id', hostname: 'h', username: 'u'),
    terminal: terminal,
    verifyHostKey: (_, __, ___) async => true,
    keyboardInteractive: null,
  );
}

void main() {
  test('从空变成有字时认下当时的连接，之后再改字不换；清空后重新跟着标签走', () {
    final drafts = TerminalComposeDrafts();
    final first = _session('a');
    final restored = _session('a');

    expect(drafts.boundTargetOf('a'), isNull);
    drafts.edit('a', 'ls', first);
    drafts.edit('a', 'ls -l', restored);
    expect(drafts.textOf('a'), 'ls -l');
    expect(drafts.boundTargetOf('a'), same(first), reason: '没点改发就不换连接');

    drafts.retarget('a', restored);
    expect(drafts.boundTargetOf('a'), same(restored));

    drafts.clear('a');
    expect(drafts.textOf('a'), isEmpty);
    expect(drafts.boundTargetOf('a'), isNull);
    drafts.edit('a', 'pwd', restored);
    expect(drafts.boundTargetOf('a'), same(restored));
  });

  test('每个标签一份；关掉的标签有字的挪进 orphan，空的直接忘掉', () {
    final drafts = TerminalComposeDrafts();
    drafts.edit('a', 'for a', _session('a'));
    drafts.edit('b', 'for b', _session('b'));
    expect(drafts.textOf('a'), 'for a');
    expect(drafts.textOf('b'), 'for b');

    var notified = 0;
    drafts.addListener(() => notified++);
    drafts.forgetClosedTabs(['b']);
    expect(drafts.textOf('a'), isEmpty);
    expect(drafts.orphan?.hostLabel, 'host-a');
    expect(drafts.orphan?.text, 'for a');
    expect(notified, 1);

    drafts.forgetClosedTabs(['b']);
    expect(notified, 1, reason: '没有新关掉的标签，不通知');
    drafts.dismissOrphan();
    expect(drafts.orphan, isNull);
  });
}
