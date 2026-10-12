@Tags(['ai-cli-ssh-fixture'])
library;

import 'dart:async';
import 'dart:convert';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/ai_cli_launch.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/tmux/tmux_target.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/tmux/ai_cli_tmux_service.dart';
import 'package:shun/infrastructure/tmux/tmux_protocol.dart';
import 'package:shun/infrastructure/tmux/tmux_service.dart';
import 'fixtures/tmux_fixture.dart';
import 'support/test_terminal.dart';

// Real mutations are performed once. Only the fault boundary is injected;
// independent SSH queries count the remote sessions and inert tool executions.
class FaultTmux extends TmuxService {
  FaultTmux(this.boundary, this.fail);
  final String boundary;
  final Future<void> Function(SSHClient) fail;
  @override
  Future<TmuxProbe> probe(SSHClient client, TmuxSocketSpec socket) async {
    final result = await super.probe(client, socket);
    if (boundary == 'before-create') await fail(client);
    return result;
  }

  @override
  Future<TmuxTarget> create(SSHClient client,
      {required String hostKey,
      required String unixUser,
      required int uid,
      required TmuxSocketSpec socket,
      required String name,
      String startupCommand = ''}) async {
    final target = await super.create(client,
        hostKey: hostKey,
        unixUser: unixUser,
        uid: uid,
        socket: socket,
        name: name);
    if (boundary == 'after-create') await fail(client);
    return target;
  }

