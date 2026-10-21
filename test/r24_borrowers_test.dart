import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/sftp_service.dart';
import 'package:shun/infrastructure/ssh/ssh_lease.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/presentation/widgets/sftp_transfer_dialogs.dart';

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
      await expectLater(reading.timeout(const Duration(seconds: 2)),
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

  transferOutcomes();
  transferDialogs();
}

void transferDialogs() {
  /// 在一个空页面上弹 [open] 的对话框，点 [tap]（null 表示不点），返回对话框的结果。
  Future<Object?> run(WidgetTester tester,
      Future<Object?> Function(BuildContext context) open, String? tap) async {
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
      context = c;
      return const SizedBox();
    })));
    Object? result = #pending;
    unawaited(open(context).then((value) => result = value));
    await tester.pumpAndSettle();
    if (tap != null) {
      await tester.tap(find.text(tap));
      await tester.pumpAndSettle();
    }
    return result;
  }

  group('传输前的两个问题：替不替换、续不续传', () {
    testWidgets('替换同名文件：写出文件名和大小；取消就是不替换', (tester) async {
      Future<bool> open(BuildContext c) =>
          confirmReplaceDialog(c, 'a.txt', const FileStamp(2048, null));
      expect(await run(tester, open, '取消'), isFalse);
      expect(await run(tester, open, '替换'), isTrue);
      await run(tester, open, null);
      expect(find.textContaining('a.txt'), findsOneWidget);
      expect(find.textContaining('2.0 KB'), findsOneWidget);
    });

    testWidgets('续传：没有半截或半截比文件还大时不问，直接从头传', (tester) async {
      final none = _MemoryFiles({});
      expect(
          await run(tester,
              (c) => askResumeDialog(c, none, '/d/a.part', 'a', 10), null),
          isFalse);
      final bigger = _MemoryFiles({'/d/a.part': '0123456789AB'});
      expect(
          await run(tester,
              (c) => askResumeDialog(c, bigger, '/d/a.part', 'a', 10), null),
          isFalse);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('续传：有半截时写出已传多少；续传 / 从头传 / 取消各自不同', (tester) async {
      final files = _MemoryFiles({'/d/a.part': '0123'});
      Future<bool?> open(BuildContext c) =>
          askResumeDialog(c, files, '/d/a.part', 'a.bin', 10);
      expect(await run(tester, open, '续传'), isTrue);
      expect(await run(tester, open, '从头传'), isFalse);
      expect(await run(tester, open, '取消'), isNull);
      await run(tester, open, null);
      expect(find.textContaining('4 B / 10 B'), findsOneWidget);
    });
  });
}

void transferOutcomes() {
  Stream<Uint8List> bytes(String text) =>
      Stream.value(Uint8List.fromList(text.codeUnits));

  group('上传 / 复制的结果：取消、中断、未知分得清（UX12）', () {
    test('不续传时旧的临时文件从头覆盖，不拼在前面', () async {
      final files = _MemoryFiles({'/d/a.txt.shun-part': 'OLD-'});
      await writeStreamAtomically(files, '/d/a.txt', bytes('new'),
          totalBytes: 3);
      expect(files.text('/d/a.txt'), 'new');
      expect(files.exists('/d/a.txt.shun-part'), isFalse);
    });

    test('用户选了续传：接着临时文件往后写，源里已传的部分跳过', () async {
      final files = _MemoryFiles({'/d/a.txt.shun-part': 'ab'});
      await writeStreamAtomically(files, '/d/a.txt', bytes('abcd'),
          totalBytes: 4, resume: true);
      expect(files.text('/d/a.txt'), 'abcd');
    });

    test('目标已有同名文件、用户没同意替换：不动它，报 TargetExists', () async {
      final files = _MemoryFiles({'/d/a.txt': 'keep'});
      await expectLater(
          writeStreamAtomically(files, '/d/a.txt', bytes('new'), totalBytes: 3),
          throwsA(isA<TargetExists>()));
      expect(files.text('/d/a.txt'), 'keep');
    });

    test('用户同意替换：换成新内容', () async {
      final files = _MemoryFiles({'/d/a.txt': 'keep'});
      await writeStreamAtomically(files, '/d/a.txt', bytes('new'),
          totalBytes: 3, replace: true);
      expect(files.text('/d/a.txt'), 'new');
    });

    test('写临时文件时连接断了：目标没动过，报 TransferInterrupted（不是「结果未知」）', () async {
      final files = _MemoryFiles({'/d/a.txt': 'keep'})
        ..failWrite = const OutcomeUnknown('写入「/d/a.txt.shun-part」');
      await expectLater(
        writeStreamAtomically(files, '/d/a.txt', bytes('new'),
            totalBytes: 3, replace: true),
        throwsA(isA<TransferInterrupted>()
            .having((e) => e.target, 'target', '/d/a.txt')
            .having((e) => e.partialPath, 'partial', '/d/a.txt.shun-part')),
      );
      expect(files.text('/d/a.txt'), 'keep');
      expect(files.renames, isEmpty, reason: '没换名，目标没被碰');
    });

    test('连接在发出前就没了、一个字节没写：原样报 ConnectionGone', () async {
      final files = _MemoryFiles({})..failWrite = const ConnectionGone('box');
      await expectLater(
          writeStreamAtomically(files, '/d/a.txt', bytes('new'), totalBytes: 3),
          throwsA(isA<ConnectionGone>()));
    });

    test('断在「把临时文件换成目标」那一步：只有这里是「结果未知」', () async {
      final files = _MemoryFiles({'/d/a.txt': 'keep'})
        ..failRename =
            const OutcomeUnknown('改名「/d/a.txt.shun-part」→「/d/a.txt」');
      await expectLater(
          writeStreamAtomically(files, '/d/a.txt', bytes('new'),
              totalBytes: 3, replace: true),
          throwsA(isA<OutcomeUnknown>()));
    });

    test('服务器卡住不回复时点取消：马上取消，不换名', () async {
      final files = _MemoryFiles({'/d/a.txt': 'keep'})..hangWrite = true;
      final token = TransferCancellationToken();
      final upload = writeStreamAtomically(files, '/d/a.txt', bytes('new'),
          totalBytes: 3, replace: true, cancellationToken: token);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      token.cancel();
      await expectLater(upload.timeout(const Duration(seconds: 1)),
          throwsA(isA<TransferCancelledException>()));
      expect(files.renames, isEmpty);
      expect(files.text('/d/a.txt'), 'keep');
    });

    test('传到另一栏默认不续传；目标已有同名文件不替换', () async {
      final source = _MemoryFiles({'/s/a.txt': 'fresh'});
      final target = _MemoryFiles({'/t/.a.txt.shun-part': 'STALE'});
      const entry = RemoteEntry(
          name: 'a.txt', path: '/s/a.txt', isDirectory: false, size: 5);
      await transferEntry(source, entry, target, '/t');
      expect(target.text('/t/a.txt'), 'fresh');
      await expectLater(transferEntry(source, entry, target, '/t'),
          throwsA(isA<TargetExists>()));
    });

    test('cancelOnDemand：源一直不出数据时点取消，流马上报取消', () async {
      final token = TransferCancellationToken();
      final silent = StreamController<Uint8List>();
      final done = cancelOnDemand(silent.stream, token).toList();
      token.cancel();
      await expectLater(done.timeout(const Duration(seconds: 1)),
          throwsA(isA<TransferCancelledException>()));
      await silent.close();
    });

    test('提示里只有路径，没有主机地址和凭据（SEC12）', () {
      final texts = [
        const TransferInterrupted('/d/a', '/d/a.shun-part').toString(),
        const TargetExists('/d/a').toString(),
      ];
      for (final text in texts) {
        expect(text, contains('/d/a'));
        expect(text, isNot(contains('pw-SEC12-secret')));
      }
    });
  });
}

/// 内存里的文件来源：只实现传输要用的几样，可以让写入 / 改名失败或挂住。
class _MemoryFiles extends FileTransferService {
  _MemoryFiles(Map<String, String> files)
      : _files = {
          for (final e in files.entries)
            e.key: Uint8List.fromList(e.value.codeUnits)
        };

  final Map<String, Uint8List> _files;
  final renames = <String>[];
  Object? failWrite;
  Object? failRename;
  bool hangWrite = false;

  bool exists(String path) => _files.containsKey(path);
  String text(String path) => String.fromCharCodes(_files[path]!);

  @override
  String get id => 'memory';
  @override
  String get displayName => 'memory';
  @override
  String get rootPath => '/';
  @override
  bool get isLocal => false;
  @override
  String displayPath(String path) => path;
  @override
  String joinPath(String path, String name) => '$path/$name';
  @override
  String parentPath(String path) => path.substring(0, path.lastIndexOf('/'));
  @override
  Future<List<RemoteEntry>> list(String path) async => [
        for (final e in _files.entries)
          if (parentPath(e.key) == path)
            RemoteEntry(
                name: e.key.split('/').last,
                path: e.key,
                isDirectory: false,
                size: e.value.length),
      ];
  @override
  Stream<Uint8List> readStream(String path,
          {int startOffset = 0, TransferProgressCallback? onProgress}) =>
      Stream.value(Uint8List.sublistView(_files[path]!, startOffset));
  @override
  Future<void> writeStream(String path, Stream<Uint8List> stream,
      {int startOffset = 0,
      bool truncate = true,
      TransferProgressCallback? onProgress}) async {
    if (failWrite case final error?) throw error;
    if (hangWrite) return Completer<void>().future;
    final builder = BytesBuilder()
      ..add(truncate ? const <int>[] : _files[path] ?? const <int>[]);
    var written = 0;
    await for (final chunk in stream) {
      builder.add(chunk);
      written += chunk.length;
      onProgress?.call(written);
    }
    _files[path] = builder.takeBytes();
  }

  @override
  Future<int?> fileSize(String path) async => _files[path]?.length;
  @override
  Future<void> mkdir(String path) async {}
  @override
  Future<void> ensureDirectory(String path) async {}
  @override
  Future<void> rename(String from, String to) async {
    if (failRename case final error?) throw error;
    renames.add('$from -> $to');
    _files[to] = _files.remove(from)!;
  }

  @override
  Future<void> delete(RemoteEntry entry) async => _files.remove(entry.path);
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
