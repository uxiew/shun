import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/credential_identity.dart';
import 'package:shun/domain/host_identity.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:shun/infrastructure/terminal/terminal_input_controller.dart';
import 'package:shun/presentation/widgets/terminal_special_keys.dart';

// R66 sudo 键。真 SSH、系统验证框在设备上测（integration_test/r66_sudo_key_test.dart）。

HostProfile _host(String id, {String? password, Map<String, Object?>? extra}) =>
    HostProfile({
      'id': id,
      'label': id,
      'hostname': '$id.example.com',
      'port': 22,
      'username': 'root',
      'authMethod': 'password',
      'protocol': 'ssh',
      if (password != null) 'password': password,
      ...?extra,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('发哪个密码', () {
    String? resolve(
      HostProfile tab,
      List<HostProfile> hosts, [
      List<Map<String, dynamic>> identities = const [],
    ]) =>
        storedHostPassword(tab, hosts: hosts, identities: identities);

    test('这台主机自己存的；不看标签上那份，看保险库现在的', () {
      final saved = _host('a', password: 'current');
      expect(resolve(_host('a', password: 'stale'), [saved]), 'current');
      expect(resolve(_host('a'), [saved]), 'current',
          reason: '后台满 10 分钟标签上的凭据清了');
    });

    test('临时标签（tmux、AI 工具）：按来源主机查', () {
      final tab = _host('managed-1', extra: {sourceHostIdKey: 'a'});
      expect(resolve(tab, [_host('a', password: 'pw')]), 'pw');
    });

    test('没存、存的是空的、主机删了、没进保险库：没有', () {
      expect(resolve(_host('a'), [_host('a')]), isNull);
      expect(resolve(_host('a'), [_host('a', password: '')]), isNull);
      expect(resolve(_host('a', password: 'pw'), const []), isNull);
    });

    test('经跳板：只看目标主机，跳板的密码绝不拿来发', () {
      final jump = _host('jump', password: 'jump-pw');
      final viaJump = _host('b', extra: {
        'hostChain': {
          'hostIds': ['jump'],
        },
      });
      expect(resolve(viaJump, [jump, viaJump]), isNull);
      final withOwn = _host('b', password: 'b-pw', extra: viaJump.data);
      expect(resolve(withOwn, [jump, _host('b', password: 'b-pw')]), 'b-pw');
    });

    test('主机引用身份：身份有密码用身份的，没存的退回主机自己的', () {
      final host = _host('a', password: 'own', extra: {'identityId': 'i'});
      expect(
        resolve(host, [
          host
        ], [
          {'id': 'i', 'authMethod': 'password', 'password': 'identity'},
        ]),
        'identity',
      );
      expect(
        resolve(host, [
          host
        ], [
          {'id': 'i', 'authMethod': 'password'},
        ]),
        'own',
      );
    });
  });

  group('发出去', () {
    late Map<String, List<String>> sent;
    late ProviderContainer container;
    late _Controller sessions;

    ActiveTerminalSession session(String id, HostProfile host) {
      final terminal = GhosttyTerminalAdapter();
      addTearDown(terminal.dispose);
      sent[id] = [];
      return ActiveTerminalSession(
        id: id,
        host: host,
        terminal: terminal,
        verifyHostKey: (_, __, ___) async => true,
        keyboardInteractive: null,
        binding: terminal
            .bind((Uint8List bytes) => sent[id]!.add(utf8.decode(bytes))),
      );
    }

    setUp(() async {
      sent = {};
      SharedPreferences.setMockInitialValues({});
      const secure =
          MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secure, (call) async => null);
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secure, null));
      final repository = await VaultRepository.open();
      container = ProviderContainer(overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
        sessionControllerProvider.overrideWith(
          (ref) => _Controller(ref.read(vaultControllerProvider.notifier), ref),
        ),
      ]);
      addTearDown(container.dispose);
      sessions =
          container.read(sessionControllerProvider.notifier) as _Controller;
    });

    Future<ActiveTerminalSession> seeded(
      HostProfile host, {
      String id = 'one',
    }) async {
      await container.read(vaultControllerProvider.notifier).upsertHost(host);
      final value = session(id, host);
      sessions.addSession(value);
      return value;
    }

    test('按打字发：一字不差，没有回车，远端开着 bracketed paste 也不包标记', () async {
      final target = await seeded(_host('a', password: r'p@ss w0rd"$'));
      target.terminal.feed(utf8.encode('\x1b[?2004h'));
      expect(target.terminal.bracketedPasteMode, isTrue);
      await sessions.sendStoredPassword(target);
      expect(sent['one']!.join(), r'p@ss w0rd"$');
    });

    test('亮着的 Ctrl 先清掉：不然第一个字符会被吃掉', () async {
      final target = await seeded(_host('a', password: 'secret'));
      target.terminal.input.setModifiers(const {'ctrl'});
      await sessions.sendStoredPassword(target);
      expect(sent['one']!.join(), 'secret');
      expect(target.terminal.input.modifiers, isEmpty);
    });

    test('两个标签：只发给按下时的那一个，发它自己的密码', () async {
      final first = await seeded(_host('a', password: 'first'));
      final second = await seeded(_host('b', password: 'second'), id: 'two');
      await sessions.sendStoredPassword(second);
      expect(sent['one'], isEmpty);
      expect(sent['two']!.join(), 'second');
      await sessions.sendStoredPassword(first);
      expect(sent['one']!.join(), 'first');
      expect(sent['two']!.join(), 'second');
    });

    test('经跳板的标签没存密码：抛错，什么都不发，跳板的密码不出现', () async {
      await container
          .read(vaultControllerProvider.notifier)
          .upsertHost(_host('jump', password: 'jump-pw'));
      final target = await seeded(_host('b', extra: {
        'hostChain': {
          'hostIds': ['jump'],
        },
      }));
      await expectLater(
        sessions.sendStoredPassword(target),
        throwsA(isA<StoredPasswordException>()),
      );
      expect(sent['one'], isEmpty);
    });

    test('密码里有换行或控制字符：不发（换行就等于自动回车）', () async {
      for (final bad in ['line\n', 'a\rb', 'a\x03b', 'a\x7fb']) {
        final target = await seeded(_host('a', password: bad));
        await expectLater(
          sessions.sendStoredPassword(target),
          throwsA(isA<StoredPasswordException>()),
          reason: jsonEncode(bad),
        );
        expect(sent['one'], isEmpty);
        sessions.removeAll();
      }
    });

    test('目标变了不发：标签关了、断了、换成恢复后的新连接', () async {
      final target = await seeded(_host('a', password: 'pw'));

      target.connected = false;
      await expectLater(
        sessions.sendStoredPassword(target),
        throwsA(isA<TerminalTargetChangedException>()),
      );
      target.connected = true;

      final replacement = session('one-again', target.host);
      sessions.replaceSession(target, replacement);
      await expectLater(
        sessions.sendStoredPassword(target),
        throwsA(isA<TerminalTargetChangedException>()),
      );

      sessions.removeAll();
      await expectLater(
        sessions.sendStoredPassword(replacement),
        throwsA(isA<TerminalTargetChangedException>()),
      );
      expect(sent['one'], isEmpty);
      expect(sent['one-again'], isEmpty);
    });

    test('不进日志', () async {
      final printed = <String>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add('$message');
      addTearDown(() => debugPrint = previous);
      final target = await seeded(_host('a', password: 'do-not-log-me'));
      await sessions.sendStoredPassword(target);
      expect(printed.where((line) => line.contains('do-not-log-me')), isEmpty);
    });
  });

  group('键', () {
    Future<void> pump(
      WidgetTester tester, {
      VoidCallback? onHostPassword,
      bool compact = false,
    }) async {
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: TerminalSpecialKeys(
              order: const ['escape'],
              customKeys: const [],
              onSend: (_, {bool enter = false}) {},
              onKey: (_) {},
              inputController: TerminalInputController(),
              onAi: null,
              onPortForward: null,
              pictureInPicture: false,
              onPictureInPicture: null,
              fullscreen: false,
              onFullscreen: () {},
              split: false,
              onSplit: null,
              compact: compact,
              onHostPassword: onHostPassword,
            ),
          ),
        ),
      ));
    }

    testWidgets('没存密码就没有这个键', (tester) async {
      await pump(tester);
      expect(
        find.byKey(const ValueKey('terminal-action-host-password')),
        findsNothing,
      );
    });

    testWidgets('按一下调一次', (tester) async {
      var pressed = 0;
      await pump(tester, onHostPassword: () => pressed++);
      await tester.tap(
        find.byKey(const ValueKey('terminal-action-host-password')),
      );
      expect(pressed, 1);
    });

    testWidgets('收成一行时在「更多」里', (tester) async {
      var pressed = 0;
      await pump(tester, onHostPassword: () => pressed++, compact: true);
      expect(
        find.byKey(const ValueKey('terminal-action-host-password')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('terminal-action-more')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('terminal-action-host-password')),
      );
      await tester.pumpAndSettle();
      expect(pressed, 1);
    });
  });
}

class _Controller extends SessionController {
  _Controller(VaultController vault, Ref ref) : super(SshService(), vault, ref);

  void addSession(ActiveTerminalSession value) =>
      state = state.copyWith(sessions: [...state.sessions, value]);

  void removeAll() => state = state.copyWith(sessions: const []);

  void replaceSession(
    ActiveTerminalSession old,
    ActiveTerminalSession replacement,
  ) =>
      state = state.copyWith(sessions: [
        for (final value in state.sessions)
          identical(value, old) ? replacement : value,
      ]);
}
