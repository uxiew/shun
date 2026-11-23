import 'dart:async';
import 'dart:convert';
import 'dart:ui' show SemanticsAction, Tristate;

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
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/screens/terminal_screen.dart';
import 'package:shun/presentation/screens/vault_screen.dart';
import 'package:shun/presentation/widgets/port_forward_sheet.dart';

import 'support/prism_test_host.dart';
import 'support/test_terminal.dart';
import 'support/ui_gallery_fixtures.dart' show UiGallerySessionController;

class _Client extends Fake implements SSHClient {
  @override
  bool get isClosed => false;
  @override
  Future<void> close() async {}
}

class _Forwards extends PortForwardController {
  final starts = <(ActiveTerminalSession, int, String?, int?)>[];
  Completer<void>? pending;

  @override
  Future<void> startLocal({
    required ActiveTerminalSession session,
    required int localPort,
    required String remoteHost,
    required int remotePort,
  }) {
    starts.add((session, localPort, remoteHost, remotePort));
    return pending?.future ?? Future.value();
  }

  @override
  Future<void> startDynamic({
    required ActiveTerminalSession session,
    required int localPort,
  }) {
    starts.add((session, localPort, null, null));
    return pending?.future ?? Future.value();
  }

  void seedRows() {
    state = [
      ActivePortForward(
          id: 'live',
          kind: ForwardKind.dynamic,
          localPort: 1080,
          hostLabel: 'web'),
      ActivePortForward(
          id: 'lost',
          kind: ForwardKind.local,
          localPort: 9000,
          remoteHost: 'db',
          remotePort: 5432,
          hostLabel: 'old',
          endedReason: 'SSH 连接断开了，转发已停止；不会自动重开'),
    ];
  }
}

enum _Entry { direct, terminal, vault }

Finder key(String name) => find.byKey(ValueKey(name));

Future<
    ({
      ActiveTerminalSession tab,
      _Forwards forwards,
      SessionController tabs
    })> _open(WidgetTester tester, {_Entry entry = _Entry.direct}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.reset);
  final host = HostProfile.create(
    id: 'web',
    label: 'web',
    hostname: 'web.invalid',
    username: 'user',
  );
  final tab = ActiveTerminalSession(
    id: 'tab',
    host: host,
    terminal: newTestTerminal(),
    verifyHostKey: (_, __, ___) async => false,
    keyboardInteractive: null,
    sshClients: [_Client()],
  );
  final forwards = _Forwards();
  SharedPreferences.setMockInitialValues({
    'shun_vault_v1': jsonEncode({
      'hosts': [host.toJson()]
    }),
    'shun_settings_v1': jsonEncode({'serverViewMode': 'list'}),
  });
  const storage = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(storage, (_) async => null);
  addTearDown(() => messenger.setMockMethodCallHandler(storage, null));
  final repository = await VaultRepository.open();
  final container = ProviderContainer(overrides: [
    vaultRepositoryProvider.overrideWithValue(repository),
    sessionControllerProvider.overrideWith((ref) => UiGallerySessionController(
          ref.read(vaultControllerProvider.notifier),
          ref,
          SessionState(sessions: [tab]),
        )),
    portForwardControllerProvider.overrideWith((_) => forwards),
  ]);
  addTearDown(container.dispose);
  if (entry == _Entry.terminal) {
    final strategy = tester.binding.schedulingStrategy;
    tester.binding.schedulingStrategy =
        ({required int priority, required SchedulerBinding scheduler}) => true;
    addTearDown(() => tester.binding.schedulingStrategy = strategy);
  }
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      localizationsDelegates: prismTestDelegates,
      builder: prismTestBuilder,
      home: Scaffold(
          body: switch (entry) {
        _Entry.terminal => const TerminalScreen(),
        _Entry.vault => const VaultScreen(),
        _Entry.direct => PortForwardSheet(session: tab),
      }),
    ),
  ));
  await tester.pumpAndSettle();
  if (entry == _Entry.terminal) {
    await tester.tap(key('terminal-action-port-forward'));
    await tester.pumpAndSettle();
  } else if (entry == _Entry.vault) {
    await tester.tap(key('vault-host-menu-web'));
    await tester.pumpAndSettle();
    await tester.tap(key('host-menu-portForward'));
    await tester.pumpAndSettle();
  }
  return (
    tab: tab,
    forwards: forwards,
    tabs: container.read(sessionControllerProvider.notifier)
  );
}

