import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/ssh_lease.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';

import 'support/test_terminal.dart';

// R24：借用标签上那条 SSH 的文件、监控、系统管理、端口转发。
// 这里是不用网络的部分；真实 OpenSSH 上的部分在 integration_ssh_fixture_test.dart 的 R24 组（连测试环境的用例都放那一个文件，见 docs/dev/README.md）。
void main() {
  final host = HostProfile({
    'id': 'h',
    'label': 'box',
    'protocol': 'ssh',
    'hostname': 'box.example',
    'username': 'alice',
    'password': 'pw-SEC12-secret',
  });

  ActiveTerminalSession session({List<SSHClient> clients = const []}) =>
      ActiveTerminalSession(
        id: 'tab',
        host: host,
        terminal: newTestTerminal(),
        verifyHostKey: (_, __, ___) async => true,
        keyboardInteractive: null,
        sshClients: clients,
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

  group('SshLease：只用借的那一代，断了马上说清楚', () {
    late _QuietSocket socket;
    late SSHClient client;
    late ActiveTerminalSession tab;

    setUp(() {
      socket = _QuietSocket();
      client = SSHClient(socket, username: 'alice');
      tab = session(clients: [client]);
    });

    tearDown(() => tab.abort());

    test('断开的标签借不到；不是 SSH 的也借不到', () {
      expect(() => SshLease.of(session()), throwsA(isA<ConnectionGone>()));
      tab.connected = false;
      expect(() => SshLease.of(tab), throwsA(isA<ConnectionGone>()));
    });

    test('只读的一步在等回复时连接断了：马上报 ConnectionGone，不跟着一直等', () async {
      final lease = SshLease.of(tab);
      final never = Completer<int>();
      final reading = lease.read((_) => never.future);
      socket.drop();
      await expectLater(
          reading.timeout(const Duration(seconds: 2)),
          throwsA(isA<ConnectionGone>()));
      expect(lease.alive, isFalse);
    });

    test('改动服务器的一步：发出去以后断了是「结果未知」；断了以后再发是「没执行」', () async {
      final lease = SshLease.of(tab);
      final never = Completer<void>();
      final writing = lease.write('删除 /tmp/a', (_) => never.future);
      socket.drop();
      await expectLater(
        writing.timeout(const Duration(seconds: 2)),
        throwsA(isA<OutcomeUnknown>()
            .having((e) => e.action, 'action', '删除 /tmp/a')),
      );
      var sent = false;
      await expectLater(
        lease.write('删除 /tmp/b', (_) async => sent = true),
        throwsA(isA<ConnectionGone>()),
      );
      expect(sent, isFalse, reason: '断了以后的一步根本不发');
    });

    test('关标签（abort）等同于断开：借用者马上知道', () async {
      final lease = SshLease.of(tab);
      final reading = lease.read((_) => Completer<void>().future);
      tab.abort();
      await expectLater(reading.timeout(const Duration(seconds: 2)),
          throwsA(isA<ConnectionGone>()));
    });

    test('连接还在时别的错原样抛出，不冒充断线', () async {
      final lease = SshLease.of(tab);
      await expectLater(
        lease.write('删除 /tmp/a', (_) async => throw StateError('没有这个文件')),
        throwsA(isA<StateError>()),
      );
      expect(lease.alive, isTrue);
    });

    test('下载流读到一半连接断了：流报 ConnectionGone 并结束', () async {
      final lease = SshLease.of(tab);
      final source = StreamController<Uint8List>();
      final chunks = <int>[];
      final done = Completer<Object?>();
      lease.readStream(source.stream).listen(
            (chunk) => chunks.add(chunk.length),
            onError: (Object error) => done.complete(error),
            onDone: () => done.isCompleted ? null : done.complete(null),
          );
      source.add(Uint8List(10));
      await Future<void>.delayed(Duration.zero);
      socket.drop();
      expect(await done.future.timeout(const Duration(seconds: 2)),
          isA<ConnectionGone>());
      expect(chunks, [10]);
      await source.close();
    });

    test('提示里只有主机名称和那一步，没有密码、地址、用户名（SEC12）', () {
      final texts = [
        const ConnectionGone('box').toString(),
        const OutcomeUnknown('删除 /tmp/a').toString(),
      ];
      for (final text in texts) {
        expect(text, isNot(contains('pw-SEC12-secret')));
        expect(text, isNot(contains('box.example')));
        expect(text, isNot(contains('alice')));
      }
    });
  });
}

/// 一直不说话的 socket：给借用一个真的 SSHClient 对象。[drop] 模拟对端断线（传输层随之关闭）。
class _QuietSocket implements SSHSocket {
  final _in = StreamController<Uint8List>();
  final _out = StreamController<List<int>>();
  _QuietSocket() {
    _out.stream.listen((_) {});
  }

  void drop() => unawaited(_in.close());

  @override
  Stream<Uint8List> get stream => _in.stream;
  @override
  StreamSink<List<int>> get sink => _out.sink;
  @override
  Future<void> get done => _in.done;
  @override
  Future<void> close() async => destroy();
  @override
  Future<void> flush() async {}
  @override
  void destroy() {
    unawaited(_in.close());
    unawaited(_out.close());
  }
}
