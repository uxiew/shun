import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/connection_switch.dart';
import 'package:shun/application/port_forward_controller.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/plugins/mosh_install_hint.dart';
import 'package:shun/domain/tmux/tmux_target.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:shun/infrastructure/tmux/tmux_protocol.dart';
import 'package:shun/presentation/screens/terminal_screen.dart';
import 'package:shun/presentation/widgets/connection_transport_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

// R42：标签条上的 SSH / MOSH 徽标和它的菜单。控制器是记录调用的替身：这里只验界面说了什么、点了交给谁；
// 切换本身的规矩见 connection_switch_test.dart。
void main() {
  const target = TmuxTarget(
    hostKey: 'box.example.com:22',
    unixUser: 'ops',
    uid: 1000,
    socket: TmuxSocketSpec.standard(),
    server: TmuxServerIdentity(
        socketPath: '/tmp/tmux-1000/default', pid: 70, startTime: 1700000000),
    sessionId: r'$3',
    sessionCreated: 1700000100,
    displayName: 'work',
  );

  ActiveTerminalSession tab(
    String id, {
    String protocol = 'ssh',
    TmuxClientBinding? tmux,
    PluginTerminalLink? plugin,
    bool ssh = false,
  }) =>
      ActiveTerminalSession(
        id: id,
        host: HostProfile({
          'id': 'h1',
          'label': 'box',
          'hostname': 'box.example.com',
          'port': 22,
          'username': 'ops',
          'protocol': protocol,
        }),
        terminal: GhosttyTerminalAdapter(),
        verifyHostKey: (_, __, ___) async => true,
        keyboardInteractive: null,
        tmux: tmux,
        plugin: plugin,
        // 一个不联网的 SSHClient：界面靠它认「这是连着的 SSH 标签」。
        sshClients:
            ssh ? [SSHClient(_QuietSocket(), username: 'ops')] : const [],
      );

  late _Controller controller;
  late _Forwards forwards;

  Future<void> open(
      WidgetTester tester, List<ActiveTerminalSession> tabs) async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    final messenger = tester.binding.defaultBinaryMessenger;
    const pip = MethodChannel('top.xdwa.shun/picture_in_picture');
    messenger.setMockMethodCallHandler(pip, (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(pip, null));
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    // 同 terminal_connection_banner_test：让 flterm 的空闲任务不等动画。
    final strategy = tester.binding.schedulingStrategy;
    tester.binding.schedulingStrategy =
        ({required int priority, required SchedulerBinding scheduler}) => true;
    addTearDown(() => tester.binding.schedulingStrategy = strategy);
    forwards = _Forwards();
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      portForwardControllerProvider.overrideWith((ref) => forwards),
      sessionControllerProvider.overrideWith((ref) => controller = _Controller(
          ref.read(vaultControllerProvider.notifier),
          ref,
          SessionState(sessions: tabs))),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: TerminalScreen())),
    ));
    await tester.pump(const Duration(milliseconds: 500));
  }

  Finder key(String value) => find.byKey(ValueKey(value));

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(key('terminal-transport-badge'));
    await tester.pumpAndSettle();
  }

  testWidgets('徽标写当前方式；菜单写主机、普通 shell、状态，普通标签是另开一个；不说切网不断', (tester) async {
    await open(tester, [tab('a')]);
    expect(
        find.descendant(
            of: key('terminal-transport-badge'), matching: find.text('SSH')),
        findsOneWidget);
    controller.menu = const TransportMenu(
      current: TabTransport.ssh,
      switchTo: TransportSwitchOption(from: TabTransport.ssh, inPlace: false),
      hostDefault: TabTransport.ssh,
    );
    await openMenu(tester);
    expect(find.text('box · SSH'), findsOneWidget);
    expect(find.text('ops@box.example.com:22'), findsOneWidget);
    expect(find.textContaining('普通 shell：跟着这条连接走'), findsOneWidget);
    expect(find.text('状态：已连接'), findsOneWidget);
    expect(find.text('用 Mosh 另开一个'), findsOneWidget);
    expect(find.textContaining('这个标签和里面的 shell 不动'), findsOneWidget);
    expect(key('transport-set-default'), findsNothing, reason: '和主机默认一样就不显示');
    expect(find.textContaining('漫游'), findsNothing);
    expect(find.textContaining('切网不断'), findsNothing);
    await tester.tap(key('transport-switch'));
    await tester.pumpAndSettle();
    expect(controller.switched.single.$1, 'a');
    expect(controller.switched.single.$2, isEmpty);
    expect(key('transport-switch'), findsNothing, reason: '另开一个：菜单先收起来，看等待卡片');
  });

  testWidgets('切不了时变灰并写原因，点了也不切；和默认不同时有「设为默认」', (tester) async {
    await open(tester, [tab('m', protocol: 'mosh')..connected = false]);
    expect(
        find.descendant(
            of: key('terminal-transport-badge'), matching: find.text('MOSH')),
        findsOneWidget);
    controller.menu = const TransportMenu(
      current: TabTransport.mosh,
      switchTo: TransportSwitchOption(
        from: TabTransport.mosh,
        inPlace: false,
        blocked: '这个标签已经断开了。先点「重新连接」，连上以后再切换。',
      ),
      hostDefault: TabTransport.ssh,
      setDefault: DefaultTransportOption(transport: TabTransport.mosh),
    );
    await openMenu(tester);
    expect(find.text('状态：已断开 · 终端里是断开前的画面（历史）'), findsOneWidget);
    expect(find.textContaining('先点「重新连接」'), findsOneWidget);
    await tester.tap(key('transport-switch'));
    await tester.pumpAndSettle();
    expect(controller.switched, isEmpty);
    expect(find.text('把 Mosh 设为这台主机的默认'), findsOneWidget);
    await tester.tap(key('transport-set-default'));
    await tester.pumpAndSettle();
    expect(controller.defaults, ['m']);
    expect(find.text('已把 Mosh 设为这台主机的默认'), findsOneWidget);
  });

  testWidgets('tmux 标签原地切到 Mosh：先列出这条 SSH 上会停掉的转发，确认了才切，传的就是列出的那几条',
      (tester) async {
    final binding = const TmuxClientBinding(
        target: target, clientTty: '/dev/pts/4', clientPid: 41);
    final t = tab('t', tmux: binding);
    await open(tester, [t]);
    forwards.items = [
      ActivePortForward(id: 'f1', kind: ForwardKind.dynamic, localPort: 1080),
      ActivePortForward(
          id: 'f2',
          kind: ForwardKind.local,
          localPort: 8080,
          remoteHost: '127.0.0.1',
          remotePort: 80),
    ];
    controller.menu = const TransportMenu(
      current: TabTransport.ssh,
      switchTo: TransportSwitchOption(from: TabTransport.ssh, inPlace: true),
      hostDefault: TabTransport.ssh,
    );
    await openMenu(tester);
    expect(find.textContaining(r'tmux 会话 work（$3）· ops@box.example.com:22'),
        findsOneWidget);
    expect(find.text('切换到 Mosh（同一个 tmux 会话）'), findsOneWidget);
    expect(find.textContaining('不重发任何输入'), findsOneWidget);

    await tester.tap(key('transport-switch'));
    await tester.pumpAndSettle();
    expect(key('transport-forwards-confirm'), findsOneWidget);
    expect(find.textContaining('上面的 2 条转发跟着停'), findsOneWidget);
    expect(find.text('• ${forwards.items[0].describe()}'), findsOneWidget);
    expect(find.text('• ${forwards.items[1].describe()}'), findsOneWidget);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(controller.switched, isEmpty, reason: '不确认就不切');

    await tester.tap(key('transport-switch'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('停掉并切换'));
    await tester.pumpAndSettle();
    expect(controller.switched.single.$1, 't');
    expect(controller.switched.single.$2, {'f1', 'f2'});
    expect(find.text('已切到 Mosh，还是同一个 tmux 会话'), findsOneWidget);
  });

  testWidgets('原地切换中：状态条写进度、能取消；失败时说原来的连接不变', (tester) async {
    final t = tab('t',
        tmux: const TmuxClientBinding(
            target: target, clientTty: '/dev/pts/4', clientPid: 41));
    await open(tester, [t]);
    controller.publish(controller.state.copyWith(switching: {
      't': const TransportSwitchProgress(TabTransport.mosh),
    }));
    await tester.pump();
    expect(find.textContaining('正在切到 Mosh…'), findsWidgets);
    expect(find.textContaining('切完之前这个标签照常能用'), findsOneWidget);
    await tester.tap(key('terminal-switch-cancel'));
    await tester.pump();
    expect(controller.cancelled, ['t']);

    controller.publish(controller.state.copyWith(switching: const {}));
    controller.menu = const TransportMenu(
      current: TabTransport.ssh,
      switchTo: TransportSwitchOption(from: TabTransport.ssh, inPlace: true),
    );
    controller.failWith = const TmuxTargetGoneException('原来的 tmux 会话已经不在了');
    await tester.pump();
    await openMenu(tester);
    await tester.tap(key('transport-switch'));
    await tester.pumpAndSettle();
    expect(find.textContaining('没有切换，原来的连接不变'), findsOneWidget);
    expect(find.textContaining('原来的 tmux 会话已经不在了'), findsOneWidget);
  });

  testWidgets('缺 mosh-server：给这台的安装、卸载命令，复制、填进 SSH 标签不回车', (tester) async {
    final t = tab('t',
        ssh: true,
        tmux: const TmuxClientBinding(
            target: target, clientTty: '/dev/pts/4', clientPid: 41));
    await open(tester, [t]);
    String? clipboard;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    controller.menu = const TransportMenu(
      current: TabTransport.ssh,
      switchTo: TransportSwitchOption(from: TabTransport.ssh, inPlace: true),
    );
    controller.failWith = MoshServerMissing(moshInstallHint(
        parseOsRelease('ID=debian\nPRETTY_NAME="Debian GNU/Linux 13"\n')));
    await openMenu(tester);
    await tester.tap(key('transport-switch'));
    await tester.pumpAndSettle();
    expect(find.text('服务器上没有 mosh-server'), findsOneWidget);
    expect(find.text('认出来的系统：Debian GNU/Linux 13'), findsOneWidget);
    expect(find.text('sudo apt-get install mosh'), findsOneWidget);
    expect(find.text('sudo apt-get remove mosh'), findsOneWidget,
        reason: '卸载命令也写着');
    expect(find.textContaining('放行 UDP 60001–60999'), findsOneWidget);
    expect(find.textContaining('《Mosh 使用指南》'), findsOneWidget);
    await tester.tap(key('mosh-install-copy'));
    await tester.pump();
    expect(clipboard, 'sudo apt-get install mosh');
    await tester.tap(key('mosh-install-paste'));
    await tester.pumpAndSettle();
    expect(controller.pasted.single, ('t', 'sudo apt-get install mosh'));
    expect(find.textContaining('没有回车'), findsOneWidget);
  });

  testWidgets('从保险库连 Mosh 主机、服务器缺 mosh-server：失败页给「看安装命令」', (tester) async {
    await open(tester, const []);
    controller.publish(SessionState(
      pendingConnections: [
        PendingTerminalConnection(
          id: 'p',
          host: HostProfile({
            'id': 'h1',
            'label': 'box',
            'hostname': 'box.example.com',
            'username': 'ops',
            'protocol': 'mosh',
          }),
          phase: PendingConnectionPhase.failed,
          error: MoshServerMissing(moshInstallHint(
              parseOsRelease('ID=alpine\nPRETTY_NAME="Alpine Linux v3.22"\n'))),
        ),
      ],
      activePendingId: 'p',
    ));
    await tester.pump();
    await tester.tap(key('mosh-install-hint-open'));
    await tester.pumpAndSettle();
    expect(find.text('认出来的系统：Alpine Linux v3.22'), findsOneWidget);
    // 保险库里没有这台（不知道登录用户）：按普通用户给 sudo。
    expect(find.text('sudo apk add mosh'), findsOneWidget);
    expect(find.textContaining('要管理员权限'), findsOneWidget);
    expect(find.text('sudo apk del mosh'), findsOneWidget);
    expect(key('mosh-install-paste'), findsNothing,
        reason: '没有这台的 SSH 标签就不给「填进」');
  });

  testWidgets('「安装…」：确认框写清命令、密码谁输、端口、怎么卸；取消什么都不发，确认才开安装标签；root 登录不加 sudo',
      (tester) async {
    await open(tester, const []);
    const secureStorage =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, null));
    // 保险库写盘是真异步：不放在 runAsync 里，假时钟下永远等不到。
    await tester.runAsync(() async {
      await controller.vaultController.upsertHost(HostProfile({
        'id': 'h1',
        'label': 'box',
        'hostname': 'box.example.com',
        'username': 'ops',
        'protocol': 'mosh',
        'shunMoshPorts': '60001:60010',
      }));
      await controller.vaultController.upsertHost(HostProfile({
        'id': 'h2',
        'label': 'rootbox',
        'hostname': 'root.example.com',
        'username': 'root',
        'protocol': 'mosh',
      }));
    });
    await tester.pump();
    final debian =
        moshInstallHint(parseOsRelease('ID=debian\nPRETTY_NAME="Debian 13"\n'));
    final context = tester.element(find.byType(TerminalScreen));
    unawaited(showMoshInstallHint(context, hint: debian, hostId: 'h1'));
    await tester.pumpAndSettle();
    await tester.tap(key('mosh-install-run'));
    await tester.pumpAndSettle();
    final dialog = find.byKey(const ValueKey('mosh-install-confirm'));
    expect(
        find.descendant(
            of: dialog, matching: find.textContaining('安装 mosh · box')),
        findsOneWidget);
    expect(
        find.descendant(
            of: dialog, matching: find.text('sudo apt-get install mosh')),
        findsOneWidget);
    expect(
        find.descendant(
            of: dialog, matching: find.textContaining('App 看不到、也不保存这个密码')),
        findsOneWidget);
    expect(
        find.descendant(
            of: dialog, matching: find.textContaining('放行 UDP 60001–60010')),
        findsOneWidget);
    expect(
        find.descendant(
            of: dialog,
            matching: find.textContaining('sudo apt-get remove mosh')),
        findsOneWidget);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(controller.installs, isEmpty, reason: '取消就什么都不发');
    await tester.tap(key('mosh-install-run'));
    await tester.pumpAndSettle();
    await tester.tap(key('mosh-install-confirm-run'));
    await tester.pumpAndSettle();
    expect(controller.installs.single, ('h1', 'sudo apt-get install mosh'));
    expect(key('mosh-install-run'), findsNothing, reason: '提示收起来，去看安装标签');

    final alpine = moshInstallHint(parseOsRelease('ID=alpine\n'));
    unawaited(showMoshInstallHint(context, hint: alpine, hostId: 'h2'));
    await tester.pumpAndSettle();
    expect(find.text('apk add mosh'), findsOneWidget, reason: 'root 登录不加 sudo');
    expect(find.text('apk del mosh'), findsOneWidget);
    await tester.tap(key('mosh-install-run'));
    await tester.pumpAndSettle();
    expect(find.textContaining('要管理员权限'), findsNothing);
    await tester.tap(key('mosh-install-confirm-run'));
    await tester.pumpAndSettle();
    expect(controller.installs.last, ('h2', 'apk add mosh'));

    // NixOS：没有一条能直接跑的命令，就没有「安装…」。
    unawaited(showMoshInstallHint(context,
        hint: moshInstallHint(parseOsRelease('ID=nixos\n')), hostId: 'h1'));
    await tester.pumpAndSettle();
    expect(key('mosh-install-run'), findsNothing);
    expect(find.textContaining('programs.mosh.enable'), findsOneWidget);
  });

  testWidgets('关 Mosh-tmux 标签：说只分离客户端、会话留在远端，不说 shell 会退出', (tester) async {
    final m = tab('m',
        protocol: 'mosh',
        plugin: _Link(),
        tmux: const TmuxClientBinding(
            target: target, clientTty: '/dev/pts/9', clientPid: 999));
    await open(tester, [m]);
    await tester.tap(find.byTooltip('Delete').first);
    await tester.pumpAndSettle();
    expect(find.textContaining(r'tmux 会话 work（$3）和里面的程序留在远端'), findsOneWidget);
    expect(find.textContaining('里面的 shell 会一起退出'), findsNothing);
  });
}