void main() {
  for (final entry in [_Entry.terminal, _Entry.vault]) {
    testWidgets('从 ${entry.name} 打开面板，用已有的标签启动本地转发', (tester) async {
      final rig = await _open(tester, entry: entry);
      expect(key('port-forward-sheet'), findsOneWidget);
      expect(
          tester.semantics
              .simulatedAccessibilityTraversal()
              .map((n) => n.label),
          containsAllInOrder([
            '端口转发',
            'web',
            '本地转发',
            'SOCKS5',
            '本地端口（0 为自动）',
            '远端主机',
            '端口',
            '启动'
          ]));
      await tester.tap(key('port-forward-start'));
      await tester.pump();
      expect(rig.forwards.starts, [(rig.tab, 8080, '127.0.0.1', 80)]);
      await tester.pumpAndSettle();
    });
  }

  testWidgets('切换类型保留输入，启动期间不能重复提交，错误可读且可重试', (tester) async {
    final rig = await _open(tester);
    final local = key('port-forward-local-port');
    final host = key('port-forward-remote-host');
    final port = key('port-forward-remote-port');
    final start = key('port-forward-start');
    final dynamicKind = key('port-forward-dynamic');
    final pending = rig.forwards.pending = Completer<void>();
    expect(tester.getTopLeft(host).dy - tester.getBottomLeft(local).dy,
        greaterThanOrEqualTo(20));
    await tester.enterText(local, '0');
    await tester.enterText(host, ' db.internal ');
    await tester.enterText(port, '5432');
    await tester.tap(dynamicKind);
    await tester.pumpAndSettle();
    expect(tester.getSemantics(dynamicKind).flagsCollection.isSelected,
        Tristate.isTrue);
    expect(host, findsNothing);
    expect(port, findsNothing);
    await tester.tap(start);
    await tester.tap(start);
    await tester.pump();
    expect(rig.forwards.starts, [(rig.tab, 0, null, null)]);
    expect(tester.getSemantics(start).label, contains('处理中'));
    expect(
        tester
            .getSemantics(start)
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isFalse);
    await tester.tap(start);
    await tester.pump();
    expect(rig.forwards.starts, hasLength(1));
    rig.forwards.pending = null;
    pending.completeError(StateError('port in use'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Bad state: port in use'), findsOneWidget);
    await tester.tap(key('port-forward-local'));
    await tester.pumpAndSettle();
    await tester.tap(start);
    await tester.pumpAndSettle();
    expect(rig.forwards.starts.last, (rig.tab, 0, 'db.internal', 5432));
  });

  testWidgets('主机菜单弹层直接显示端口占用错误，不影响已有转发，重试清除错误', (tester) async {
    final rig = await _open(tester, entry: _Entry.vault);
    rig.forwards.seedRows();
    await tester.pumpAndSettle();
    final localPort = key('port-forward-local-port');
    final start = key('port-forward-start');
    final pending = rig.forwards.pending = Completer<void>();
    await tester.enterText(localPort, '1080');
    await tester.tap(start);
    pending.completeError(StateError('port in use'));
    await tester.pumpAndSettle();

    final message = find.text('Bad state: port in use');
    expect(message.hitTestable(), findsOneWidget);
    expect(find.descendant(of: key('port-forward-sheet'), matching: message),
        findsOneWidget);
    expect(tester.getSemantics(message).flagsCollection.isLiveRegion, isTrue);
    expect(key('port-forward-running-live'), findsOneWidget);

    rig.forwards.pending = null;
    await tester.enterText(localPort, '0');
    await tester.tap(start);
    await tester.pumpAndSettle();
    expect(message, findsNothing);
    expect(rig.forwards.starts.last, (rig.tab, 0, '127.0.0.1', 80));
  });

  testWidgets('断线立即禁用启动；列表保留主机和原因，只有行尾能停止或去除', (tester) async {
    final rig = await _open(tester);
    rig.forwards.seedRows();
    rig.tab.connected = false;
    rig.tabs.activate(0);
    await tester.pumpAndSettle();
    final start = key('port-forward-start');
    expect(
        tester.getSemantics(start).flagsCollection.isEnabled, Tristate.isFalse);
    await tester.tap(start);
    expect(rig.forwards.starts, isEmpty);
    expect(key('port-forward-disconnected'), findsOneWidget);
    expect(key('port-forward-running-live'), findsOneWidget);
    expect(key('port-forward-stopped-lost'), findsOneWidget);

    const live = 'SOCKS5 127.0.0.1:1080\nweb';
    const lost = '127.0.0.1:9000 → db:5432\nold · SSH 连接断开了，转发已停止；不会自动重开';
    final nodes = tester.semantics.simulatedAccessibilityTraversal();
    expect(
        nodes.map((n) => n.label.isEmpty ? n.tooltip : n.label),
        containsAllInOrder([
          '连接已断开，开不了新转发。重新连接后再从新连接打开。',
          '启动',
          '运行中',
          live,
          '停止',
          '已停止',
          lost,
          '从列表里去掉',
        ]));
    for (final label in [live, lost]) {
      final row = nodes.singleWhere((n) => n.label == label).getSemanticsData();
      expect(row.flagsCollection.isButton, isFalse);
      expect(row.hasAction(SemanticsAction.tap), isFalse);
    }
    for (final action in [
      'port-forward-stop-live',
      'port-forward-remove-lost'
    ]) {
      final node = tester.getSemantics(key(action)).getSemanticsData();
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.hasAction(SemanticsAction.tap), isTrue);
    }
    await tester.tap(key('port-forward-stop-live'));
    await tester.pumpAndSettle();
    expect(key('port-forward-running-live'), findsNothing);
    expect(key('port-forward-stopped-lost'), findsOneWidget);
    await tester.tap(key('port-forward-remove-lost'));
    await tester.pumpAndSettle();
    expect(key('port-forward-stopped-lost'), findsNothing);
    expect(find.bySemanticsLabel('已停止'), findsNothing);
  });
}