  @override
  Future<({String output, int? exitCode, bool truncated})> runBounded(
      SSHClient client, String command,
      {String? stdin, required Duration timeout, required int maxBytes}) async {
    if (stdin != null && boundary == 'before-start') await fail(client);
    final result = await super.runBounded(client, command,
        stdin: stdin, timeout: timeout, maxBytes: maxBytes);
    if (stdin != null && boundary == 'after-start') await fail(client);
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = TmuxFixture.load();
  final skip = fixture == null ? TmuxFixture.skipReason : false;
  final socket = TmuxSocketSpec.named('r56matrix');
  const setup = r'''
mkdir -p ~/r56matrix/project
printf '#!/bin/sh\nprintf "run\\n" >> "$HOME/r56matrix/count"\nexec sleep 300\n' > ~/r56matrix/tool
chmod +x ~/r56matrix/tool
''';
  var sequence = 0;
  String request() =>
      '750e8400-e29b-41d4-a716-${(++sequence).toString().padLeft(12, '0')}';
  AiCliLaunchSpec launch() => AiCliLaunchSpec(
      executable: '/home/fixture/r56matrix/tool',
      projectDirectory: '/home/fixture/r56matrix/project');

  setUpAll(() async {
    if (fixture == null) return;
    for (final node in TmuxFixture.realNodes) {
      await fixture.run(node, setup);
    }
  });
  tearDownAll(() async {
    if (fixture == null) return;
    for (final node in TmuxFixture.realNodes) {
      await fixture.run(node,
          'tmux -L r56matrix kill-server 2>/dev/null || :; rm -rf ~/r56matrix');
    }
  });

  for (final boundary in [
    'before-create',
    'after-create',
    'before-start',
    'after-start'
  ]) {
    for (final fault in ['disconnect', 'cancel', 'timeout']) {
      test('AIC04 $fault $boundary preserves remote counts and never replays',
          () async {
        final f = fixture!;
        const node = 'tmux35';
        await f.run(node,
            'tmux -L r56matrix kill-server 2>/dev/null || :; rm -f ~/r56matrix/count');
        final host = f.host(node);
        final plan =
            resolveRoutePlan(host, hosts: [host], proxyProfiles: const []);
        final attempt = ConnectionAttempt(generation: sequence + 1);
        var dispatched = false;
        var faults = 0;
        final service = AiCliTmuxService(
            tmux: FaultTmux(boundary, (client) async {
          faults++;
          if (fault == 'timeout') {
            await const TmuxService().runBounded(client, 'sleep 2',
                timeout: const Duration(milliseconds: 100), maxBytes: 100);
          } else if (fault == 'cancel') {
            attempt.cancel();
          } else {
            client.close();
          }
          throw StateError('injected $fault');
        }));
        final id = request();
        await expectLater(
            SshService().withVerifiedClientForAiTmux(
              routePlan: plan,
              verifyHostKey: f.verify,
              attempt: attempt,
              action: (client) => service.start(client,
                  hostKey: plan.target.endpoint.authority,
                  socket: socket,
                  requestId: id,
                  launch: launch(),
                  onCreateAttempted: () => dispatched = true),
            ),
            throwsA(isA<Object>()));
        expect(faults, 1);
        expect(dispatched, boundary != 'before-create');
        if (boundary == 'after-start') {
          for (var n = 0; n < 30; n++) {
            if (await f.run(node, 'test -f ~/r56matrix/count && printf yes') ==
                'yes') {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
        Future<String> counts() => f.run(
            node,
            'tmux -L r56matrix list-sessions -F "#{session_name}" 2>/dev/null | grep -c "^shun-ai-$id\$"; '
            'if test -f ~/r56matrix/count; then wc -l < ~/r56matrix/count; else printf "0\\n"; fi');
        final expected =
            '${boundary == 'before-create' ? 0 : 1}\n${boundary == 'after-start' ? 1 : 0}';
        expect(await counts(), expected);
        // A subsequent verified, read-only connection must not finish or retry
        // an uncertain start. Created-but-not-started sessions remain intact.
        await SshService().withVerifiedClient(
            routePlan: plan,
            verifyHostKey: f.verify,
            attempt: ConnectionAttempt(),
            query: (client) => const TmuxService().probe(client, socket));
        expect(await counts(), expected);
      }, skip: skip);
    }
  }

  for (final node in TmuxFixture.realNodes) {
    test('AIC05 $node rejects a pane added during the attach handshake',
        () async {
      final f = fixture!;
      await f.run(node, 'tmux -L r56matrix kill-server 2>/dev/null || :');
      final host = f.host(node);
      final plan =
          resolveRoutePlan(host, hosts: [host], proxyProfiles: const []);
      final run = await SshService().withVerifiedClientForAiTmux(
          routePlan: plan,
          verifyHostKey: f.verify,
          attempt: ConnectionAttempt(),
          action: (client) => const AiCliTmuxService().start(client,
              hostKey: plan.target.endpoint.authority,
              socket: socket,
              requestId: request(),
              launch: launch(),
              onCreateAttempted: () {}));
      final client = await f.client(node);
      addTearDown(client.close);
      final channel = await client.execute(tmuxAiAttachCommand(run),
          pty: const SSHPtyConfig());
      final ready = Completer<void>();
      final output = StringBuffer();
      final subscription = channel.stdout.listen((bytes) {
        output.write(utf8.decode(bytes, allowMalformed: true));
        if (output.toString().contains(tmuxAttachMarker) &&
            !ready.isCompleted) {
          ready.complete();
        }
      });
      addTearDown(subscription.cancel);
      await ready.future.timeout(const Duration(seconds: 5));
      await f.run(node,
          'tmux -L r56matrix split-window -d -t ${run.paneId} "sleep 300"');
      channel.stdin.add(utf8.encode('\n'));
      await channel.done.timeout(const Duration(seconds: 5));
      expect(channel.exitCode, 97);
      expect(
          await f.run(
              node, 'tmux -L r56matrix list-clients -F "#{client_pid}"'),
          isEmpty);
    }, skip: skip);
    for (final change in [
      'dead',
      'split',
      'window',
      'same-name',
      'server',
      'socket',
      'user'
    ]) {
      test('AIC05 $node rejects $change at verify AND guarded attach',
          () async {
        final f = fixture!;
        await f.run(node, 'tmux -L r56matrix kill-server 2>/dev/null || :');
        final host = f.host(node);
        final plan =
            resolveRoutePlan(host, hosts: [host], proxyProfiles: const []);
        final id = request();
        final run = await SshService().withVerifiedClientForAiTmux(
            routePlan: plan,
            verifyHostKey: f.verify,
            attempt: ConnectionAttempt(),
            action: (client) => const AiCliTmuxService().start(client,
                hostKey: plan.target.endpoint.authority,
                socket: socket,
                requestId: id,
                launch: launch(),
                onCreateAttempted: () {}));
        final name = run.target.displayName;
        final command = switch (change) {
          'dead' =>
            'tmux -L r56matrix set-option -w -t ${run.windowId} remain-on-exit on; kill ${run.panePid}',
          'split' =>
            'tmux -L r56matrix split-window -d -t ${run.paneId} "sleep 300"',
          'window' =>
            'tmux -L r56matrix new-window -d -t \'${run.target.sessionId}\' "sleep 300"',
          'same-name' =>
            'tmux -L r56matrix new-session -d -s keeper; tmux -L r56matrix kill-session -t \'${run.target.sessionId}\'; tmux -L r56matrix new-session -d -s $name',
          'server' =>
            'tmux -L r56matrix kill-server; sleep 0.1; tmux -L r56matrix new-session -d -s $name',
          'socket' =>
            'mv /tmp/tmux-1000/r56matrix /tmp/tmux-1000/r56matrix-moved',
          _ => 'true',
        };
        await f.run(node, command);
        if (change == 'dead') {
          for (var n = 0; n < 30; n++) {
            if (await f.run(node,
                    'tmux -L r56matrix display-message -p -t ${run.paneId} "#{pane_dead}"') ==
                '1') {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          expect(
              await f.run(node,
                  'tmux -L r56matrix display-message -p -t ${run.paneId} "#{pane_dead}"'),
              '1');
        }
        final checkingHost =
            change == 'user' ? f.host(node, user: 'other') : host;
        final checkingPlan = resolveRoutePlan(checkingHost,
            hosts: [checkingHost], proxyProfiles: const []);
        await expectLater(
            SshService().withVerifiedClient(
                routePlan: checkingPlan,
                verifyHostKey: f.verify,
                attempt: ConnectionAttempt(),
                query: (client) =>
                    const AiCliTmuxService().verify(client, run)),
            throwsA(isA<TmuxCommandException>()));
        final terminal = newTestTerminal();
        addTearDown(terminal.dispose);
        // Bypass the preceding UI verification to simulate mutation in the
        // time-of-check/time-of-use gap; the actual attach still must reject.
        await expectLater(
            SshService().connectAiTmux(
                sessionId: id,
                host: checkingHost,
                routePlan: checkingPlan,
                verifyHostKey: f.verify,
                terminal: terminal,
                attempt: ConnectionAttempt(),
                run: run),
            throwsA(isA<Exception>()));
        if (change == 'socket') {
          await f.run(node,
              'tmux -S /tmp/tmux-1000/r56matrix-moved kill-server 2>/dev/null || :');
        }
      }, skip: skip);
    }
  }
}
