import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/host_identity.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/tmux/tmux_target.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/home_shell.dart';
import 'package:shun/presentation/screens/terminal_screen.dart';
import 'package:shun/presentation/widgets/session_overview.dart';

import 'support/test_terminal.dart';

// F35 / R70：从底栏「终端」往上滑出会话总览。手势手感要真机，这里管逻辑：分组、切换、关闭、重连。
void main() {
  HostProfile host(String id, String label) => HostProfile({
        'id': id,
        'label': label,
        'hostname': '192.0.2.1',
        'username': 'demo',
        'protocol': 'ssh',
      });

  ActiveTerminalSession tab(
    String id,
    HostProfile host, {
    bool connected = true,
    String? output,
    TmuxClientBinding? tmux,
  }) {
    final terminal = newTestTerminal();
    if (output != null) terminal.feed(utf8.encode(output));
    return ActiveTerminalSession(
      id: id,
      host: host,
      terminal: terminal,
      verifyHostKey: (_, __, ___) async => true,
      keyboardInteractive: null,
      tmux: tmux,
    )..connected = connected;
  }

  late ProviderContainer container;
  late _Seeded controller;
  final opened = <ActiveTerminalSession>[];

  Future<void> open(
    WidgetTester tester,
    SessionState state, {
    List<HostProfile> hosts = const [],
  }) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    // 同 terminal_connection_banner_test：让 flterm 的空闲任务不等动画。
    final strategy = tester.binding.schedulingStrategy;
    tester.binding.schedulingStrategy =
        ({required int priority, required SchedulerBinding scheduler}) => true;
    addTearDown(() => tester.binding.schedulingStrategy = strategy);
    opened
      ..clear()
      ..addAll(state.sessions);
    container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      sessionControllerProvider.overrideWith(
        (ref) => controller = _Seeded(
          ref.read(vaultControllerProvider.notifier),
          ref,
          state,
        ),
      ),
    ]);
    addTearDown(container.dispose);
    await container.read(vaultControllerProvider.notifier).ready();
    if (hosts.isNotEmpty) {
      final vault = container.read(vaultControllerProvider).data!;
      await container
          .read(vaultControllerProvider.notifier)
          .replace(vault.copyWith(hosts: hosts));
    }
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: HomeShell()),
    ));
    await tester.pump(const Duration(milliseconds: 500));
    // 假的安全存储让「远控」页报一条读不到的提示，它会挡住底部的按钮。和这里测的东西无关。
    tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
        .removeCurrentSnackBar();
    await tester.pump();
  }

  /// 拆掉页面、停掉会话，不留定时器。
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    for (final session in opened) {
      session.abort();
    }
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> swipeUp(WidgetTester tester) async {
    await tester.drag(
      find.byKey(const ValueKey('terminal-tab-swipe')),
      const Offset(0, -500),
    );
    await settle(tester);
  }

  final overview = find.byType(SessionOverview);

  testWidgets('上滑出总览；点「终端」照旧切页，不出总览；没滑够就收回去', (tester) async {
    await open(tester, const SessionState());
    expect(overview, findsNothing);

    await tester.tap(find.text('终端').last);
    await settle(tester);
    expect(container.read(homeTabProvider), 1);
    expect(overview, findsNothing);

    await tester.drag(
      find.byKey(const ValueKey('terminal-tab-swipe')),
      const Offset(0, -40),
    );
    await settle(tester);
    expect(overview, findsNothing, reason: '滑一点点不算');

    await swipeUp(tester);
    expect(overview, findsOneWidget);
    expect(find.text('没有打开的会话'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('别的底栏格子上滑不出总览', (tester) async {
    await open(tester, const SessionState());
    final bar =
        tester.getRect(find.byKey(const ValueKey('home-navigation-bar')));
    await tester.dragFrom(
      Offset(bar.left + bar.width * .5, bar.center.dy),
      const Offset(0, -500),
    );
    await settle(tester);
    expect(overview, findsNothing);
    await finish(tester);
  });

  testWidgets('按机器分组：同一台的标签在一个 tab 里，开在当前会话那台；预览是终端最近的文字', (tester) async {
    final alpha = host('a', 'alpha');
    final beta = host('b', 'beta');
    // 临时标签拿的是主机的拷贝，按来源算同一台。
    final copy = HostProfile({
      ...alpha.data,
      'id': 'temp',
      'label': 'alpha',
      sourceHostIdKey: 'a',
    });
    await open(
      tester,
      SessionState(
        sessions: [
          tab('s1', alpha, output: 'first screen\r\n'),
          tab('s2', beta, output: 'beta screen\r\n'),
          tab('s3', copy, output: 'copy screen\r\n'),
        ],
        activeIndex: 1,
      ),
      hosts: [alpha, beta],
    );
    await swipeUp(tester);
    expect(find.text('alpha · 2'), findsOneWidget);
    expect(find.text('beta'), findsWidgets);
    expect(find.textContaining('beta screen'), findsOneWidget,
        reason: '打开在当前会话那台');

    await tester.tap(find.text('alpha · 2'));
    await settle(tester);
    expect(find.textContaining('first screen'), findsOneWidget);
    expect(find.text('alpha #1'), findsOneWidget);

    // 左右滑到同一台的下一个会话。
    await tester.drag(
      find.byKey(const ValueKey('overview-windows')),
      const Offset(-320, 0),
    );
    await settle(tester);
    expect(find.textContaining('copy screen'), findsOneWidget);
    expect(find.text('alpha #2'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('tmux 标签的卡片写 tmux 会话名；同一台只剩一个普通标签时不带序号', (tester) async {
    final alpha = host('a', 'alpha');
    const binding = TmuxClientBinding(
      target: TmuxTarget(
        hostKey: 'box.example.com:22',
        unixUser: 'ops',
        uid: 1000,
        socket: TmuxSocketSpec.standard(),
        server: TmuxServerIdentity(
          socketPath: '/tmp/tmux-1000/default',
          pid: 70,
          startTime: 1700000000,
        ),
        sessionId: r'$3',
        sessionCreated: 1700000100,
        displayName: 'work',
      ),
      clientTty: '/dev/pts/3',
      clientPid: 71,
    );
    await open(
      tester,
      SessionState(
          sessions: [tab('s1', alpha), tab('s2', alpha, tmux: binding)]),
    );
    await swipeUp(tester);
    expect(find.text('alpha · 2'), findsOneWidget, reason: 'tmux 标签和普通标签是同一台');
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('tmux work'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('预览每秒刷新；总览不再挂终端视图（一个终端只能有一个视图）', (tester) async {
    final session = tab('s1', host('a', 'alpha'), output: 'old line\r\n');
    await open(tester, SessionState(sessions: [session]));
    await swipeUp(tester);
    expect(find.textContaining('old line'), findsOneWidget);
    session.terminal.feed(utf8.encode('new line\r\n'));
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump();
    expect(find.textContaining('new line'), findsOneWidget);
    expect(
      find.descendant(
        of: overview,
        matching: find.byWidgetPredicate(
          (widget) => widget.runtimeType.toString().contains('TerminalView'),
        ),
      ),
      findsNothing,
    );
    await finish(tester);
  });

  testWidgets('点卡片：切到那个会话和终端页，总览收起来', (tester) async {
    final alpha = host('a', 'alpha');
    final beta = host('b', 'beta');
    await open(
      tester,
      SessionState(sessions: [tab('s1', alpha), tab('s2', beta)]),
    );
    await swipeUp(tester);
    await tester.tap(find.text('beta').first);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('overview-window-s2')));
    await settle(tester);
    expect(overview, findsNothing);
    expect(container.read(sessionControllerProvider).activeIndex, 1);
    expect(container.read(homeTabProvider), 1);
    await finish(tester);
  });

  testWidgets('返回键、点边上、点 × 都能收起来；返回键先关总览不退出 App', (tester) async {
    await open(tester, const SessionState());
    await swipeUp(tester);
    final popped = await tester.binding.handlePopRoute();
    await settle(tester);
    expect(popped, isTrue, reason: '返回键被总览接住了');
    expect(overview, findsNothing);

    await swipeUp(tester);
    await tester.tapAt(const Offset(200, 10));
    await settle(tester);
    expect(overview, findsNothing);

    await swipeUp(tester);
    await tester.tap(find.byKey(const ValueKey('overview-close')));
    await settle(tester);
    expect(overview, findsNothing);
    await finish(tester);
  });

  testWidgets('往下滑收起来', (tester) async {
    await open(tester, const SessionState());
    await swipeUp(tester);
    await tester.drag(
      find.byKey(const ValueKey('session-overview')),
      const Offset(0, 500),
    );
    await settle(tester);
    expect(overview, findsNothing);
    await finish(tester);
  });

  testWidgets('× 先问再关，取消就留着；关完卡片没了', (tester) async {
    final alpha = host('a', 'alpha');
    await open(
      tester,
      SessionState(sessions: [tab('s1', alpha), tab('s2', alpha)]),
    );
    await swipeUp(tester);
    final close = find.byKey(const ValueKey('overview-close-s1'));
    await tester.tap(close);
    await settle(tester);
    await tester.tap(find.text('取消'));
    await settle(tester);
    expect(container.read(sessionControllerProvider).sessions, hasLength(2));

    await tester.tap(close);
    await settle(tester);
    await tester.tap(find.text('断开并关闭'));
    await settle(tester);
    final left = container.read(sessionControllerProvider).sessions;
    expect(left.map((value) => value.id), ['s2']);
    expect(find.byKey(const ValueKey('overview-window-s1')), findsNothing);
    await finish(tester);
  });

  testWidgets('断开的卡片有「重新连接」；两个以上断开时顶上有「全部重连」，一个接一个连', (tester) async {
    final alpha = host('a', 'alpha');
    await open(
      tester,
      SessionState(sessions: [
        tab('up', alpha),
        tab('down1', alpha, connected: false),
        tab('down2', alpha, connected: false),
      ]),
    );
    await swipeUp(tester);
    expect(find.byKey(const ValueKey('overview-reconnect-up')), findsNothing);
    await tester.drag(
      find.byKey(const ValueKey('overview-windows')),
      const Offset(-320, 0),
    );
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('overview-reconnect-down1')));
    await settle(tester);
    expect(controller.reconnected, ['down1']);

    controller.reconnected.clear();
    await tester.tap(find.byKey(const ValueKey('overview-reconnect-all')));
    await settle(tester);
    expect(controller.reconnected, ['down1', 'down2']);
    await finish(tester);
  });

  testWidgets('点了全部重连接着收起总览：指纹还问得出来，后面的标签照样连', (tester) async {
    final alpha = host('a', 'alpha');
    await open(
      tester,
      SessionState(sessions: [
        tab('down1', alpha, connected: false),
        tab('down2', alpha, connected: false),
      ]),
    );
    controller.gate = Completer<void>();
    await swipeUp(tester);
    await tester.tap(find.byKey(const ValueKey('overview-reconnect-all')));
    await tester.pump();
    expect(controller.reconnected, ['down1']);

    await tester.tap(find.byKey(const ValueKey('overview-close')));
    await settle(tester);
    expect(overview, findsNothing);

    // 总览已经没了，连接这时才问指纹：要弹得出来，不能直接按拒绝处理。
    final answer = controller.verifier!(alpha, 'ssh-ed25519', 'SHA256:test');
    await settle(tester);
    expect(find.textContaining('SHA256:test'), findsOneWidget);
    await tester.tap(find.text('拒绝'));
    await settle(tester);
    expect(await answer, isFalse);

    controller.gate!.complete();
    await settle(tester);
    expect(controller.reconnected, ['down1', 'down2']);
    await finish(tester);
  });

  testWidgets('键盘盖住底栏时从「更多」进：打开后下面的页没有焦点，键盘不会弹回来盖住总览', (tester) async {
    final alpha = host('a', 'alpha');
    await open(
      tester,
      SessionState(sessions: [tab('s1', alpha), tab('s2', alpha)]),
    );
    container.read(homeTabProvider.notifier).state = 1;
    await settle(tester);
    // 终端页不显示时拿不到焦点，所以要在这一页上切一次标签：新标签的终端一挂上就拿焦点。
    controller.activate(1);
    await settle(tester);

    bool inTerminal() =>
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<TerminalScreen>() !=
        null;
    expect(inTerminal(), isTrue);

    await tester.tap(find.byKey(const ValueKey('terminal-action-more')));
    await settle(tester);
    await tester
        .tap(find.byKey(const ValueKey('terminal-action-session-overview')));
    await settle(tester);
    expect(overview, findsOneWidget);
    expect(inTerminal(), isFalse);
    await finish(tester);
  });

  testWidgets('键盘弹着时点「更多」，菜单一开键盘就收了：选的项不能丢', (tester) async {
    final alpha = host('a', 'alpha');
    await open(
      tester,
      SessionState(sessions: [tab('s1', alpha), tab('s2', alpha)]),
    );
    container.read(homeTabProvider.notifier).state = 1;
    await settle(tester);
    controller.activate(1);
    tester.view.viewInsets = const FakeViewPadding(bottom: 800);
    addTearDown(tester.view.resetViewInsets);
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('terminal-action-more')));
    await tester.pump();
    // 菜单抢走焦点，系统把键盘收了。
    tester.view.viewInsets = FakeViewPadding.zero;
    await settle(tester);
    await tester
        .tap(find.byKey(const ValueKey('terminal-action-session-overview')));
    await settle(tester);
    expect(overview, findsOneWidget);
    await finish(tester);
  });

  testWidgets('全屏时没有底栏：「更多」能开总览，返回键先关总览，还在全屏', (tester) async {
    final alpha = host('a', 'alpha');
    await open(tester, SessionState(sessions: [tab('s1', alpha)]));
    container.read(homeTabProvider.notifier).state = 1;
    container.read(terminalFullscreenProvider.notifier).state = true;
    await settle(tester);
    expect(find.byKey(const ValueKey('home-navigation-bar')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('terminal-action-more')));
    await settle(tester);
    await tester
        .tap(find.byKey(const ValueKey('terminal-action-session-overview')));
    await settle(tester);
    expect(overview, findsOneWidget);

    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(overview, findsNothing);
    expect(container.read(terminalFullscreenProvider), isTrue);
    await finish(tester);
  });

  testWidgets('切到标签条外面的标签：标签条滚过去，当前标签看得见', (tester) async {
    await open(
      tester,
      SessionState(sessions: [
        for (var i = 0; i < 12; i++) tab('s$i', host('m$i', 'machine-$i')),
      ]),
    );
    container.read(homeTabProvider.notifier).state = 1;
    await settle(tester);
    final last = find.byKey(const ValueKey('terminal-tab-s11'));
    expect(last, findsNothing, reason: '一开始在条外面，还没建');

    controller.activate(11);
    await settle(tester);
    expect(last, findsOneWidget);
    final strip =
        tester.getRect(find.byKey(const ValueKey('terminal-tab-strip')));
    final chip = tester.getRect(last);
    expect(chip.left, greaterThanOrEqualTo(strip.left));
    expect(chip.right, lessThanOrEqualTo(strip.right));
    await finish(tester);
  });

  testWidgets('正在自动恢复的标签不给按钮，写正在恢复；只断一个不显示全部重连', (tester) async {
    final alpha = host('a', 'alpha');
    await open(
      tester,
      SessionState(
        sessions: [
          tab('r', alpha, connected: false),
          tab('d', alpha, connected: false),
        ],
        recovering: const {'r'},
      ),
    );
    await swipeUp(tester);
    expect(find.text('正在恢复连接…'), findsOneWidget);
    expect(find.byKey(const ValueKey('overview-reconnect-r')), findsNothing);
    expect(find.byKey(const ValueKey('overview-reconnect-all')), findsNothing);
    await finish(tester);
  });

  testWidgets('连接中和失败的也在分组里：连接中不能关，失败的能关', (tester) async {
    final alpha = host('a', 'alpha');
    await open(
      tester,
      SessionState(pendingConnections: [
        PendingTerminalConnection(id: 'p1', host: alpha),
        PendingTerminalConnection(
          id: 'p2',
          host: alpha,
          phase: PendingConnectionPhase.failed,
          error: 'boom',
        ),
      ], activePendingId: 'p2'),
    );
    await swipeUp(tester);
    expect(find.text('连接失败'), findsOneWidget, reason: '打开在当前那个');
    await tester.tap(find.byKey(const ValueKey('overview-close-p2')));
    await settle(tester);
    expect(
      container
          .read(sessionControllerProvider)
          .pendingConnections
          .map((value) => value.id),
      ['p1'],
    );
    expect(find.text('正在连接…'), findsWidgets);
    expect(find.byKey(const ValueKey('overview-close-p1')), findsNothing);
    await finish(tester);
  });
}

class _Seeded extends SessionController {
  _Seeded(VaultController vaultController, Ref ref, SessionState initial)
      : super(SshService(), vaultController, ref) {
    state = initial;
  }

  final reconnected = <String>[];

  /// 设了就卡在第一个重连上，等测试放行。
  Completer<void>? gate;
  HostKeyVerifier? verifier;

  @override
  Future<void> reconnect(
    String sessionId, {
    required HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
  }) async {
    reconnected.add(sessionId);
    verifier = verifyHostKey;
    await gate?.future;
  }
}
