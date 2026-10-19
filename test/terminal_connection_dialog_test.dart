import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/settings_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/models/settings.dart';
import 'package:shun/domain/tmux/tmux_target.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/screens/terminal_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flterm/flterm.dart' as flterm show TerminalView;
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:shun/presentation/terminal/ghostty_terminal_view.dart';
import 'package:shun/infrastructure/terminal/terminal_session_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('pending connections remain separate selectable tabs', () {
    final host = _host('pending', '新服务器');
    final pending = PendingTerminalConnection(id: 'pending-1', host: host);
    final state = SessionState(
      pendingConnections: [pending],
      activePendingId: pending.id,
    );

    expect(state.tabCount, 1);
    expect(state.selectedPending, same(pending));
    expect(state.copyWith(activePendingId: null).selectedPending, isNull);
    expect(state.copyWith(activePendingId: null).pendingConnections, [pending]);
  });

  test('cancelling a pending connection removes its tab and stops transport',
      () async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    final host = _host('cancel', '等待连接');
    final service = _TrackingSshService();
    final container = ProviderContainer(
      overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
        sshServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(sessionControllerProvider.notifier);

    final connecting = controller.connect(host, _acceptHostKey);
    await Future<void>.delayed(Duration.zero);
    final pending = container.read(sessionControllerProvider).selectedPending!;
    controller.cancelPendingConnection(pending.id);

    // 取消直接作用在交给 SshService 的那次尝试上：它会立刻关掉已建好的 socket / client。
    expect(service.attempts.single.isCancelled, isTrue);
    expect(
      container.read(sessionControllerProvider).pendingConnections,
      isEmpty,
    );
    expect(container.read(sessionControllerProvider).activePendingId, isNull);
    service.result.completeError(const ConnectionCancelledException());
    await connecting;
  });

  test('commands can target a captured session instead of the active tab',
      () async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    final firstOutput = <String>[];
    final secondOutput = <String>[];
    final firstTerminal = GhosttyTerminalAdapter()
      ..bind((bytes) => firstOutput.add(utf8.decode(bytes)));
    final secondTerminal = GhosttyTerminalAdapter()
      ..bind((bytes) => secondOutput.add(utf8.decode(bytes)));
    final first = ActiveTerminalSession(
      id: 'session-first',
      host: HostProfile.create(
        id: 'first',
        label: 'First',
        hostname: 'first.example.com',
        username: 'root',
        port: 22022,
      ),
      terminal: firstTerminal,
      verifyHostKey: _acceptHostKey,
      keyboardInteractive: null,
    );
    final second = ActiveTerminalSession(
      id: 'session-second',
      host: _host('second', 'Second'),
      terminal: secondTerminal,
      verifyHostKey: _acceptHostKey,
      keyboardInteractive: null,
    );
    final container = ProviderContainer(
      overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
        sessionControllerProvider.overrideWith(
          (ref) => _SeededSessionController(
            ref.read(vaultControllerProvider.notifier),
            ref,
            SessionState(sessions: [first, second], activeIndex: 1),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(sessionControllerProvider.notifier);

    controller.sendToSession(first.id, 'ss -lntp');
    controller.send('pwd', enter: true);

    expect(firstOutput, ['ss -lntp']);
    // 片段（send）从 R19 起按粘贴发、回车单独发一次，所以是两块；这里只管发给了哪个标签。
    expect(secondOutput.join(), 'pwd\r');
    expect(
      () => controller.sendToSession('closed-session', 'whoami'),
      throwsStateError,
    );
  });

  test('terminal session tabs reorder without changing the active session',
      () async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    final first = ActiveTerminalSession(
      id: 'session-first',
      host: _host('first', 'First'),
      terminal: GhosttyTerminalAdapter(),
      verifyHostKey: _acceptHostKey,
      keyboardInteractive: null,
    );
    final second = ActiveTerminalSession(
      id: 'session-second',
      host: _host('second', 'Second'),
      terminal: GhosttyTerminalAdapter(),
      verifyHostKey: _acceptHostKey,
      keyboardInteractive: null,
    );
    final pending = PendingTerminalConnection(
      id: 'pending-third',
      host: _host('third', 'Third'),
    );
    final container = ProviderContainer(
      overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
        sessionControllerProvider.overrideWith(
          (ref) => _SeededSessionController(
            ref.read(vaultControllerProvider.notifier),
            ref,
            SessionState(
              sessions: [first, second],
              activeIndex: 1,
              pendingConnections: [pending],
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(sessionControllerProvider.notifier);

    controller.reorderSessionTab(0, 1);
    var state = container.read(sessionControllerProvider);
    expect(state.sessions.map((session) => session.id), [second.id, first.id]);
    expect(state.active?.id, second.id);

    controller.reorderSessionTab(0, 2);
    state = container.read(sessionControllerProvider);
    expect(state.sessions.map((session) => session.id), [first.id, second.id]);
    expect(state.active?.id, second.id);
    expect(state.pendingConnections.single.id, pending.id);

    controller.reorderSessionTab(2, 0);
    expect(
      container
          .read(sessionControllerProvider)
          .sessions
          .map((session) => session.id),
      [first.id, second.id],
    );
  });

  testWidgets(
    'connection progress is a dialog in its tab and existing terminal stays usable',
    (tester) async {
      // flterm 闲下来后排一个空闲任务压缩滚动区，碰上按钮水波纹这类动画时，假时钟下的 pumpAndSettle 会死循环
      // （docs/dev/README.md 第 7 节）。让空闲任务不等动画，和页面逻辑无关。
      final strategy = tester.binding.schedulingStrategy;
      tester.binding.schedulingStrategy = (
              {required int priority, required SchedulerBinding scheduler}) =>
          true;
      addTearDown(() => tester.binding.schedulingStrategy = strategy);
      SharedPreferences.setMockInitialValues({});
      final repository = await VaultRepository.open();
      final existingHost = _host('existing', '已有终端');
      final pendingHost = _host('pending', '正在连接');
      final existing = ActiveTerminalSession(
        id: 'session-1',
        host: existingHost,
        terminal: GhosttyTerminalAdapter(),
        verifyHostKey: _acceptHostKey,
        keyboardInteractive: null,
      );
      existing.terminal.feed(utf8.encode('alpha beta gamma'));
      final pending = PendingTerminalConnection(
        id: 'pending-1',
        host: pendingHost,
        stage: const ConnectionStage(
          ConnectionStep.handshake,
          hop: 1,
          hopCount: 3,
          label: 'hop2',
        ),
      );
      final initialState = SessionState(
        sessions: [existing],
        pendingConnections: [pending],
        activePendingId: pending.id,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            vaultRepositoryProvider.overrideWithValue(repository),
            sessionControllerProvider.overrideWith(
              (ref) => _SeededSessionController(
                ref.read(vaultControllerProvider.notifier),
                ref,
                initialState,
              ),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: TerminalScreen()),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('terminal-connection-status-dialog')),
        findsOneWidget,
      );
      expect(find.text('正在建立安全连接…'), findsOneWidget);
      expect(find.text('第 2/3 跳，“hop2”：SSH 握手、核对指纹、登录'), findsOneWidget,
          reason: '等待页要写出当前卡在哪一跳、哪一步');
      expect(
        find.text('连接会在此标签页中完成，其他终端会话不会受到影响。'),
        findsNothing,
      );
      expect(find.text('已有终端'), findsOneWidget);
      expect(find.text('正在连接'), findsWidgets);
      expect(find.byType(ReorderableListView), findsOneWidget);
      expect(
        find.byKey(const ValueKey('terminal-tab-session-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('pending-terminal-tab-pending-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('cancel-pending-connection')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('cancel-pending-connection')),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('terminal-connection-status-dialog')),
        findsNothing,
      );
      expect(find.byType(GhosttyTerminalView), findsOneWidget);

      await tester.tap(find.text('已有终端'));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('terminal-connection-status-dialog')),
        findsNothing,
      );
      expect(find.byType(GhosttyTerminalView), findsOneWidget);
      expect(find.text('正在连接'), findsNothing);
      // 已有终端照常收发：上面取消的只是那个正在连接的标签。
      // 长按选字、拖手柄、链接这些终端本身的手势在 terminal_gestures_test、terminal_links_test 里测
      // （R20 之前这里测的是 xterm2 视图的选区手柄和 deleteDetection，xterm2 已不在 App 里）。
      final sent = <String>[];
      existing.terminal.bind((bytes) => sent.add(utf8.decode(bytes)));
      existing.terminal.sendText('ok');
      expect(sent, ['ok']);

      // tmux uses the alternate screen. A swipe must never become arrow keys,
      // including when the remote application has not enabled mouse reporting.
      existing.terminal.feed(utf8.encode('\x1b[?1049h\x1b[Halpha beta gamma'));
      await tester.pump();
      sent.clear();
      await tester.drag(
          find.byType(GhosttyTerminalView), const Offset(0, -100));
      await tester.pump();
      expect(sent, isEmpty);

      // With tmux mouse reporting enabled, scroll events still reach tmux.
      existing.terminal.feed(utf8.encode('\x1b[?1000h\x1b[?1006h'));
      await tester.pump();
      await tester.drag(
          find.byType(GhosttyTerminalView), const Offset(0, -100));
      await tester.pump();
      expect(sent, isNotEmpty);
      expect(sent.every((event) => event.startsWith('\x1b[<')), isTrue);
      expect(
          find.byKey(const ValueKey('terminal-copy-snapshot')), findsNothing);
      sent.clear();

      // 全屏程序里没法直接选字：右上角「复制」弹整屏文字的快照，在快照里选了复制。
      existing.terminal.feed(utf8.encode('\x1b[Halpha beta updated'));
      await tester.pump();
      String? copiedText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedText = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.tap(find.byKey(const ValueKey('copy-terminal-selection')));
      await tester.pumpAndSettle();
      expect(sent, isEmpty);
      final snapshot = tester.widget<TextField>(
          find.byKey(const ValueKey('terminal-copy-snapshot')));
      expect(snapshot.readOnly, isTrue);
      final captured = snapshot.controller!.text;
      expect(captured, contains('alpha beta updated'));
      // A tmux redraw must not change the text being selected/copied.
      existing.terminal.feed(utf8.encode('\x1b[2J\x1b[Hnew tmux output'));
      await tester.pump();
      expect(snapshot.controller!.text, captured);
      snapshot.controller!.selection =
          const TextSelection(baseOffset: 0, extentOffset: 5);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('copy-terminal-snapshot')));
      await tester.pumpAndSettle();
      expect(copiedText, 'alpha');
      // Opening it again shows the current screen, and supports copy all.
      await tester.tap(find.byKey(const ValueKey('copy-terminal-selection')));
      await tester.pumpAndSettle();
      final updated = tester
          .widget<TextField>(
              find.byKey(const ValueKey('terminal-copy-snapshot')))
          .controller!
          .text;
      expect(updated, contains('new tmux output'));
      await tester.tap(find.byKey(const ValueKey('copy-terminal-snapshot')));
      await tester.pumpAndSettle();
      expect(copiedText, updated);
      existing.terminal.feed(utf8.encode('\x1b[?1000l\x1b[?1006l\x1b[?1049l'));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('terminal-tab-strip')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('terminal-action-fullscreen')),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('terminal-tab-strip')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('terminal-floating-performance')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('terminal-performance-monitor')),
        findsOneWidget,
      );
      expect(find.byTooltip('退出全屏'), findsOneWidget);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'custom background makes the terminal canvas transparent in ${brightness.name} mode',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final repository = await VaultRepository.open();
        final settingsController = _SeededSettingsController(
          repository,
          const AppSettings(
            customBackgroundEnabled: true,
            customBackgroundPath: '/app/background.jpg',
            customBackgroundScope: 'terminal',
          ),
        );
        final session = ActiveTerminalSession(
          id: 'transparent-${brightness.name}',
          host: _host('transparent', '透明终端'),
          terminal: GhosttyTerminalAdapter(),
          verifyHostKey: _acceptHostKey,
          keyboardInteractive: null,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              vaultRepositoryProvider.overrideWithValue(repository),
              settingsControllerProvider.overrideWith(
                (ref) => settingsController,
              ),
              sessionControllerProvider.overrideWith(
                (ref) => _SeededSessionController(
                  ref.read(vaultControllerProvider.notifier),
                  ref,
                  SessionState(sessions: [session]),
                ),
              ),
            ],
            child: MaterialApp(
              theme: ThemeData(brightness: brightness),
              home: const Scaffold(body: TerminalScreen()),
            ),
          ),
        );
        await tester.pump();

        final terminalView = tester.widget<flterm.TerminalView>(
          find.byType(flterm.TerminalView),
        );
        expect(terminalView.theme!.backgroundOpacity, 0);
        final background = terminalView.theme!.palette.background;
        expect(background, isNot(Colors.transparent));
        expect(background.toARGB32() >>> 24, 255);
        expect(
          tester
              .widget<Material>(
                find.byKey(
                  const ValueKey('terminal-special-keys-surface'),
                ),
              )
              .color,
          Colors.transparent,
        );
      },
    );
  }

  testWidgets('secure keyboard change switches the IME mode and persists',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    await repository.saveSettings(
      const AppSettings(uiThemeId: 'catppuccin', terminalFontSize: 18),
    );
    final settingsController = _SeededSettingsController(repository);
    final host = _host('secure', '安全终端');
    final session = ActiveTerminalSession(
      id: 'secure-session',
      host: host,
      terminal: GhosttyTerminalAdapter(),
      verifyHostKey: _acceptHostKey,
      keyboardInteractive: null,
    );
    final initialState = SessionState(sessions: [session]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultRepositoryProvider.overrideWithValue(repository),
          settingsControllerProvider.overrideWith(
            (ref) => settingsController,
          ),
          sessionControllerProvider.overrideWith(
            (ref) => _SeededSessionController(
              ref.read(vaultControllerProvider.notifier),
              ref,
              initialState,
            ),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: TerminalScreen()),
        ),
      ),
    );
    await tester.pump();

    final normalView = find.byType(flterm.TerminalView);
    expect(tester.widget<flterm.TerminalView>(normalView).secureTextInput,
        isFalse);
    expect(
        tester.widget<flterm.TerminalView>(normalView).theme!.backgroundOpacity,
        1);
    expect(
      tester
          .widget<Material>(
            find.byKey(const ValueKey('terminal-special-keys-surface')),
          )
          .color,
      isNot(Colors.transparent),
    );

    await settingsController.updateTerminalSecureKeyboard(true);
    await tester.pump();

    // Ghostty 改的是已连上的输入法的配置（fork 的 secureTextInput），不用像 xterm2 那样重建视图。
    expect(
        tester
            .widget<flterm.TerminalView>(find.byType(flterm.TerminalView))
            .secureTextInput,
        isTrue);
    final persisted = await repository.loadSettings();
    expect(persisted.terminalSecureKeyboard, isTrue);
    expect(persisted.uiThemeId, 'catppuccin');
    expect(persisted.terminalFontSize, 18);
  });
}

