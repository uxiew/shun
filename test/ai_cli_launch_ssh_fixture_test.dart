@Tags(['ai-cli-ssh-fixture'])
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/ai_cli_launch.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/ai_cli_discovery.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';

import 'fixtures/docker_fixture.dart';
import 'support/test_terminal.dart';

// Inert remote executable over real OpenSSH; no AI account or model request.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final f = DockerFixture.load();
  final skip = f == null ? DockerFixture.skipReason : false;
  HostProfile edge() => HostProfile({
        'id': 'edge',
        'label': 'edge',
        'hostname': f!.edgeHost,
        'port': f.edgePort,
        'username': f.user,
        'password': f.password,
        'authMethod': 'password',
        'protocol': 'ssh',
      });
  HostProfile target(Map<String, Object?> extra) => HostProfile({
        'id': 'target',
        'label': 'target',
        'hostname': f!.targetName,
        'port': f.targetPort,
        'username': f.user,
        'password': f.password,
        'authMethod': 'password',
        'protocol': 'ssh',
        ...extra,
      });
  Map<String, Object?> proxy() => {
        'type': 'socks5',
        'host': f!.socksAuthHost,
        'port': f.socksAuthPort,
        'username': f.socksUser,
        'password': f.socksPassword,
      };
  RoutePlan plan(HostProfile host) => resolveRoutePlan(host, hosts: [
        HostProfile({...edge().data, 'hostname': 'ssh-edge', 'port': 22}),
        host,
      ], proxyProfiles: const []);
  Future<bool> verify(HostProfile host, String algorithm, String fp) async =>
      fp ==
      (host.hostname == 'ssh-edge' || host.hostname == f!.edgeHost
          ? f!.edgeFingerprint
          : f.targetFingerprint);
  Future<String> run(HostProfile host, String command) =>
      SshService().withVerifiedClient(
          routePlan: plan(host),
          verifyHostKey: verify,
          attempt: ConnectionAttempt(),
          query: (client) async =>
              utf8.decode(await client.run(command)).trim());

  group('AIC03/AIC04 inert SSH launch', () {
    setUpAll(() async {
      if (f == null) return;
      const setup = r'''
mkdir -p ~/r56/project
printf '#!/bin/sh\nprintf started > "$HOME/r56/ran"\nsleep 3\n' > ~/r56/tool
chmod +x ~/r56/tool
''';
      await run(edge(), setup);
      await run(target({'proxyConfig': proxy()}), setup);
    });
    tearDownAll(() async {
      if (f == null) return;
      await run(edge(), 'rm -rf ~/r56');
      await run(target({'proxyConfig': proxy()}), 'rm -rf ~/r56');
    });

    for (final path in ['direct', 'socks-jump']) {
      test('$path uses exact route, one exec, no host startup command',
          () async {
        final base = path == 'direct'
            ? edge()
            : target({
                'hostChain': {
                  'hostIds': ['edge']
                },
                'proxyConfig': proxy(),
              });
        final host = HostProfile({
          ...base.data,
          'startupCommand': 'printf wrong > ~/r56/startup',
        });
        final terminal = newTestTerminal();
        addTearDown(terminal.dispose);
        final project = await SshService().withVerifiedClient(
          routePlan: plan(host),
          verifyHostKey: verify,
          attempt: ConnectionAttempt(),
          query: (client) => const AiCliDiscoveryService().canonicalProject(
            client,
            AiCliLaunchSpec(
                executable: '/home/fixture/r56/tool',
                projectDirectory: '~/r56/project'),
            AiCliProbeCancellation(),
          ),
        );
        expect(project, '/home/fixture/r56/project');
        var attempted = 0;
        final session = await SshService().connectAiCli(
          sessionId: 'r56-$path',
          host: host,
          routePlan: plan(host),
          verifyHostKey: verify,
          terminal: terminal,
          attempt: ConnectionAttempt(),
          launch: AiCliLaunchSpec(
              executable: '/home/fixture/r56/tool', projectDirectory: project),
          onExecAttempted: () => attempted++,
        );
        addTearDown(session.abort);
        expect(attempted, 1);
        expect(session.aiLaunch, isNotNull);
        for (var i = 0; i < 30; i++) {
          if (await run(base, 'test -f ~/r56/ran && printf yes') == 'yes') {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(await run(base, 'cat ~/r56/ran'), 'started');
        expect(await run(base, 'test ! -e ~/r56/startup && printf clean'),
            'clean');
      }, skip: skip);
    }

    test('missing project exits 125 without changing to home', () async {
      final host = edge();
      final terminal = newTestTerminal();
      addTearDown(terminal.dispose);
      final session = await SshService().connectAiCli(
        sessionId: 'r56-missing',
        host: host,
        routePlan: plan(host),
        verifyHostKey: verify,
        terminal: terminal,
        attempt: ConnectionAttempt(),
        launch: AiCliLaunchSpec(
            executable: '/home/fixture/r56/tool',
            projectDirectory: '~/r56/missing'),
      );
      addTearDown(session.abort);
      await session.sshSession!.done;
      expect(session.sshSession!.exitCode, 125);
    }, skip: skip);

    test('new AI PTY writes nothing to an existing interactive terminal',
        () async {
      await run(edge(), 'rm -f ~/r56/oldinput ~/r56/ran');
      final oldHost = HostProfile({
        ...edge().data,
        'startupCommand': 'stty raw -echo; exec cat > ~/r56/oldinput',
      });
      final oldTerminal = newTestTerminal();
      addTearDown(oldTerminal.dispose);
      final old = await SshService().connect(
          sessionId: 'old-interactive',
          host: oldHost,
          routePlan: plan(oldHost),
          terminal: oldTerminal,
          verifyHostKey: verify);
      addTearDown(old.abort);
      for (var n = 0; n < 30; n++) {
        if (await run(edge(), 'test -f ~/r56/oldinput && printf yes') ==
            'yes') {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final before = await run(edge(), 'wc -c < ~/r56/oldinput');
      final nextTerminal = newTestTerminal();
      addTearDown(nextTerminal.dispose);
      final launched = await SshService().connectAiCli(
        sessionId: 'new-ai',
        host: edge(),
        routePlan: plan(edge()),
        verifyHostKey: verify,
        terminal: nextTerminal,
        attempt: ConnectionAttempt(),
        launch: AiCliLaunchSpec(
            executable: '/home/fixture/r56/tool',
            projectDirectory: '/home/fixture/r56/project'),
      );
      addTearDown(launched.abort);
      for (var n = 0; n < 30; n++) {
        if (await run(edge(), 'test -f ~/r56/ran && printf yes') == 'yes') {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(await run(edge(), 'cat ~/r56/ran'), 'started');
      expect(await run(edge(), 'wc -c < ~/r56/oldinput'), before);
      old.terminal.sendText('manual');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await run(edge(), 'wc -c < ~/r56/oldinput'),
          '${int.parse(before) + 6}');
    }, skip: skip);
  });
}
