import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/session_controller.dart';
import 'package:netcatty_mobile/application/vault_controller.dart';
import 'package:netcatty_mobile/domain/connection_route.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/tmux/tmux_target.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:netcatty_mobile/infrastructure/terminal/terminal_session_adapter.dart';
import 'package:netcatty_mobile/infrastructure/terminal/xterm_terminal_adapter.dart';
import 'package:netcatty_mobile/presentation/screens/terminal_screen.dart';
import 'package:netcatty_mobile/presentation/terminal/terminal_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

// R19 / TER09、SEC10、UX03：终端页上的粘贴。快捷键栏「粘贴」、长按它打开的多行编辑框、硬件 Ctrl+V
// 三个入口走同一套：一行直接发；多行、末尾换行、控制字符先预览；默认不加回车；目标在动手那一刻定下，
// 断线、恢复成新连接后不发、不自动补发。两个引擎各跑一遍。

const _sheet = ValueKey('terminal-paste-editor');
const _send = ValueKey('terminal-paste-send');
const _sendEnter = ValueKey('terminal-paste-enter');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final engines = <String, TerminalSessionAdapterBase Function()>{
    'Ghostty': GhosttyTerminalAdapter.new,
    'xterm2': XtermTerminalAdapter.new,
  };

  for (final MapEntry(key: engine, value: newTerminal) in engines.entries) {
    group(engine, () {
      testWidgets('一行：点「粘贴」直接发，不弹预览，不加回车', (tester) async {
        final page = await _Page.open(tester, newTerminal, clipboard: 'ls -la');
        await page.tapPaste();
        expect(find.byKey(_sheet), findsNothing);
        expect(page.sent['first'], ['ls -la']);
      });

      testWidgets('多行、远端没开 bracketed paste：先预览，写明前面各行会执行；按钮也写明；末尾换行不发', (
        tester,
      ) async {
        final page = await _Page.open(
          tester,
          newTerminal,
          clipboard: 'echo 1\necho 2\n',
        );
        await page.tapPaste();
        expect(find.byKey(_sheet), findsOneWidget);
        expect(page.sent['first'], isEmpty, reason: '预览时什么都没发');
        expect(
          find.byKey(const ValueKey('terminal-paste-risk-lines-run')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('terminal-paste-trailing-newline')),
          findsOneWidget,
        );
        expect(find.text('粘贴（会逐行执行）'), findsOneWidget);
        expect(
          tester.widget(find.byKey(_send)),
          isA<OutlinedButton>(),
          reason: '会执行的动作不长成默认按钮',
        );

        await page.tap(find.byKey(_send));
        expect(find.byKey(_sheet), findsNothing);
        expect(page.sent['first'], ['echo 1\recho 2'], reason: '最后一行后面没有回车');
        expect(find.text('已粘贴到（没有回车） first'), findsOneWidget);
      });

      testWidgets('多行、远端开着 bracketed paste：写明只是远端约定；「粘贴」是默认按钮；包着标记发', (
        tester,
      ) async {
        final page = await _Page.open(
          tester,
          newTerminal,
          clipboard: 'echo 1\necho 2',
        );
        page.first.terminal.feed(utf8.encode('\x1b[?2004h'));
        await page.tapPaste();
        expect(
          find.byKey(const ValueKey('terminal-paste-risk-bracketed')),
          findsOneWidget,
        );
        expect(find.textContaining('App 保证不了'), findsOneWidget);
        expect(tester.widget(find.byKey(_send)), isA<FilledButton>());

        await page.tap(find.byKey(_send));
        expect(page.sent['first'], ['\x1b[200~echo 1\necho 2\x1b[201~']);
      });

      testWidgets('「粘贴并回车」：用户明确点了才在粘贴后加一个回车', (tester) async {
        final page = await _Page.open(tester, newTerminal, clipboard: 'make\n');
        await page.tapPaste();
        await page.tap(find.byKey(_sendEnter));
        expect(page.sent['first'], ['make', '\r']);
        expect(find.text('已粘贴并发送回车到 first'), findsOneWidget);
      });

      testWidgets('编辑框里按回车只换行，不发；取消什么都不发', (tester) async {
        final page = await _Page.open(tester, newTerminal, clipboard: 'a\nb');
        await page.tapPaste();
        await tester.enterText(find.byKey(_sheet), 'rm -rf /tmp/x\n');
        await tester.testTextInput.receiveAction(TextInputAction.newline);
        await page.settle();
        expect(page.sent['first'], isEmpty);

        await page.tap(find.byKey(const ValueKey('terminal-paste-cancel')));
        expect(find.byKey(_sheet), findsNothing);
        expect(page.sent['first'], isEmpty);
      });

      testWidgets('控制字符：预览里列出名字，发出去的没有它们', (tester) async {
        final page = await _Page.open(
          tester,
          newTerminal,
          clipboard: 'echo \x1b[31mred\x03\x10',
        );
        await page.tapPaste();
        expect(find.text('Esc ×1、Ctrl-C ×1、Ctrl-P ×1'), findsOneWidget);
        await page.tap(find.byKey(_send));
        expect(page.sent['first'], ['echo [31mred']);
      });

      testWidgets('断网：不发；恢复成新连接也不自动补发；点「改发到新连接」才发给新连接', (tester) async {
        final page = await _Page.open(tester, newTerminal, clipboard: 'a\nb');
        await page.tapPaste();

        page.disconnect(page.first);
        await page.settle();
        expect(
          find.byKey(const ValueKey('terminal-paste-target-problem')),
          findsOneWidget,
        );
        expect(tester.widget<ButtonStyleButton>(find.byKey(_send)).enabled,
            isFalse);
        expect(tester.widget<ButtonStyleButton>(find.byKey(_sendEnter)).enabled,
            isFalse);

        final restored = page.restore(page.first);
        await page.settle();
        expect(page.sent['first'], isEmpty);
        expect(page.sent['first-restored'], isEmpty, reason: '恢复后不自动补发');
        expect(find.textContaining('连接已经恢复成新的 shell'), findsOneWidget);

        await page.tap(find.byKey(const ValueKey('terminal-paste-retarget')));
        await page.tap(find.byKey(_send));
        expect(page.sent['first'], isEmpty, reason: '旧连接什么都没收到');
        expect(page.sent['first-restored'], ['a\rb']);
        expect(restored.terminal, same(page.first.terminal));
      });

      testWidgets('打开预览后切了标签：仍然只发给预览里写的那个', (tester) async {
        final page = await _Page.open(tester, newTerminal, clipboard: 'a\nb');
        await page.tapPaste();
        expect(find.text('粘贴到 first'), findsOneWidget);
        page.controller.activate(1);
        await page.settle();
        await page.tap(find.byKey(_send));
        expect(page.sent['first'], ['a\rb']);
        expect(page.sent['second'], isEmpty);
      });

      testWidgets('读剪贴板的时候连接被恢复换掉：不发，说明原因', (tester) async {
        final page = await _Page.open(tester, newTerminal, clipboard: 'ls');
        page.onClipboardRead = () => page.restore(page.first);
        await page.tapPaste();
        expect(page.sent['first'], isEmpty);
        expect(page.sent['first-restored'], isEmpty);
        expect(find.text('没有发送：连接已经恢复成新的 shell，原来那条收不到了'), findsOneWidget);
      });

      testWidgets('硬件键盘 Ctrl+V 走同一套预览；长按「粘贴」打开空白多行编辑框', (tester) async {
        final page = await _Page.open(tester, newTerminal, clipboard: 'a\nb');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await page.settle();
        expect(find.byKey(_sheet), findsOneWidget);
        expect(page.sent['first'], isEmpty, reason: '没有直接粘进终端，也没有发 Ctrl+V');
        await page.tap(find.byKey(const ValueKey('terminal-paste-cancel')));

        await tester.longPress(find.byTooltip('粘贴'));
        await page.settle();
        expect(find.byKey(_sheet), findsOneWidget);
        expect(tester.widget<TextField>(find.byKey(_sheet)).controller!.text,
            isEmpty);
        await tester.enterText(
            find.byKey(_sheet), 'for i in 1 2\ndo echo \$i\ndone');
        await page.settle();
        expect(page.sent['first'], isEmpty);
      });

      testWidgets('单独挂一个终端视图、没人接粘贴意图时，Ctrl+V 原样交给终端', (tester) async {
        final terminal = newTerminal();
        addTearDown(terminal.dispose);
        final sent = <String>[];
        terminal.bind((bytes) => sent.add(latin1.decode(bytes)));
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: terminalViewFor(
              terminal,
              const TerminalViewOptions(
                fontSize: 14,
                secureKeyboard: false,
                interactive: true,
                transparentBackground: false,
              ),
            ),
          ),
        ));
        await tester.pump();
        sent.clear();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(sent.join(), '\x16');
      });
    });
  }
}