class _Controller extends SessionController {
  _Controller(VaultController vault, Ref ref, SessionState initial)
      : super(SshService(), vault, ref) {
    state = initial;
  }

  TransportMenu? menu;
  Object? failWith;
  final switched = <(String, Set<String>)>[];
  final defaults = <String>[];
  final cancelled = <String>[];
  final pasted = <(String, String)>[];
  final installs = <(String, String)>[];

  @override
  Future<bool> openMoshInstallTerminal({
    required String hostId,
    required String command,
    required HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
  }) async {
    installs.add((hostId, command));
    return true;
  }

  void publish(SessionState value) => state = value;

  @override
  Future<TransportMenu?> transportMenu(String sessionId) async => menu;

  @override
  Future<bool> switchTransport(
    String sessionId, {
    required HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
    Set<String> stoppingForwards = const {},
  }) async {
    if (failWith case final error?) throw error;
    switched.add((sessionId, stoppingForwards));
    return true;
  }

  @override
  Future<void> setDefaultTransport(String sessionId) async =>
      defaults.add(sessionId);

  @override
  void cancelSwitch(String sessionId) => cancelled.add(sessionId);

  @override
  void pasteInto(ActiveTerminalSession target, String text,
          {bool enter = false}) =>
      pasted.add((target.id, enter ? '$text\r' : text));
}

class _Forwards extends PortForwardController {
  var items = <ActivePortForward>[];

  @override
  List<ActivePortForward> forwardsOn(ActiveTerminalSession session) => items;
}

class _QuietSocket implements SSHSocket {
  final _in = StreamController<Uint8List>();
  final _out = StreamController<List<int>>()..stream.listen((_) {});

  @override
  Stream<Uint8List> get stream => _in.stream;
  @override
  StreamSink<List<int>> get sink => _out.sink;
  @override
  Future<void> get done => _in.done;
  @override
  Future<void> close() async => destroy();
  @override
  Future<void> flush() async {}
  @override
  void destroy() {
    unawaited(_in.close());
    unawaited(_out.close());
  }
}

class _Link implements PluginTerminalLink {
  @override
  String get protocol => 'Mosh';
  @override
  String get detail => 'UDP 10.0.2.2:60101';
  @override
  bool get active => true;
  @override
  Future<void> get ended => Completer<void>().future;
  @override
  String? get endNotice => null;
  @override
  Future<void> close() async {}
}
