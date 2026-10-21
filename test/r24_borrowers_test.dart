import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';

import 'support/test_terminal.dart';

// R24：借用标签上那条 SSH 的文件、监控、系统管理、端口转发。
// 这里是不用网络的部分；真实 OpenSSH 上的 Direct/SOCKS/Jump 矩阵在 r24_borrowers_fixture_test.dart。
void main() {
  ActiveTerminalSession session() => ActiveTerminalSession(
        id: 'tab',
        host: HostProfile({'id': 'h', 'label': 'h', 'protocol': 'ssh'}),
        terminal: newTestTerminal(),
        verifyHostKey: (_, __, ___) async => true,
        keyboardInteractive: null,
      );

  group('连接释放时先放借用者（REG01 释放顺序）', () {
    test('abort 按登记顺序调一次；再 abort 不重复调', () {
      final s = session();
      final calls = <String>[];
      s.onRelease(() => calls.add('sftp'));
      s.onRelease(() => calls.add('forward'));
      s.abort();
      s.abort();
      expect(calls, ['sftp', 'forward']);
      expect(s.connected, isFalse);
    });

    test('一个借用者抛错不挡住后面的，也不让 abort 抛出去', () {
      final s = session();
      final calls = <String>[];
      s.onRelease(() => throw StateError('boom'));
      s.onRelease(() => calls.add('second'));
      expect(s.abort, returnsNormally);
      expect(calls, ['second']);
    });

    test('已经释放了再登记：马上调，不留到以后', () {
      final s = session()..abort();
      var called = 0;
      s.onRelease(() => called++);
      expect(called, 1);
    });

    test('撤销登记后不再调', () {
      final s = session();
      var called = 0;
      final cancel = s.onRelease(() => called++);
      cancel();
      s.abort();
      expect(called, 0);
    });
  });
}
