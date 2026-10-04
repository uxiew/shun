import 'dart:convert';

import 'package:flutter/material.dart';
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
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flterm/flterm.dart' as flterm show TerminalView;
import 'package:xterm2/xterm.dart' as xterm show TerminalView;

// GST02：切标签、分屏、旋转、进出画中画、整页卸掉再装回，视图跟着重建，终端和连接不动；
// 旧视图晚一步销毁不影响新视图；只有关标签才释放终端。两个引擎各跑一遍。
//
// Ghostty 多两条：flterm 一个控制器同一时刻只能挂一个 flterm 视图，第二个来挂直接抛 StateError，
// 所以全程不能有异常；关标签后原生控制器要等视图卸下才释放，但最后一定释放（R17）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('xterm2：页面怎么重建都不新建连接、不释放终端；关标签才释放', (tester) async {
    await _ownership(
      tester,
      newTerminal: XtermTerminalAdapter.new,
      engineView: xterm.TerminalView,
    );
  });

  testWidgets('Ghostty：同上，并且 flterm 视图不重复挂、关标签后原生控制器释放', (tester) async {
    await _ownership(
      tester,
      newTerminal: GhosttyTerminalAdapter.new,
      engineView: flterm.TerminalView,
    );
  });
}

Future<void> _ownership(
  WidgetTester tester, {
  required TerminalSessionAdapterBase Function() newTerminal,
  required Type engineView,
}) async {
  {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('app.netcatty.mobile/picture_in_picture'),
      (call) async => null,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(
        const MethodChannel('app.netcatty.mobile/picture_in_picture'), null));
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final service = _CountingSshService();
    ActiveTerminalSession session(String id) {
      final terminal = newTerminal();
      terminal.feed(utf8.encode('marker-$id\r\n'));
      return ActiveTerminalSession(
        id: id,
        host: _host(id),
        terminal: terminal,
        verifyHostKey: (_, __, ___) async => true,
        keyboardInteractive: null,
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
          service,
        ),
      ),
    ]);
    addTearDown(container.dispose);
    final controller = container.read(sessionControllerProvider.notifier);

    Widget screen() => UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: TerminalScreen())),
        );

    // Ghostty 换手可能要多等一两帧（旧视图先卸下 flterm 视图，新视图下一帧再挂）。
    Future<void> settle() async {
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
    }

    void expectViews(Iterable<ActiveTerminalSession> shown) {
      expect(find.byType(engineView), findsNWidgets(shown.length));
      for (final s in [first, second]) {
        final terminal = s.terminal as TerminalSessionAdapterBase;
        expect(terminal.hasActiveView, shown.contains(s),
            reason: '${s.id} 的显示权不对');
        if (terminal is GhosttyTerminalAdapter) {
          expect(terminal.hasEngineView, shown.contains(s),
              reason: '${s.id} 的 flterm 视图挂得不对');
        }
      }
    }

    void expectUntouched() {
      expect(service.connects, 0, reason: '页面重建不能新建连接');
      for (final s in [first, second]) {
        expect(s.terminal.isDisposed, isFalse, reason: '${s.id} 的终端被页面释放了');
        expect(s.closedByUser, isFalse);
        expect(s.terminal.allText(), contains('marker-${s.id}'));
      }
    }

    await tester.pumpWidget(screen());
    await settle();
    expectViews([first]);
    expectUntouched();

    // 切标签
    controller.activate(1);
    await settle();
    expectViews([second]);
    expectUntouched();

    // 分屏：两个标签各一个视图
    await tester.tap(find.byKey(const ValueKey('terminal-action-split')));
    await settle();
    expectViews([first, second]);
    expectUntouched();

    // 旋转：分屏从上下变左右，两个视图都重建。新视图先挂上、旧视图后销毁，
    // 旧视图释放显示权时不能把新视图的也释放掉，否则新视图会变成空白。
    tester.view.physicalSize = const Size(2340, 1080);
    await settle();
    expectViews([first, second]);
    expectUntouched();

    // 进出画中画
    container.read(terminalPictureInPictureProvider.notifier).state = true;
    await settle();
    expectViews([second]);
    container.read(terminalPictureInPictureProvider.notifier).state = false;
    await settle();
    expectViews([first, second]);
    expectUntouched();

    // 整个终端页卸掉（切到别的页）再装回来
    await tester.pumpWidget(const SizedBox());
    await settle();
    expectViews([]);
    expectUntouched();
    await tester.pumpWidget(screen());
    await settle();
    // 分屏开关是页面自己的状态，重装后回到不分屏，只显示当前标签。
    expectViews([second]);
    expectUntouched();

    // 关标签才释放终端；另一个标签不受影响。
    await controller.close(0);
    await settle();
    expect(first.terminal.isDisposed, isTrue);
    expect(second.terminal.isDisposed, isFalse);
    expect(find.byType(engineView), findsOneWidget);
    expect(service.connects, 0);
    if (first.terminal case final GhosttyTerminalAdapter ghostty) {
      expect(ghostty.engineReleased, isTrue, reason: '视图卸下后原生控制器要释放');
    }

    // 收尾：关掉剩下的标签，Ghostty 的原生控制器同样要等视图卸下后释放。
    await controller.close(0);
    await settle();
    if (second.terminal case final GhosttyTerminalAdapter ghostty) {
      expect(ghostty.engineReleased, isTrue);
    }
  }
}

class _SeededSessionController extends SessionController {
  _SeededSessionController(
    VaultController vaultController,
    Ref ref,
    SessionState initialState,
    SshService service,
  ) : super(service, vaultController, ref) {
    state = initialState;
  }
}

class _CountingSshService extends SshService {
  var connects = 0;

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
    connects++;
    throw StateError('页面重建不该触发连接');
  }
}

HostProfile _host(String id) => HostProfile.create(
      id: id,
      label: id,
      hostname: '$id.example.com',
      username: 'root',
    );
