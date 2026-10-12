import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/ai_cli_return.dart';
import 'package:shun/domain/ai_cli.dart';
import 'package:shun/domain/ai_cli_launch.dart';
import 'package:shun/domain/ai_cli_work.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/ai_cli_preferences.dart';
import 'package:shun/infrastructure/storage/ai_cli_recent_work.dart';
import 'support/test_terminal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const store = SecureAiCliRecentWork();
  final values = <String, String>{};
  final writes = <Map<Object?, Object?>>[];
  Completer<void>? gate;
  setUp(() {
    values.clear();
    writes.clear();
    gate = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      final key = args['key'] as String;
      if (call.method == 'read') return values[key];
      if (call.method == 'write') {
        writes.add(args.cast<Object?, Object?>());
        await gate?.future;
        values[key] = args['value'] as String;
      } else if (call.method == 'delete') {
        values.remove(key);
      }
      return null;
    });
  });
  AiCliWorkItem item(String id, {String project = '/repo', String? nativeId}) =>
      AiCliWorkItem(
          id: id,
          tool: AiCliKind.claude,
          name: 'Claude',
          executable: '/bin/claude',
          projectDirectory: project,
          openedAt: DateTime.utc(2026, 10, 12),
          claudeSessionId: nativeId);
  HostProfile host(
          {String id = 'host',
          String user = 'fixture',
          String address = '127.0.0.1'}) =>
      HostProfile({
        'id': id,
        'hostname': address,
        'port': 22,
        'username': user,
        'protocol': 'ssh'
      });

  test(
      'AIC07 secure storage roundtrip is host/user scoped, bounded, and clearable',
      () async {
    final scope = aiCliHostScope(host());
    for (var i = 0; i < 23; i++) {
      await store.record(scope, item('$i', project: '/worktree/$i'));
    }
    final loaded = await const SecureAiCliRecentWork().load(scope);
    expect(loaded.length, 20);
    expect(loaded.first.id, '22');
    for (final other in [
      host(user: 'other'),
      host(id: 'new-id'),
      host(address: 'other.invalid')
    ]) {
      expect(await store.load(aiCliHostScope(other)), isEmpty);
    }
    final payload = jsonDecode(values.values.single) as Map;
    expect(
        (payload['items'] as List).first.keys,
        unorderedEquals([
          'id',
          'tool',
          'name',
          'executable',
          'projectDirectory',
          'openedAt',
          'claudeSessionId',
          'nativeIdSource',
          'tmuxRun'
        ]));
    expect(writes.last['key'], startsWith('recent.'));
    await store.clear(scope);
    expect(await store.load(scope), isEmpty);
  });

  test(
      'AIC07 clear waits for pending record; concurrent worktrees do not overwrite each other',
      () async {
    gate = Completer<void>();
    final first = store.record('scope', item('a', project: '/a'));
    await Future<void>.delayed(Duration.zero);
    final second =
        const SecureAiCliRecentWork().record('scope', item('b', project: '/b'));
    final clear = store.clear('scope');
    gate!.complete();
    await Future.wait([first, second, clear]);
    expect(await store.load('scope'), isEmpty);
    await Future.wait([
      store.record('scope', item('a', project: '/a')),
      store.record('scope', item('b', project: '/b'))
    ]);
    expect((await store.load('scope')).map((x) => x.id), ['b', 'a']);
  });

  test(
      'AIC07 malformed legacy pointers cannot select a different session; clear repairs envelope',
      () async {
    await store.record('scope', item('original'));
    final key = values.keys.single;
    values[key] = jsonEncode({
      'version': 1,
      'items': [
        {...item('relative').toJson(), 'projectDirectory': '~/repo'},
        {
          ...item('missing-native-source').toJson(),
          'claudeSessionId': '550e8400-e29b-41d4-a716-446655440000'
        },
        item('valid').toJson()
      ]
    });
    expect((await store.load('scope')).map((x) => x.id), ['valid']);
    values[key] = '{broken';
    await expectLater(store.load('scope'), throwsFormatException);
    await store.clear('scope');
    await store.record('scope', item('repaired'));
    expect((await store.load('scope')).single.id, 'repaired');
  });

  test(
      'AIC06 configured CLI home changes scope without storing environment secrets',
      () {
    HostProfile configured(String value) => HostProfile({
          ...host().data,
          'environmentVariables': [
            {'name': 'CODEX_HOME', 'value': value}
          ]
        });
    expect(aiCliHostScope(configured('/identity-a')),
        isNot(aiCliHostScope(configured('/identity-b'))));
    expect(aiCliHostScope(configured('/secret-home')),
        isNot(contains('secret-home')));
    expect(aiCliHostScope(configured('/identity-a')),
        isNot(aiCliHostScope(host())));
  });

  test(
      'AIC07 maximum escaped paths cannot create an unreadable oversized record',
      () async {
    for (var i = 0; i < 20; i++) {
      await store.record(
          'large',
          AiCliWorkItem(
              id: '$i',
              tool: AiCliKind.custom,
              name: 'Tool',
              executable: '/${'"' * 2000}/$i',
              projectDirectory: '/${'"' * 2000}/$i',
              openedAt: DateTime.now()));
    }
    expect(values.values.single.length, lessThanOrEqualTo(100000));
    expect((await store.load('large')).first.id, '19');
  });

  test(
      'AIC05/AIC08 live return checks host, tool, project, run; forged titles change no identity',
      () {
    const id = '550e8400-e29b-41d4-a716-446655440000';
    final work = item('tab', nativeId: id);
    final terminal = newTestTerminal();
    addTearDown(terminal.dispose);
    ActiveTerminalSession session(
            {HostProfile? onHost,
            String executable = '/bin/claude',
            String project = '/repo',
            String nativeId = id}) =>
        ActiveTerminalSession(
            id: 'tab',
            host: onHost ?? host(),
            terminal: terminal,
            verifyHostKey: (_, __, ___) async => false,
            keyboardInteractive: null,
            aiLaunch: AiCliLaunchSpec(
                executable: executable,
                projectDirectory: project,
                arguments: ['--session-id', nativeId]));
    final original = session();
    expect(matchesAiWorkTerminal(original, work, host()), isTrue);
    for (final changed in [
      session(onHost: host(user: 'other')),
      session(executable: '/other/claude'),
      session(project: '/worktree'),
      session(nativeId: '650e8400-e29b-41d4-a716-446655440000')
    ]) {
      expect(matchesAiWorkTerminal(changed, work, host()), isFalse);
    }
    for (final title in [
      'Claude completed approved resume=FAKE',
      'Codex working',
      'partial',
      'x' * 9000
    ]) {
      terminal.feed(Uint8List.fromList(utf8.encode('\x1b]0;$title\x07')));
      expect(work.exactResume()!.arguments, ['--resume', id]);
      expect(matchesAiWorkTerminal(original, work, host()), isTrue);
    }
    original.aiTerminalOriginal = false;
    expect(matchesAiWorkTerminal(original, work, host()), isFalse);
  });
}