class _SeededSessionController extends SessionController {
  _SeededSessionController(
    VaultController vaultController,
    Ref ref,
    SessionState initialState, {
    SshService? service,
  }) : super(service ?? SshService(), vaultController, ref) {
    state = initialState;
  }
}

/// connect 一直挂着，记下调用方传进来的尝试，看取消有没有落到它身上。
class _TrackingSshService extends SshService {
  final attempts = <ConnectionAttempt>[];
  final result = Completer<ActiveTerminalSession>();

  @override
  Future<ActiveTerminalSession> connect({
    required String sessionId,
    required HostProfile host,
    List<HostProfile> hosts = const [],
    List<SshKeyProfile> keys = const [],
    List<ProxyProfile> proxyProfiles = const [],
    RoutePlan? routePlan,
    required HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
    required TerminalSessionAdapter terminal,
    ConnectionPurpose purpose = ConnectionPurpose.fresh,
    ConnectionAttempt? attempt,
    TmuxTarget? tmuxAttach,
  }) {
    attempts.add(attempt!);
    return result.future;
  }
}

class _SeededSettingsController extends SettingsController {
  _SeededSettingsController(
    super.repository, [
    AppSettings initialState = const AppSettings(),
  ]) {
    state = initialState;
  }
}

HostProfile _host(String id, String label) => HostProfile.create(
      id: id,
      label: label,
      hostname: '$id.example.com',
      username: 'root',
    );

Future<bool> _acceptHostKey(
  HostProfile host,
  String algorithm,
  String fingerprint,
) async =>
    true;
