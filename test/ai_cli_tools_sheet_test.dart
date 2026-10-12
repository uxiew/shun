import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/ai_cli.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/ai_cli_discovery.dart';
import 'package:shun/infrastructure/storage/ai_cli_preferences.dart';
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
}
