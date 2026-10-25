import 'dart:async';
import 'dart:io' hide ProcessSignal;
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/port_forward_controller.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/infrastructure/ssh/server_monitor_service.dart';
import 'package:shun/infrastructure/ssh/system_management_service.dart';
import 'package:shun/presentation/screens/terminal_screen.dart';
import 'package:shun/presentation/widgets/server_monitor_sheet.dart';
import 'package:shun/presentation/widgets/system_management/system_management_sheet.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/presentation/widgets/port_forward_sheet.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/screens/sftp_screen.dart';
import 'package:shun/presentation/widgets/sftp_editor.dart';
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

    // LIFE06（10-25）：以前每一步都在「连接断了」的 future 上挂一个监听，连接不断就永远不摘，
    // 连同那一步的结果一起留着；监控复用一个借用、每 3 秒采一次，就每 3 秒多留一份。
    test('复用的借用做完一步就不再等断线：做 100 步不攒东西，没做完的照样报断线', () async {
      final lease = SshLease.of(tab);
      for (var i = 0; i < 100; i++) {
        expect(await lease.read((_) async => 'sample $i'), 'sample $i');
      }
      await expectLater(
        lease.write('删除 /tmp/a', (_) async => throw StateError('没有这个文件')),
        throwsA(isA<StateError>()),
      );
      expect(lease.pendingWatchers, 0);

      final reading = lease.read((_) => Completer<int>().future);
      expect(lease.pendingWatchers, 1, reason: '还没做完的那一步要等断线');
      socket.drop();
      await expectLater(reading.timeout(const Duration(seconds: 2)),
          throwsA(isA<ConnectionGone>()));
      expect(lease.pendingWatchers, 0);
    });

    test('下载流读完、被取消以后也不再等断线', () async {
      final lease = SshLease.of(tab);
      final finished = StreamController<Uint8List>();
      final chunks = lease.readStream(finished.stream).toList();
      expect(lease.pendingWatchers, 1);
      finished.add(Uint8List(3));
      await finished.close();
      expect(await chunks, hasLength(1));
      expect(lease.pendingWatchers, 0);

      final endless = StreamController<Uint8List>();
      final subscription = lease.readStream(endless.stream).listen((_) {});
      expect(lease.pendingWatchers, 1);
      await subscription.cancel();
      expect(lease.pendingWatchers, 0);
      await endless.close();
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
  previewAndSave();
  portForwards(session);
  monitorAndSystem(session);
}

void portForwards(
    ActiveTerminalSession Function({List<SSHClient> clients}) session) {
  group('端口转发跟着借来的连接走（REG01）', () {
    late _QuietSocket socket;
    late ActiveTerminalSession tab;
    late PortForwardController forwards;

    setUp(() {
      socket = _QuietSocket();
      tab = session(clients: [SSHClient(socket, username: 'alice')]);
      forwards = PortForwardController();
    });

    tearDown(() {
      tab.abort();
      forwards.dispose();
    });

    Future<bool> accepts(int port) async {
      try {
        (await Socket.connect('127.0.0.1', port)).destroy();
        return true;
      } on SocketException {
        return false;
      }
    }

    test('断开的标签上不开转发：报 ConnectionGone，本机端口一个也没开', () async {
      tab.connected = false;
      await expectLater(
          forwards.startLocal(
              session: tab, localPort: 0, remoteHost: 'x', remotePort: 1),
          throwsA(isA<ConnectionGone>()));
      expect(forwards.state, isEmpty);
    });

    test('连接断了：本机端口关掉、接进来的连接断掉，条目标成已停止，不重开', () async {
      await forwards.startLocal(
          session: tab, localPort: 0, remoteHost: 'db', remotePort: 5432);
      final port = forwards.state.single.localPort;
      expect(await accepts(port), isTrue);
      final waiting = await Socket.connect('127.0.0.1', port);
      final closed =
          waiting.drain<void>().then((_) => true, onError: (_) => true);
      expect(forwards.forwardsOn(tab), hasLength(1));

      socket.drop();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final item = forwards.state.single;
      expect(item.running, isFalse);
      expect(item.endedReason, contains('不会自动重开'));
      expect(item.hostLabel, 'box');
      expect(await accepts(port), isFalse, reason: '本机端口已关');
      expect(await closed.timeout(const Duration(seconds: 2)), isTrue,
          reason: '已经接进来的连接也断了');
      expect(forwards.forwardsOn(tab), isEmpty, reason: '已停止的不算「在这条连接上」');

      await forwards.stop(item.id);
      expect(forwards.state, isEmpty, reason: '已停止的可以从列表里去掉');
    });

    test('用户关标签：原因写「标签已关闭」；释放时先停转发再关 SSH', () async {
      await forwards.startLocal(
          session: tab, localPort: 0, remoteHost: 'db', remotePort: 5432);
      final port = forwards.state.single.localPort;
      await tab.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(forwards.state.single.endedReason, contains('标签已关闭'));
      expect(await accepts(port), isFalse);
    });

    test('本机端口被占：报错，不留半个条目', () async {
      final busy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      await expectLater(
          forwards.startLocal(
              session: tab,
              localPort: busy.port,
              remoteHost: 'db',
              remotePort: 5432),
          throwsA(isA<SocketException>()));
      expect(forwards.state, isEmpty);
      await busy.close();
    });
  });

  group('端口转发面板', () {
    Future<void> show(WidgetTester tester, ActiveTerminalSession tab,
        List<ActivePortForward> items) async {
      SharedPreferences.setMockInitialValues({});
      final repository = await VaultRepository.open();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          vaultRepositoryProvider.overrideWithValue(repository),
          portForwardControllerProvider
              .overrideWith((ref) => _SeededForwards(items)),
        ],
        child:
            MaterialApp(home: Scaffold(body: PortForwardSheet(session: tab))),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('标签已断开：写明原因，「启动」点不了', (tester) async {
      final tab = session()..connected = false;
      await show(tester, tab, const []);
      expect(find.byKey(const ValueKey('port-forward-disconnected')),
          findsOneWidget);
      final start = tester.widget<FilledButton>(find.ancestor(
          of: find.text('启动'), matching: find.byType(FilledButton)));
      expect(start.onPressed, isNull);
    });

    testWidgets('已停止的单独一节：写主机和停止原因', (tester) async {
      final tab = session()..connected = false;
      await show(tester, tab, [
        ActivePortForward(
          id: 'f1',
          kind: ForwardKind.local,
          localPort: 8080,
          remoteHost: 'db',
          remotePort: 5432,
          hostLabel: 'box',
          endedReason: 'SSH 连接断开了，转发已停止；不会自动重开',
        ),
      ]);
      expect(find.text('已停止'), findsOneWidget);
      expect(find.text('运行中'), findsNothing);
      expect(find.textContaining('不会自动重开'), findsOneWidget);
      expect(find.textContaining('box'), findsWidgets);
    });
  });
}

void monitorAndSystem(
    ActiveTerminalSession Function({List<SSHClient> clients}) session) {
  group('监控、系统管理只借这一代连接（REG01 / NET11）', () {
    late _QuietSocket socket;
    late ActiveTerminalSession tab;

    setUp(() {
      socket = _QuietSocket();
      tab = session(clients: [SSHClient(socket, username: 'alice')]);
    });

    tearDown(() => tab.abort());

    test('SshLease.reuse：连着时一直是同一个借用；断了以后报 ConnectionGone，不换新连接', () async {
      final cache = Expando<SshLease>();
      final first = SshLease.reuse(cache, tab);
      expect(identical(SshLease.reuse(cache, tab), first), isTrue,
          reason: '每 3 秒采样一次也不在标签上越攒越多释放钩子');
      socket.drop();
      await first.lost.timeout(const Duration(seconds: 2));
      expect(() => SshLease.reuse(cache, tab), throwsA(isA<ConnectionGone>()));
    });

    test('监控：采样等回复时连接断了，采样器马上停下并通知面板，不再每 3 秒重试', () async {
      final monitor = SessionMonitor(tab);
      var notified = 0;
      monitor.addListener(() => notified++);
      monitor.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(monitor.polling, isTrue, reason: '假连接不回复，采样一直在等');
      socket.drop();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(monitor.stopped, isTrue);
      expect(monitor.polling, isFalse);
      expect(notified, greaterThan(0));
      monitor.dispose();
    });

    test('监控：断开的标签不采样，直接停', () {
      tab.connected = false;
      final monitor = SessionMonitor(tab)..start();
      expect(monitor.stopped, isTrue);
      expect(monitor.polling, isFalse);
      // 停了就不该再留每 3 秒一次的定时器（以前先采样后建定时器，停了又开）。
      monitor.start();
      expect(monitor.stopped, isTrue);
      monitor.dispose();
    });

    test('系统管理：会改动服务器的命令发出后断了，报「结果未知」并写明是哪一步', () async {
      final service = SystemManagementService();
      final signal = service.signalProcess(tab, 4242, ProcessSignal.term);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      socket.drop();
      await expectLater(
          signal.timeout(const Duration(seconds: 2)),
          throwsA(isA<OutcomeUnknown>()
              .having((e) => e.action, 'action', '进程信号「4242 TERM」')));
    });

    test('系统管理：只读的列表断了报「已断开」；断了以后再点改动的操作，根本不发', () async {
      final service = SystemManagementService();
      final listing = service.listProcesses(tab);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      socket.drop();
      await expectLater(listing.timeout(const Duration(seconds: 2)),
          throwsA(isA<ConnectionGone>()));
      await expectLater(service.signalProcess(tab, 4242, ProcessSignal.kill),
          throwsA(isA<ConnectionGone>()),
          reason: 'ConnectionGone = 没执行；OutcomeUnknown 只给发出去以后断的');
    });
  });

  group('断开以后的面板和入口（停止条件：不留点了没用的按钮）', () {
    testWidgets('监控面板：断开的标签写明原因，刷新点不了', (tester) async {
      final tab = session()..connected = false;
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: ServerMonitorSheet(session: tab))));
      await tester.pump();
      expect(
          find.byKey(const ValueKey('monitor-disconnected')), findsOneWidget);
      final refresh = tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.refresh));
      expect(refresh.onPressed, isNull);
    });

    testWidgets('系统管理面板：断开的标签写明原因，整页点不动', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final repository = await VaultRepository.open();
      final tab = session()..connected = false;
      await tester.pumpWidget(ProviderScope(
        overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          home: Scaffold(
            body: SystemManagementSheet(
              session: tab,
              snippets: const [],
              onOpenTerminal: (_, __) async {},
              onOpenSftp: (_) {},
            ),
          ),
        ),
      ));
      await tester.pump();
      expect(find.byKey(const ValueKey('system-management-disconnected')),
          findsOneWidget);
      final absorb = tester.widget<AbsorbPointer>(find
          .ancestor(
              of: find.byType(TabBarView), matching: find.byType(AbsorbPointer))
          .first);
      expect(absorb.absorbing, isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('终端快捷栏：SSH 标签断开后「端口转发」「系统管理」变灰，连着时能点', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final repository = await VaultRepository.open();
      final messenger = tester.binding.defaultBinaryMessenger;
      const pip = MethodChannel('top.xdwa.shun/picture_in_picture');
      messenger.setMockMethodCallHandler(pip, (call) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(pip, null));
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      // 同 terminal_connection_banner_test：让 flterm 的空闲任务不等动画。
      final strategy = tester.binding.schedulingStrategy;
      tester.binding.schedulingStrategy = (
              {required int priority, required SchedulerBinding scheduler}) =>
          true;
      addTearDown(() => tester.binding.schedulingStrategy = strategy);

      final tab =
          session(clients: [SSHClient(_QuietSocket(), username: 'alice')]);
      late _FixedSessions controller;
      final container = ProviderContainer(overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
        sessionControllerProvider.overrideWith((ref) => controller =
            _FixedSessions(ref.read(vaultControllerProvider.notifier), ref,
                SessionState(sessions: [tab]))),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: TerminalScreen())),
      ));
      await tester.pump(const Duration(milliseconds: 500));
      IconButton action(String name) => tester
          .widget<IconButton>(find.byKey(ValueKey('terminal-action-$name')));
      expect(action('port-forward').onPressed, isNotNull);
      expect(action('system-management').onPressed, isNotNull);

      tab.connected = false;
      controller.publish(SessionState(sessions: [tab]));
      await tester.pump(const Duration(milliseconds: 500));
      expect(action('port-forward').onPressed, isNull);
      expect(action('system-management').onPressed, isNull);

      tab.abort();
      await tester.pumpWidget(const SizedBox());
    });
  });
}