/// 两个标签的终端页，终端绑着记录用的 sink（像连着一样），不建真连接。剪贴板是假的。
class _Page {
  _Page(this.tester, this.controller, this.first, this.sent);

  final WidgetTester tester;
  final _SeededSessionController controller;
  final ActiveTerminalSession first;
  final Map<String, List<String>> sent;
  VoidCallback? onClipboardRead;

  static Future<_Page> open(
    WidgetTester tester,
    TerminalSessionAdapterBase Function() newTerminal, {
    required String clipboard,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    final messenger = tester.binding.defaultBinaryMessenger;
    late _Page page;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        page.onClipboardRead?.call();
        return {'text': clipboard};
      }
      return null;
    });
    addTearDown(() =>
        messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    const pip = MethodChannel('app.netcatty.mobile/picture_in_picture');
    messenger.setMockMethodCallHandler(pip, (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(pip, null));
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    // 见 terminal_input_routing_test.dart：flterm 的空闲任务遇上动画会让假时钟下的 pump 死循环。
    final strategy = tester.binding.schedulingStrategy;
    tester.binding.schedulingStrategy =
        ({required int priority, required SchedulerBinding scheduler}) => true;
    addTearDown(() => tester.binding.schedulingStrategy = strategy);

    final sent = <String, List<String>>{};
    final terminals = <String, TerminalSessionAdapterBase>{};
    ActiveTerminalSession session(String id) {
      final terminal = newTerminal();
      terminals[id] = terminal;
      sent[id] = [];
      return ActiveTerminalSession(
        id: id,
        host: HostProfile.create(
          id: id,
          label: id,
          hostname: '$id.example.com',
          username: 'root',
        ),
        terminal: terminal,
        verifyHostKey: (_, __, ___) async => true,
        keyboardInteractive: null,
        binding: terminal
            .bind((Uint8List bytes) => sent[id]!.add(utf8.decode(bytes))),
      );
    }

    final first = session('first');
    final second = session('second');
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      sessionControllerProvider.overrideWith(
        (ref) => _SeededSessionController(
          ref.read(vaultControllerProvider.notifier),
          ref,
          SessionState(sessions: [first, second]),
        ),
      ),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: TerminalScreen())),
    ));
    page = _Page(
      tester,
      container.read(sessionControllerProvider.notifier)
          as _SeededSessionController,
      first,
      sent,
    );
    await page.settle();
    // 终端挂上时的协议回应（焦点事件之类）不算粘贴发的。
    for (final list in sent.values) {
      list.clear();
    }
    return page;
  }

  Future<void> settle() async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  }

  Future<void> tap(Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await settle();
  }

  Future<void> tapPaste() => tap(find.byTooltip('粘贴'));

  void disconnect(ActiveTerminalSession session) {
    session.connected = false;
    controller.replaceState(
      controller.state.copyWith(sessions: [...controller.state.sessions]),
    );
  }

  /// 模拟断线恢复：同一个标签、同一个终端，换一条新连接（新代次的绑定）。
  ActiveTerminalSession restore(ActiveTerminalSession old) {
    final id = '${old.id}-restored';
    sent[id] = [];
    final replacement = ActiveTerminalSession(
      id: old.id,
      host: old.host,
      terminal: old.terminal,
      verifyHostKey: old.verifyHostKey,
      keyboardInteractive: null,
      binding: old.terminal
          .bind((Uint8List bytes) => sent[id]!.add(utf8.decode(bytes))),
    );
    controller.replaceState(controller.state.copyWith(sessions: [
      for (final session in controller.state.sessions)
        identical(session, old) ? replacement : session,
    ]));
    return replacement;
  }
}

class _SeededSessionController extends SessionController {
  _SeededSessionController(
    VaultController vaultController,
    Ref ref,
    SessionState initialState,
  ) : super(_NoNetworkSshService(), vaultController, ref) {
    state = initialState;
  }

  void replaceState(SessionState value) => state = value;
}

/// 前后台切换会让会话控制器去重连没连着的标签；测试里一律失败，不碰网络。
class _NoNetworkSshService extends SshService {
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
  }) async =>
      throw StateError('测试不连网络');
}
