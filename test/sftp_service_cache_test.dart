import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:shun/presentation/screens/sftp_screen.dart';

// 文件页按标签缓存的 SFTP 服务：关掉的标签要从表里删掉，不然它的会话、终端、SSH 客户端都回收不了
// （R20 资源测试在设备上开关 500 次，504 个会话全被这张表拿着）。

ActiveTerminalSession _session(String id) {
  final terminal = GhosttyTerminalAdapter();
  addTearDown(terminal.dispose);
  return ActiveTerminalSession(
    id: id,
    host: HostProfile.create(
        id: 'h-$id', label: id, hostname: '$id.example.com', username: 'u'),
    terminal: terminal,
    verifyHostKey: (_, __, ___) async => true,
    keyboardInteractive: null,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('关掉的标签从表里删掉；还开着的（连着、断着都算）留着', () {
    final cache = SftpServiceCache();
    final a = _session('a');
    final b = _session('b')..connected = false;
    final c = _session('c');
    cache.serviceFor(a);
    cache.serviceFor(b);
    cache.serviceFor(c);

    cache.retainOnly([b, c]); // a 的标签关了；b 暂时断线、标签还在

    expect(cache.sessionIds, unorderedEquals(['b', 'c']));
  });

  test('同一个标签：会话没换就是同一个服务；断线恢复换了会话对象就换新服务', () {
    final cache = SftpServiceCache();
    final first = _session('t');
    final service = cache.serviceFor(first);
    expect(cache.serviceFor(first), same(service));

    final restored = _session('t');
    final replaced = cache.serviceFor(restored);
    expect(replaced, isNot(same(service)));
    expect(replaced.session, same(restored));
    expect(cache.sessionIds, ['t']);
  });
}
