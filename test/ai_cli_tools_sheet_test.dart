import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/ai_cli.dart';
import 'package:shun/domain/ai_cli_work.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/ai_cli_discovery.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/ai_cli_preferences.dart';
import 'package:shun/infrastructure/storage/ai_cli_recent_work.dart';
import 'package:shun/presentation/widgets/ai_cli_tools_sheet.dart';
import 'package:shun/presentation/widgets/terminal_special_keys.dart';

import 'support/test_terminal.dart';

class Preferences implements AiCliPreferencesStore {
  final data = <String, AiCliScanRequest>{};
  @override
  Future<AiCliScanRequest> load(String scope) async =>
      data[scope] ?? AiCliScanRequest();
  @override
  Future<void> save(String scope, AiCliScanRequest request) async {
    data[scope] = request;
  }
}

class Recent implements AiCliRecentWorkStore {
  List<AiCliWorkItem> items = [];
  @override
  Future<List<AiCliWorkItem>> load(String hostScope) async => items;
  @override
  Future<void> record(String hostScope, AiCliWorkItem item) async {
    items = [item, ...items];
  }

  @override
  Future<void> clear(String hostScope) async => items = [];
}

class BrokenRecent extends Recent {
  bool broken = true;
  @override
  Future<List<AiCliWorkItem>> load(String hostScope) async {
    if (broken) throw const FormatException('corrupt envelope');
    return super.load(hostScope);
  }

  @override
  Future<void> clear(String hostScope) async {
    broken = false;
    await super.clear(hostScope);
  }
}

final host = HostProfile({
  'id': 'h',
  'label': 'Test host',
  'hostname': 'example.invalid',
  'port': 22,
  'username': 'user',
  'protocol': 'ssh'
});
AiCliScanResult result() => AiCliScanResult(
        unixUser: 'user',
        uid: '1000',
        scannedAt: DateTime(2026, 10, 12),
        installations: const [
          AiCliInstallation(
              kind: AiCliKind.claude,
              name: 'Claude Code',
              path: '/bin/claude',
              source: 'PATH')
        ]);
