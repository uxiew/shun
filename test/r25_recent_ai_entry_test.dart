import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/ai_cli.dart';
import 'package:shun/domain/ai_cli_launch.dart';
import 'package:shun/domain/ai_cli_work.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/ai_cli_preferences.dart';
import 'package:shun/infrastructure/storage/ai_cli_recent_work.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/screens/vault_screen.dart';
import 'package:shun/presentation/widgets/ai_cli_tools_sheet.dart';

import 'support/test_terminal.dart';
import 'support/prism_test_host.dart';

/// R25 接 R57：首页「最近 AI 工作」卡片要如实说原终端还在不在，还在就直接回去。
/// 判断只看本机标签（和工具列表里「返回原终端」同一个条件），不拨号。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const hostData = {
    'id': 'host-1',
    'label': 'Server',
    'hostname': '192.0.2.10',
    'username': 'root',
    'protocol': 'ssh',
  };
  final work = AiCliWorkItem(
    id: 'tab',
    tool: AiCliKind.claude,
    name: 'Claude Code',
    executable: '/bin/claude',
    projectDirectory: '/repo',
    openedAt: DateTime.utc(2026, 10, 12),
  );

  Future<({ProviderContainer container, _Recent recent})> open(
      WidgetTester tester, List<ActiveTerminalSession> sessions,
      {Widget Function(_Recent recent)? page}) async {
    const channel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    SharedPreferences.setMockInitialValues({
      'shun_vault_v1': jsonEncode({
        'hosts': [hostData],
        'keys': const [],
        'snippets': const [],
        'customGroups': const [],
      }),
    });
    final repository = await VaultRepository.open();
    final recent = _Recent([work]);
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      sessionControllerProvider.overrideWith((ref) => _Seeded(
            ref.read(vaultControllerProvider.notifier),
            ref,
            SessionState(sessions: sessions),
          )),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          localizationsDelegates: prismTestDelegates,
          builder: prismTestBuilder,
          home: Scaffold(
              body: page?.call(recent) ?? VaultScreen(recentWork: recent))),
    ));
    await tester.pumpAndSettle();
    return (container: container, recent: recent);
  }

  ActiveTerminalSession tab(String id, {AiCliLaunchSpec? launch}) {
    final terminal = newTestTerminal();
    addTearDown(terminal.dispose);
    return ActiveTerminalSession(
      id: id,
      host: HostProfile(Map<String, Object?>.of(hostData)),
      terminal: terminal,
      verifyHostKey: (_, __, ___) async => false,
      keyboardInteractive: null,
      aiLaunch: launch,
    );
  }

  final launch =
      AiCliLaunchSpec(executable: '/bin/claude', projectDirectory: '/repo');

  testWidgets('原终端还连着：卡片直接说，点了切到那个标签，不开工具列表', (tester) async {
    final opened =
        await open(tester, [tab('other'), tab('tab', launch: launch)]);
    final state = find.byKey(const ValueKey('vault-recent-ai-state'));
    expect(find.descendant(of: state, matching: find.text('原终端仍连接')),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('vault-recent-ai-work')));
    await tester.pumpAndSettle();
    expect(find.byType(AiCliToolsSheet), findsNothing);
    expect(opened.container.read(sessionControllerProvider).activeIndex, 1);
    expect(opened.container.read(homeTabProvider), 1);
    expect(opened.recent.recorded.single.id, 'tab',
        reason: '回去也算打开过一次，排序跟工具列表里「返回原终端」一致');
  });

  testWidgets('标签还在但断了、或者里面换成了别的东西：说待核对，不假装还在', (tester) async {
    final dropped = tab('tab', launch: launch)..connected = false;
    final opened = await open(tester, [dropped]);
    expect(find.textContaining('会话状态待核对'), findsOneWidget);
    expect(find.textContaining('原终端仍连接'), findsNothing);

    // 重新连上：卡片跟着变，不用离开首页。
    dropped.connected = true;
    final controller =
        opened.container.read(sessionControllerProvider.notifier) as _Seeded;
    controller.replace(SessionState(sessions: [dropped]));
    await tester.pump();
    expect(find.textContaining('原终端仍连接'), findsOneWidget);

    // 同一个标签里已经不是当初启动的工具了（比如重连成了普通 shell）。
    dropped.aiTerminalOriginal = false;
    controller.replace(SessionState(sessions: [dropped]));
    await tester.pump();
    expect(find.textContaining('会话状态待核对'), findsOneWidget);
  });

  testWidgets('工具列表里的「返回原终端」和首页卡片走同一条路：切标签、关列表、记一次', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    final opened = await open(
      tester,
      [tab('other'), tab('tab', launch: launch)],
      page: (recent) => Builder(
        key: navigator,
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              body: AiCliToolsSheet(
                host: HostProfile(Map<String, Object?>.of(hostData)),
                recentWork: recent,
                preferences: _Preferences(),
                scan: (_, __) async => AiCliScanResult(
                  unixUser: 'root',
                  uid: '0',
                  scannedAt: DateTime(2026, 10, 22),
                  installations: const [
                    AiCliInstallation(
                        kind: AiCliKind.claude,
                        name: 'Claude Code',
                        path: '/bin/claude',
                        source: 'PATH'),
                  ],
                ),
              ),
            ),
          )),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-cli-recent-tab')));
    await tester.pumpAndSettle();
    expect(find.byType(AiCliToolsSheet), findsNothing);
    expect(opened.container.read(sessionControllerProvider).activeIndex, 1);
    expect(opened.container.read(homeTabProvider), 1);
    expect(opened.recent.recorded.single.id, 'tab');
  });
}

class _Preferences implements AiCliPreferencesStore {
  @override
  Future<AiCliScanRequest> load(String scope) async => AiCliScanRequest();
  @override
  Future<void> save(String scope, AiCliScanRequest request) async {}
}

class _Seeded extends SessionController {
  _Seeded(VaultController vault, Ref ref, SessionState initial)
      : super(SshService(), vault, ref) {
    state = initial;
  }

  void replace(SessionState next) => state = next;
}

class _Recent implements AiCliRecentWorkStore {
  _Recent(this.items);
  final List<AiCliWorkItem> items;
  final recorded = <AiCliWorkItem>[];
  @override
  Future<List<AiCliWorkItem>> load(String hostScope) async => items;
  @override
  Future<void> record(String hostScope, AiCliWorkItem item) async =>
      recorded.add(item);
  @override
  Future<void> clear(String hostScope) async {}
}
