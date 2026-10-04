import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/session_controller.dart';
import 'package:netcatty_mobile/application/vault_controller.dart';
import 'package:netcatty_mobile/domain/connection_route.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/infrastructure/terminal/terminal_session_adapter.dart';
import 'package:netcatty_mobile/infrastructure/terminal/xterm_terminal_adapter.dart';
import 'package:netcatty_mobile/presentation/screens/terminal_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm2/xterm.dart' show TerminalView;

// GST02（xterm2 路径）：切标签、分屏、旋转、进出画中画、整页卸掉再装回，
// 视图跟着重建，终端和连接不动；旧视图晚一步销毁不影响新视图；只有关标签才释放终端。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('页面怎么重建都不新建连接、不释放终端；关标签才释放', (tester) async {
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
      final terminal = XtermTerminalAdapter();
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

    void expectViews(Iterable<ActiveTerminalSession> shown) {
      for (final s in [first, second]) {
        expect((s.terminal as XtermTerminalAdapter).hasActiveView,
            shown.contains(s),
            reason: '${s.id} 的显示权不对');
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
    await tester.pump();
    expect(find.byType(TerminalView), findsOneWidget);
    expectViews([first]);
    expectUntouched();

    // 切标签
    controller.activate(1);
    await tester.pump();
    expect(find.byType(TerminalView), findsOneWidget);
    expectViews([second]);
    expectUntouched();

    // 分屏：两个标签各一个视图
    await tester.tap(find.byKey(const ValueKey('terminal-action-split')));
    await tester.pump();
    expect(find.byType(TerminalView), findsNWidgets(2));
    expectViews([first, second]);
    expectUntouched();

    // 旋转：分屏从上下变左右，两个视图都重建。新视图先挂上、旧视图后销毁，
    // 旧视图释放显示权时不能把新视图的也释放掉，否则新视图会变成空白。
    tester.view.physicalSize = const Size(2340, 1080);
    await tester.pump();
    await tester.pump();
    expect(find.byType(TerminalView), findsNWidgets(2));
    expectViews([first, second]);
    expectUntouched();

    // 进出画中画
    container.read(terminalPictureInPictureProvider.notifier).state = true;
    await tester.pump();
    expect(find.byType(TerminalView), findsOneWidget);
    expectViews([second]);
    container.read(terminalPictureInPictureProvider.notifier).state = false;
    await tester.pump();
    expect(find.byType(TerminalView), findsNWidgets(2));
    expectViews([first, second]);
    expectUntouched();

    // 整个终端页卸掉（切到别的页）再装回来
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expectViews([]);
    expectUntouched();
    await tester.pumpWidget(screen());
    await tester.pump();
    // 分屏开关是页面自己的状态，重装后回到不分屏，只显示当前标签。
    expect(find.byType(TerminalView), findsOneWidget);
    expectViews([second]);
    expectUntouched();

    // 关标签才释放终端；另一个标签不受影响。
    await controller.close(0);
    await tester.pump();
    expect(first.terminal.isDisposed, isTrue);
    expect(second.terminal.isDisposed, isFalse);
    expect(find.byType(TerminalView), findsOneWidget);
    expect(service.connects, 0);
  });
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