void main() {
  testWidgets('narrow quick bar preserves keyboard controls and 48dp AI action',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final terminal = newTestTerminal();
    addTearDown(terminal.dispose);
    var opened = 0;
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
            home: Scaffold(
                body: TerminalSpecialKeys(
                    order: const ['ESC'],
                    customKeys: const [],
                    onSend: (text, {bool enter = false}) {},
                    onKey: (_) {},
                    inputController: terminal.input,
                    onAi: null,
                    onAiCli: () {
                      opened++;
                    },
                    onPortForward: () {},
                    onSystemManagement: () {},
                    pictureInPicture: false,
                    onPictureInPicture: () {},
                    fullscreen: false,
                    onFullscreen: () {},
                    split: false,
                    onSplit: () {},
                    onInputPanel: () {})))));
    await tester.pumpAndSettle();
    final ai = find.byKey(const ValueKey('terminal-action-ai-cli'));
    expect(tester.getSize(ai).width, greaterThanOrEqualTo(48));
    expect(find.byKey(const ValueKey('terminal-action-input-panel')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('terminal-action-hide-keyboard')),
        findsOneWidget);
    await tester.tap(ai);
    expect(opened, 1);
    await tester.tap(find.byKey(const ValueKey('terminal-action-more')));
    await tester.pumpAndSettle();
    expect(find.text('AI 命令行工具'), findsOneWidget);
    expect(find.byKey(const ValueKey('terminal-action-fullscreen')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'tools, missing scope, refresh and settings persist for only this identity',
      (tester) async {
    var scans = 0;
    final store = Preferences();
    AiCliScanRequest? request;
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
            home: Scaffold(
                body: AiCliToolsSheet(
                    host: host,
                    preferences: store,
                    recentWork: Recent(),
                    scan: (r, c) async {
                      scans++;
                      request = r;
                      return result();
                    })))));
    await tester.pumpAndSettle();
    expect(scans, 1);
    expect(find.text('/bin/claude'), findsOneWidget);
    expect(find.text('版本未核验'), findsOneWidget);
    expect(find.text('此范围未发现 · 可补充目录或工具路径'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('ai-cli-settings')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('ai-cli-directories')), '~/.local/bin');
    await tester.enterText(
        find.byKey(const ValueKey('ai-cli-custom')), 'Aider | ~/bin/aider');
    await tester.tap(find.byKey(const ValueKey('ai-cli-save-settings')));
    await tester.pumpAndSettle();
    expect(scans, 2);
    expect(request!.directories, ['~/.local/bin']);
    expect(request!.customTools.single.name, 'Aider');
    expect(store.data.keys, [aiCliHostScope(host)]);
    final other = HostProfile({...host.data, 'username': 'other'});
    expect(aiCliHostScope(other), isNot(aiCliHostScope(host)));
  });
  testWidgets('cancel and dispose invalidate late results', (tester) async {
    final pending = Completer<AiCliScanResult>();
    AiCliProbeCancellation? token;
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
            home: Scaffold(
                body: AiCliToolsSheet(
                    host: host,
                    preferences: Preferences(),
                    recentWork: Recent(),
                    scan: (r, c) {
                      token = c;
                      return pending.future;
                    })))));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai-cli-cancel')));
    await tester.pump();
    expect(token!.cancelled, true);
    pending.complete(result());
    await tester.pumpAndSettle();
    expect(find.text('/bin/claude'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
  testWidgets('recent Claude ID is visible and can be cleared', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final recent = Recent()
      ..items = [
        AiCliWorkItem(
          id: 'old-tab',
          tool: AiCliKind.claude,
          name: 'Claude Code',
          executable: '/bin/claude',
          projectDirectory: '/repo',
          openedAt: DateTime.utc(2026, 10, 12),
          claudeSessionId: '550e8400-e29b-41d4-a716-446655440000',
        ),
      ];
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
            home: Scaffold(
                body: AiCliToolsSheet(
                    host: host,
                    preferences: Preferences(),
                    recentWork: recent,
                    sessionState: const SessionState(),
                    scan: (_, __) async => result())))));
    await tester.pumpAndSettle();
    expect(find.text('Claude Code · /repo'), findsOneWidget);
    expect(find.text('按会话 ID 继续'), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-cli-new-from-recent-old-tab')),
        findsOneWidget);
    await tester.tap(find.text('清除最近工作'));
    await tester.pumpAndSettle();
    expect(recent.items, isEmpty);
    expect(find.text('Claude Code · /repo'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'corrupt recent records can be cleared even after discovery refresh',
      (tester) async {
    final recent = BrokenRecent();
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
            home: Scaffold(
                body: AiCliToolsSheet(
                    host: host,
                    preferences: Preferences(),
                    recentWork: recent,
                    scan: (_, __) async => result())))));
    await tester.pumpAndSettle();
    expect(find.text('无法读取最近工作记录'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ai-cli-refresh')));
    await tester.pumpAndSettle();
    expect(find.text('清除最近工作'), findsOneWidget);
    await tester.tap(find.text('清除最近工作'));
    await tester.pumpAndSettle();
    expect(find.text('无法读取最近工作记录'), findsNothing);
    expect(recent.broken, isFalse);
  });

  testWidgets('launch dialog shows tool and project before any SSH action',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final terminal = newTestTerminal();
    addTearDown(terminal.dispose);
    final session = ActiveTerminalSession(
      id: 'parent',
      host: host,
      terminal: terminal,
      verifyHostKey: (_, __, ___) async => false,
      keyboardInteractive: null,
      routePlan: resolveRoutePlan(host, hosts: [host], proxyProfiles: const []),
    );
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
            home: Scaffold(
                body: AiCliToolsSheet(
                    host: host,
                    session: session,
                    preferences: Preferences(),
                    recentWork: Recent(),
                    scan: (_, __) async => result())))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-cli-launch-/bin/claude')));
    await tester.pumpAndSettle();
    expect(find.text('Claude Code · /bin/claude'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('ai-cli-project-directory')), findsOneWidget);
    await tester.tap(find.text('保留在专属 tmux 会话'));
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isTrue);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
