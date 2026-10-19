@Tags(['ai-cli-ssh-fixture'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/ai_cli.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/ai_cli_discovery.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';

import 'fixtures/docker_fixture.dart';
import 'support/test_terminal.dart';

// Real SSH transport/topology with inert tool files, no AI logins/model calls.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final f = DockerFixture.load();
  final skip = f == null ? DockerFixture.skipReason : false;
  final aiFile = File('tool/ai-cli-fixture/.run/fixture.json');
  const discovery = AiCliDiscoveryService();
  HostProfile edge() => HostProfile({
        'id': 'edge',
        'label': 'edge',
        'hostname': f!.edgeHost,
        'port': f.edgePort,
        'username': f.user,
        'password': f.password,
        'authMethod': 'password',
        'protocol': 'ssh'
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
        ...extra
      });
  Future<bool> verify(HostProfile host, String algorithm, String fp) async =>
      fp ==
      ((host.hostname == f!.edgeHost || host.hostname == 'ssh-edge')
          ? f.edgeFingerprint
          : f.targetFingerprint);
  RoutePlan plan(HostProfile h) => resolveRoutePlan(h, hosts: [
        h.data['proxyConfig'] != null && h.hostChainIds.isNotEmpty
            ? HostProfile({...edge().data, 'hostname': 'ssh-edge', 'port': 22})
            : edge(),
        h
      ], proxyProfiles: const []);
  Future<T> query<T>(HostProfile host, Future<T> Function(SSHClient) work,
          {SshService? service}) =>
      (service ?? SshService()).withVerifiedClient(
          routePlan: plan(host),
          verifyHostKey: verify,
          attempt: ConnectionAttempt(),
          query: work);
  Future<String> run(HostProfile host, String command) => query(
      host, (client) async => utf8.decode(await client.run(command)).trim());
  const seed = r'''
mkdir -p ~/r55/pkg/bin ~/.local/bin ~/r55/extra
printf '#!/bin/sh\nprintf BAD >> "$HOME/r55/executed"\n' > ~/r55/pkg/bin/codex
chmod +x ~/r55/pkg/bin/codex
ln -sf "$HOME/r55/pkg/bin/codex" ~/.local/bin/codex
printf '{"name":"@openai/codex","version":"9.8.7","token":"SECRET-BAIT"}' > ~/r55/pkg/package.json
printf '#!/bin/sh\nprintf BAD >> "$HOME/r55/executed"\n' > ~/r55/extra/claude
chmod +x ~/r55/extra/claude
''';
  Map<String, Object?> proxy() => {
        'type': 'socks5',
        'host': f!.socksAuthHost,
        'port': f.socksAuthPort,
        'username': f.socksUser,
        'password': f.socksPassword
      };
  group('AIC01/AIC02 real OpenSSH Direct/SOCKS/Jump', () {
    setUpAll(() async {
      if (f == null) return;
      await run(edge(), seed);
      await run(target({'proxyConfig': proxy()}), seed);
    });
    tearDownAll(() async {
      if (f == null) return;
      // Only this test's explicit inert fixtures; production discovery writes nothing.
      const cleanup = 'rm -f ~/.local/bin/codex; rm -rf ~/r55';
      await run(edge(), cleanup);
      await run(target({'proxyConfig': proxy()}), cleanup);
    });
    for (final route in ['direct', 'socks', 'jump', 'socks-jump']) {
      test(
          '$route: verified final client, no extra dial/startup/tool execution',
          () async {
        final host = switch (route) {
          'direct' => edge(),
          'socks' => target({'proxyConfig': proxy()}),
          'jump' => target({
              'hostChain': {
                'hostIds': ['edge']
              }
            }),
          _ => target({
              'hostChain': {
                'hostIds': ['edge']
              },
              'proxyConfig': proxy()
            }),
        };
        final withStartup = HostProfile(
            {...host.data, 'startupCommand': 'printf BAD >> ~/r55/startup'});
        final dials = <String>[];
        final trusted = <String>[];
        SSHClient? borrowed;
        final service = SshService(dialer: (host, port, {timeout}) {
          dials.add('$host:$port');
          return Socket.connect(host, port, timeout: timeout);
        });
        final result = await service.withVerifiedClient(
            routePlan: plan(withStartup),
            verifyHostKey: (h, a, fp) async {
              trusted.add(h.hostname);
              return verify(h, a, fp);
            },
            attempt: ConnectionAttempt(),
            query: (client) {
              borrowed = client;
              return discovery.discoverClient(
                  client,
                  AiCliScanRequest(directories: ['~/r55/extra']),
                  AiCliProbeCancellation());
            });
        expect(result.unixUser, 'fixture');
        expect(result.uid, '1000');
        expect(
            result.installations
                .singleWhere((x) => x.kind == AiCliKind.codex)
                .packageVersion,
            '9.8.7');
        expect(
            result.installations.any((x) => x.kind == AiCliKind.claude), true);
        expect(dials, [
          route.startsWith('socks')
              ? '${f!.socksAuthHost}:${f.socksAuthPort}'
              : '${f!.edgeHost}:${f.edgePort}'
        ]);
        expect(
            trusted,
            route.contains('jump')
                ? [
                    route == 'socks-jump' ? 'ssh-edge' : f.edgeHost,
                    f.targetName
                  ]
                : [host.hostname]);
        expect(borrowed!.isClosed, true,
            reason: 'query-only owned transport must close');
        expect(
            await run(host,
                'test ! -e ~/r55/executed && test ! -e ~/r55/startup && printf clean'),
            'clean');
      }, skip: skip);
    }
    test('untrusted fingerprint: no query before trust, and cleanup', () async {
      var queries = 0;
      await expectLater(
          SshService().withVerifiedClient(
              routePlan: plan(edge()),
              verifyHostKey: (_, __, ___) async => false,
              attempt: ConnectionAttempt(),
              query: (client) async {
                queries++;
                return 'bad';
              }),
          throwsA(isA<Exception>()));
      expect(queries, 0);
    }, skip: skip);
    test('SOCKS error never falls back to direct target', () async {
      final dials = <String>[];
      var queries = 0;
      final service = SshService(dialer: (host, port, {timeout}) {
        dials.add('$host:$port');
        return Socket.connect(host, port, timeout: timeout);
      });
      await expectLater(
          query(
              target({
                'proxyConfig': {...proxy(), 'password': 'wrong'}
              }), (client) async {
            queries++;
            return 'bad';
          }, service: service),
          throwsA(isA<Exception>()));
      expect(dials, ['${f!.socksAuthHost}:${f.socksAuthPort}']);
      expect(queries, 0);
    }, skip: skip);
    test('borrowed live terminal receives no detection text and stays usable',
        () async {
      await run(edge(), 'rm -f ~/r55/input');
      final terminal = newTestTerminal();
      addTearDown(terminal.dispose);
      final host = HostProfile({
        ...edge().data,
        'startupCommand': 'stty raw -echo; exec cat > ~/r55/input'
      });
      final session = await SshService().connect(
          sessionId: 'r55-live',
          host: host,
          hosts: [host],
          terminal: terminal,
          verifyHostKey: verify);
      addTearDown(session.abort);
      for (var i = 0; i < 30; i++) {
        if (await run(edge(), 'test -f ~/r55/input && printf ready') ==
            'ready') {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final original = session.sshClient;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final before = await run(edge(), 'wc -c < ~/r55/input');
      final beforeData = await run(edge(), 'cat ~/r55/input');
      final result = await discovery.discover(
          session, AiCliScanRequest(), AiCliProbeCancellation());
      expect(result.installations.any((x) => x.kind == AiCliKind.codex), true);
      expect(session.sshClient, same(original));
      expect(original!.isClosed, false);
      expect(await run(edge(), 'wc -c < ~/r55/input'), before);
      session.terminal.sendText('still-working');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
          await run(edge(), 'cat ~/r55/input'), '${beforeData}still-working');
    }, skip: skip);
  });
  test('actual installed Claude/Codex: discovery only, without CLI invocation',
      () async {
    final data = jsonDecode(aiFile.readAsStringSync()) as Map<String, dynamic>;
    final host = HostProfile({
      'id': 'r55-real-cli',
      'label': 'AI fixture',
      'hostname': '127.0.0.1',
      'port': data['port'],
      'username': data['user'],
      'password': data['password'],
      'authMethod': 'password',
      'protocol': 'ssh'
    });
    final result = await SshService().withVerifiedClient(
        routePlan:
            resolveRoutePlan(host, hosts: [host], proxyProfiles: const []),
        verifyHostKey: (_, __, fp) async => fp == data['fingerprint'],
        attempt: ConnectionAttempt(),
        query: (client) => discovery.discoverClient(
            client, AiCliScanRequest(), AiCliProbeCancellation()));
    expect(result.installations.map((x) => x.kind),
        containsAll([AiCliKind.claude, AiCliKind.codex]));
    for (final kind in [AiCliKind.claude, AiCliKind.codex]) {
      final item = result.installations.firstWhere((x) => x.kind == kind);
      expect(item.packageVersion, isNotNull,
          reason: 'npm metadata should be available in this fixture');
    }
  },
      skip: aiFile.existsSync()
          ? false
          : 'AI fixture not running; detection smoke NOT_RUN');
}
