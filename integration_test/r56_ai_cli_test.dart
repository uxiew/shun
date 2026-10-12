// Account-free Android matrix. Uses an inert executable in the isolated tmux
// fixture, real UI/SSH/Ghostty/secure storage, and two separate App processes.
// Run twice through tool/r56-ai-cli.sh; the second pass checks cold restoration.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/app.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/ai_cli_identity.dart';
import 'package:shun/domain/ai_cli.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/connection_platform_service.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/ai_cli_preferences.dart';
import 'package:shun/infrastructure/storage/ai_cli_recent_work.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/widgets/ai_cli_tools_sheet.dart';

const config = String.fromEnvironment('R56_CONFIG');
const toolPath = '/home/fixture/r56device/tool';
const project = '/home/fixture/r56device/项目 with space';
const recent = SecureAiCliRecentWork();

Future<void> waitFor(
    WidgetTester tester, bool Function() ready, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 35));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out: $what');
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> frames(WidgetTester tester, [int count = 8]) async {
  for (var n = 0; n < count; n++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;
  testWidgets(
      'AIC03–AIC08 account-free launch, return, lifecycle and cold start',
      (tester) async {
    final cfg = jsonDecode(config) as Map<String, dynamic>;
    final node = (cfg['nodes'] as Map)['tmux35'] as Map;
    final host = HostProfile({
      'id': 'r56-device',
      'label': 'R56 fixture',
      'hostname': '127.0.0.1',
      'port': node['port'],
      'username': 'fixture',
      'password': cfg['password'],
      'authMethod': 'password',
      'protocol': 'ssh',
      'startupCommand': 'printf BAD > ~/r56device/startup'
    });
    final scope = aiCliHostScope(host);
    Future<bool> verify(HostProfile _, String __, String fp) async =>
        fp == node['fingerprintSha256'];
    Future<String> remote(String command) => SshService().withVerifiedClient(
        routePlan:
            resolveRoutePlan(host, hosts: [host], proxyProfiles: const []),
        verifyHostKey: verify,
        attempt: ConnectionAttempt(),
        query: (client) async => utf8.decode(await client.run(command)).trim());

    final prefs = await SharedPreferences.getInstance();
    final cold = prefs.getBool('r56.seeded') ?? false;
    final repository = await VaultRepository.open();
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      sessionControllerProvider.overrideWith((ref) => SessionController(
          ref.watch(sshServiceProvider),
          ref.watch(vaultControllerProvider.notifier),
          ref,
          platform: ref.watch(connectionPlatformProvider),
          leaseAfter: const Duration(seconds: 2))),
    ]);
    addTearDown(container.dispose);
    final vault = container.read(vaultControllerProvider.notifier);
    final data = await vault.ready();
    if (!cold) {
      await vault.replace(data.copyWith(hosts: [
        host
      ], extras: {
        ...data.extras,
        'knownHosts': [
          {
            'hostname': host.hostname,
            'port': host.port,
            'keyType': 'ssh-ed25519',
            'fingerprint': node['fingerprintSha256'],
            'acceptedAt': DateTime.now().millisecondsSinceEpoch
          }
        ]
      }));
      await recent.clear(scope);
      await const SecureAiCliPreferences().save(
          scope,
          AiCliScanRequest(customTools: [
            AiCliCustomTool(name: 'Fixture AI', path: toolPath)
          ]));
      await remote(r'''
tmux kill-server 2>/dev/null || :
mkdir -p "$HOME/r56device/项目 with space"
rm -f ~/r56device/count ~/r56device/input ~/r56device/startup
cat > ~/r56device/tool <<'SCRIPT'
#!/bin/sh
printf 'run\n' >> "$HOME/r56device/count"
printf '\033]0;AI completed approved resume=FAKE\007READY\n'
while IFS= read -r line; do printf '%s\n' "$line" >> "$HOME/r56device/input"; done
SCRIPT
chmod +x ~/r56device/tool
''');
    }
    final controller = container.read(sessionControllerProvider.notifier);
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container, child: const ShunApp()));
    await frames(tester, 20);
    container.read(homeTabProvider.notifier).state = 0;
    await frames(tester);
    debugPrint('R56 PHASE=${cold ? 'cold' : 'seed'} pid=$pid');

    Future<void> toolsSheet({bool fromHome = false}) async {
      container.read(homeTabProvider.notifier).state = 0;
      await frames(tester);
      if (fromHome) {
        await waitFor(
            tester,
            () => find
                .byKey(const ValueKey('vault-recent-ai-work'))
                .evaluate()
                .isNotEmpty,
            'recent homepage card');
        await tester.tap(find.byKey(const ValueKey('vault-recent-ai-work')));
      } else {
        await tester.tap(find.text(host.label).first);
        await frames(tester);
        await tester.tap(find.byKey(const ValueKey('host-ai-cli')));
      }
      await waitFor(tester, () {
        final scroll = find.descendant(
            of: find.byType(AiCliToolsSheet),
            matching: find.byType(Scrollable));
        if (scroll.evaluate().isNotEmpty) {
          final state = tester.state<ScrollableState>(scroll.first);
          state.position.jumpTo(state.position.maxScrollExtent);
        }
        return find
            .byKey(const ValueKey('ai-cli-launch-$toolPath'))
            .evaluate()
            .isNotEmpty;
      }, 'discovery');
      await frames(tester);
    }

    Future<void> newDialog() async {
      final button = find.byKey(const ValueKey('ai-cli-launch-$toolPath'));
      await tester.ensureVisible(button);
      await frames(tester);
      await tester.tap(button);
      await frames(tester);
    }

    Future<void> launch({bool tmux = false, String directory = project}) async {
      await newDialog();
      await tester.enterText(
          find.byKey(const ValueKey('ai-cli-project-directory')), directory);
      if (tmux) await tester.tap(find.byType(CheckboxListTile));
      await tester.tap(find.byKey(const ValueKey('ai-cli-confirm-launch')));
      await frames(tester);
    }

    Future<void> returnRecent() async {
      final item = (await recent.load(scope)).first;
      final button = find.byKey(ValueKey('ai-cli-recent-${item.id}'));
      await tester.scrollUntilVisible(button, -250,
          scrollable: find
              .descendant(
                  of: find.byType(AiCliToolsSheet),
                  matching: find.byType(Scrollable))
              .first);
      await frames(tester);
      await tester.tap(button);
      await frames(tester);
    }

    if (!cold) {
      await toolsSheet();
      await launch(directory: '/home/fixture/r56device/missing');
      await waitFor(
          tester,
          () => find.text('项目目录不存在或无法进入').evaluate().isNotEmpty,
          'missing project rejection');
      expect(controller.state.sessions, isEmpty);
      expect(await recent.load(scope), isEmpty);
      expect(await remote('test -f ~/r56device/count && cat ~/r56device/count'),
          isEmpty);
      await launch();
      await waitFor(tester, () => controller.state.sessions.isNotEmpty,
          'new ordinary AI terminal');
      final plain = controller.state.sessions.single;
      await waitFor(tester, () => plain.terminal.allText().contains('READY'),
          'inert CLI ready');
      expect(await remote('wc -l < ~/r56device/count'), '1');
      expect(
          await remote('test -e ~/r56device/startup && printf BAD'), isEmpty);
      await toolsSheet(fromHome: true);
      await returnRecent();
      expect(controller.state.sessions.single, same(plain));
      expect(await remote('wc -l < ~/r56device/count'), '1');
      await controller.close(0);
      await toolsSheet(fromHome: true);
      await launch(tmux: true);
      await waitFor(
          tester,
          () => controller.state.sessions.any((s) => s.aiTmuxRun != null),
          'tmux AI terminal');
      final attached = controller.state.sessions.single;
      await waitFor(tester, () => attached.terminal.allText().contains('READY'),
          'tmux CLI ready');
      expect(await remote('wc -l < ~/r56device/count'), '2');
      final run = attached.aiTmuxRun!;
      attached.sshClient!.close();
      await waitFor(tester, () => !attached.connected, 'transport closed');
      await frames(tester, 40);
      expect(controller.state.recovering, isEmpty);
      expect(attached.restoreHold, isNotNull);
      await toolsSheet(fromHome: true);
      await returnRecent();
      await waitFor(
          tester,
          () => controller.state.sessions
              .any((s) => s.connected && s.aiTmuxRun?.sameAs(run) == true),
          'exact tmux return');
      expect(await remote('wc -l < ~/r56device/count'), '2');
      final live = controller.state.sessions.last;
      final actionDir =
          Directory('${(await getApplicationSupportDirectory()).path}/r56')
            ..createSync(recursive: true);
      final ack = File('${actionDir.path}/background-lock');
      if (await ack.exists()) await ack.delete();
      debugPrint('R56 ACTION=background-lock');
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (!await ack.exists()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('background/lock host action timed out');
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      await frames(tester, 20);
      expect(live.routePlan!.secretsForgotten, isTrue,
          reason: 'test lease shortened to two seconds');
      expect(await remote('wc -l < ~/r56device/count'), '2');
      expect(controller.state.recovering, isEmpty);
      expect(await remote('test -f ~/r56device/input && cat ~/r56device/input'),
          isEmpty);
      expect((prefs.getString('shun.r22.restorableTabs') ?? ''),
          isNot(contains('ai-tmux')));
      final exported = jsonEncode((await vault.ready()).toJson());
      expect(exported, isNot(contains('claudeSessionId')));
      expect(exported, isNot(contains(run.requestId)));
      final support = await getApplicationSupportDirectory();
      final encrypted =
          File('${support.parent.path}/shared_prefs/shun_ai_cli.xml');
      expect(await encrypted.exists(), isTrue);
      final ciphertext = await encrypted.readAsString();
      for (final value in [
        toolPath,
        project,
        run.requestId,
        'Fixture AI',
        'resume=FAKE'
      ]) {
        expect(ciphertext, isNot(contains(value)),
            reason: 'private XML must contain encrypted values');
      }
      debugPrint(
          'R56 STORAGE=encrypted-preferences,no-plaintext-pointers,no-export');
      await prefs.setBool('r56.seeded', true);
      await prefs.setInt('r56.seedPid', pid);
      debugPrint(
          'R56 PASS=launch-failure,ordinary-return,tmux-disconnect-return,forged-title,background-lock,lease,no-replay');
    } else {
      expect(prefs.getInt('r56.seedPid'), isNot(pid));
      expect(controller.state.sessions, isEmpty);
      expect(controller.state.pendingConnections, isEmpty);
      final item = (await recent.load(scope)).single;
      expect(item.tmuxRun, isNotNull);
      expect(await remote('wc -l < ~/r56device/count'), '2');
      expect(find.text('会话状态待核对'), findsOneWidget);
      await toolsSheet(fromHome: true);
      await returnRecent();
      await waitFor(
          tester,
          () => controller.state.sessions.any((s) => s.connected),
          'explicit cold return');
      expect(controller.state.sessions.single.aiTmuxRun!.sameAs(item.tmuxRun!),
          isTrue);
      expect(await remote('wc -l < ~/r56device/count'), '2');
      await controller.close(0);
      container.read(homeTabProvider.notifier).state = 0;
      await vault.upsertHost(HostProfile({...host.data, 'username': 'other'}));
      await frames(tester, 20);
      expect(find.byKey(const ValueKey('vault-recent-ai-work')), findsNothing);
      await vault.upsertHost(host);
      await frames(tester, 20);
      await toolsSheet(fromHome: true);
      await tester.scrollUntilVisible(find.text('清除最近工作'), -250,
          scrollable: find
              .descendant(
                  of: find.byType(AiCliToolsSheet),
                  matching: find.byType(Scrollable))
              .first);
      await frames(tester);
      await tester.tap(find.text('清除最近工作'));
      await frames(tester, 10);
      expect(await recent.load(scope), isEmpty);
      expect(
          await remote(
              'tmux display-message -p -t \'${item.tmuxRun!.target.sessionId}\' "#{pane_dead}"'),
          '0');
      await tester.tap(find.byTooltip('关闭'));
      await frames(tester, 10);
      await vault.deleteHost(host.id);
      await frames(tester, 10);
      expect(find.byKey(const ValueKey('vault-recent-ai-work')), findsNothing);
      debugPrint(
          'R56 PASS=cold-no-connect,exact-return-no-new-process,identity-isolation,clear-without-kill,delete-host');
      await prefs.remove('r56.seeded');
      await prefs.remove('r56.seedPid');
    }
    expect(tester.takeException(), isNull);
    if (!cold) {
      // Keep the real SSH/tmux attachment alive. The host must kill the App
      // process here, before normal test/controller teardown can run.
      debugPrint('R56 KILL_READY=seed');
      await Completer<void>().future;
    } else {
      debugPrint('R56 DONE=cold');
    }
  }, skip: config.isEmpty, timeout: const Timeout(Duration(minutes: 4)));
}
