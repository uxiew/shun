@Tags(['ai-cli-ssh-fixture'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/ai_cli_launch.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/tmux/tmux_target.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/tmux/ai_cli_tmux_service.dart';
import 'package:shun/infrastructure/tmux/tmux_protocol.dart';

import 'fixtures/tmux_fixture.dart';
import 'support/test_terminal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final f = TmuxFixture.load();
  final skip = f == null ? TmuxFixture.skipReason : false;
  const ai = AiCliTmuxService();
  final socket = TmuxSocketSpec.named('r56ai');
  const setup = r'''
mkdir -p ~/r56/project
printf '#!/bin/sh\nprintf started > "$HOME/r56/ran"\nexec sleep 60\n' > ~/r56/tool
chmod +x ~/r56/tool
''';
  group('AIC05 dedicated tmux run on four real versions', () {
    setUpAll(() async {
      if (f == null) return;
      for (final node in TmuxFixture.realNodes) {
        await f.run(node, setup);
      }
    });
    tearDownAll(() async {
      if (f == null) return;
      for (final node in TmuxFixture.realNodes) {
        await f.run(node, 'tmux -L r56ai kill-server 2>/dev/null || :');
        await f.run(node, 'rm -rf ~/r56');
      }
    });
    for (var i = 0; i < TmuxFixture.realNodes.length; i++) {
      final node = TmuxFixture.realNodes[i];
      test('$node creates exact pane, starts inert CLI, and attaches',
          () async {
        final host = f!.host(node);
        final plan =
            resolveRoutePlan(host, hosts: [host], proxyProfiles: const []);
        final requestId = '550e8400-e29b-41d4-a716-44665544000$i';
        var attempts = 0;
        final run = await SshService().withVerifiedClientForAiTmux(
          routePlan: plan,
          verifyHostKey: f.verify,
          attempt: ConnectionAttempt(),
          action: (client) => ai.start(
            client,
            hostKey: plan.target.endpoint.authority,
            socket: socket,
            requestId: requestId,
            launch: AiCliLaunchSpec(
              executable: '/home/fixture/r56/tool',
              projectDirectory: '/home/fixture/r56/project',
            ),
            onCreateAttempted: () => attempts++,
          ),
        );
        expect(attempts, 1);
        expect(run.windowId, startsWith('@'));
        expect(run.paneId, startsWith('%'));
        expect(run.panePid, greaterThan(0));
        if (node == TmuxFixture.realNodes.last) {
          await expectLater(
              SshService().withVerifiedClientForAiTmux(
                  routePlan: plan,
                  verifyHostKey: f.verify,
                  attempt: ConnectionAttempt(),
                  action: (client) => ai.start(client,
                      hostKey: plan.target.endpoint.authority,
                      socket: socket,
                      requestId: requestId,
                      launch: AiCliLaunchSpec(
                          executable: '/home/fixture/r56/tool',
                          projectDirectory: '/home/fixture/r56/project'),
                      onCreateAttempted: () {})),
              throwsA(isA<TmuxCommandException>()));
          expect(
              await f.run(node,
                  'tmux -L r56ai list-sessions -F "#{session_name}" | grep -c "^shun-ai-$requestId\$"'),
              '1');
        }
        for (var n = 0; n < 25; n++) {
          if (await f.run(node, 'test -f ~/r56/ran && printf yes') == 'yes') {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(await f.run(node, 'cat ~/r56/ran'), 'started');
        await SshService().withVerifiedClient(
          routePlan: plan,
          verifyHostKey: f.verify,
          attempt: ConnectionAttempt(),
          query: (client) => ai.verify(client, run),
        );
        final terminal = newTestTerminal();
        addTearDown(terminal.dispose);
        final attached = await SshService().connectAiTmux(
          sessionId: 'ai-tmux-$node',
          host: host,
          routePlan: plan,
          verifyHostKey: f.verify,
          terminal: terminal,
          attempt: ConnectionAttempt(),
          run: run,
        );
        expect(attached.aiTmuxRun?.sameAs(run), true);
        attached.abort();
      }, skip: skip);
    }
    test('replaced pane process is rejected before return', () async {
      final node = TmuxFixture.realNodes.last;
      final host = f!.host(node);
      final plan =
          resolveRoutePlan(host, hosts: [host], proxyProfiles: const []);
      final run = await SshService().withVerifiedClientForAiTmux(
        routePlan: plan,
        verifyHostKey: f.verify,
        attempt: ConnectionAttempt(),
        action: (client) => ai.start(
          client,
          hostKey: plan.target.endpoint.authority,
          socket: socket,
          requestId: '650e8400-e29b-41d4-a716-446655440000',
          launch: AiCliLaunchSpec(
              executable: '/home/fixture/r56/tool',
              projectDirectory: '/home/fixture/r56/project'),
          onCreateAttempted: () {},
        ),
      );
      await f.run(
          node, 'tmux -L r56ai respawn-pane -k -t ${run.paneId} "sleep 60"');
      await expectLater(
          SshService().withVerifiedClient(
            routePlan: plan,
            verifyHostKey: f.verify,
            attempt: ConnectionAttempt(),
            query: (client) => ai.verify(client, run),
          ),
          throwsA(isA<TmuxTargetGoneException>()));
      final terminal = newTestTerminal();
      addTearDown(terminal.dispose);
      await expectLater(
          SshService().connectAiTmux(
            sessionId: 'replaced-pane',
            host: host,
            routePlan: plan,
            verifyHostKey: f.verify,
            terminal: terminal,
            attempt: ConnectionAttempt(),
            run: run,
          ),
          throwsA(isA<Exception>()));
    }, skip: skip);
  });
}