class _FixedSessions extends SessionController {
  _FixedSessions(
    VaultController vaultController,
    Ref ref,
    SessionState initialState,
  ) : super(SshService(), vaultController, ref) {
    state = initialState;
  }

  void publish(SessionState value) => state = value;
}

class _SeededForwards extends PortForwardController {
  _SeededForwards(List<ActivePortForward> items) {
    state = items;
  }
}

void previewAndSave() {
  Future<void> openFilePage(WidgetTester tester, _MemoryPhone phone) async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    await tester.pumpWidget(ProviderScope(
      overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
      child: MaterialApp(
        home: Scaffold(body: SftpScreen(localService: Future.value(phone))),
      ),
    ));
    await tester.pumpAndSettle();
  }

  group('预览有上限、保存先核对（UX12）', () {
    test('readBounded 读到上限多 1 字节就停，不把 10 MiB 整个读完', () async {
      final files = _MemoryFiles({})..put('/big', Uint8List(10 * 1024 * 1024));
      await expectLater(
          files.readBounded('/big'), throwsA(isA<PreviewTooLarge>()));
      expect(files.bytesRead, lessThanOrEqualTo(previewLimit + 64 * 1024));
      files.bytesRead = 0;
      files.put('/small', Uint8List(previewLimit));
      expect((await files.readBounded('/small')).length, previewLimit,
          reason: '刚好 1 MiB 的还能打开');
    });

    testWidgets('超过 1 MB 的文件：不打开、不自动下载，问要不要下载', (tester) async {
      final phone = _MemoryPhone({})
        ..put('/big.log', Uint8List(previewLimit + 1));
      await openFilePage(tester, phone);
      await tester.tap(find.text('big.log').first);
      await tester.pumpAndSettle();
      expect(find.text('文件太大，不在这里打开'), findsOneWidget);
      expect(phone.bytesRead, 0, reason: '一个字节都没读');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(phone.bytesRead, 0, reason: '点了取消就不下载');
    });

    testWidgets('列表里的大小过时（文件又变大了）：读到上限就停，同样问要不要下载', (tester) async {
      final phone = _MemoryPhone({})
        ..put('/grow.log', Uint8List(4 * 1024 * 1024))
        ..listedSizes['/grow.log'] = 10;
      await openFilePage(tester, phone);
      await tester.tap(find.text('grow.log').first);
      await tester.pumpAndSettle();
      expect(find.text('文件太大，不在这里打开'), findsOneWidget);
      expect(phone.bytesRead, lessThanOrEqualTo(previewLimit + 64 * 1024));
      expect(find.byType(SftpEditor), findsNothing);
    });

    testWidgets('编辑器保存前核对：服务器上的文件在打开后变了，要用户确认才覆盖', (tester) async {
      final phone = _MemoryPhone({'/a.txt': 'v1'});
      await openFilePage(tester, phone);
      await tester.tap(find.text('a.txt').first);
      await tester.pumpAndSettle();
      expect(find.byType(SftpEditor), findsOneWidget);
      phone.put('/a.txt', Uint8List.fromList('changed by someone'.codeUnits));
      await tester.enterText(find.byType(TextField).first, 'mine');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('服务器上的文件变了'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(phone.text('/a.txt'), 'changed by someone', reason: '没同意就没写');
      expect(find.textContaining('没有保存'), findsOneWidget);

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('仍然保存'));
      await tester.pumpAndSettle();
      expect(phone.text('/a.txt'), 'mine');

      // 刚保存过的版本就是新的基准：再保存不再问。
      await tester.enterText(find.byType(TextField).first, 'mine again');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('服务器上的文件变了'), findsNothing);
      expect(phone.text('/a.txt'), 'mine again');
    });
  });
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
  String joinPath(String path, String name) =>
      path == '/' ? '/$name' : '$path/$name';
  @override
  String parentPath(String path) {
    final at = path.lastIndexOf('/');
    return at <= 0 ? '/' : path.substring(0, at);
  }

  /// 列目录时报的大小：可以让它过时（文件在列表之后又变大了）。
  final listedSizes = <String, int>{};

  /// 每次 [readStream] 交出去的字节数：按 64 KiB 一块交，预览读够了就该停。
  var bytesRead = 0;

  @override
  Future<List<RemoteEntry>> list(String path) async => [
        for (final e in _files.entries)
          if (parentPath(e.key) == path && !e.key.endsWith('.shun-part'))
            RemoteEntry(
                name: e.key.split('/').last,
                path: e.key,
                isDirectory: false,
                size: listedSizes[e.key] ?? e.value.length),
      ];
  @override
  Stream<Uint8List> readStream(String path,
      {int startOffset = 0, TransferProgressCallback? onProgress}) async* {
    final data = _files[path]!;
    for (var at = startOffset; at < data.length; at += 64 * 1024) {
      final chunk = Uint8List.sublistView(
          data, at, (at + 64 * 1024).clamp(0, data.length));
      bytesRead += chunk.length;
      yield chunk;
    }
  }

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

  void put(String path, Uint8List data) => _files[path] = data;
}

/// 挂在文件页里的「手机目录」：预览、编辑、下载弹框的代码和服务器那一栏是同一份。
class _MemoryPhone extends _MemoryFiles
    implements MountableFileTransferService {
  _MemoryPhone(super.files);

  @override
  String get id => 'local';
  @override
  bool get isLocal => true;
  @override
  bool get isMounted => true;
  @override
  String? get mountedDirectoryName => 'phone';
  @override
  bool get usesAppDocuments => true;
  @override
  Future<bool> mount() async => true;
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
