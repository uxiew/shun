import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/tmux/tmux_target.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:netcatty_mobile/infrastructure/terminal/xterm_terminal_adapter.dart';
import 'package:netcatty_mobile/infrastructure/tmux/tmux_protocol.dart';
import 'package:netcatty_mobile/infrastructure/tmux/tmux_service.dart';
import 'package:netcatty_mobile/presentation/widgets/system_management/tmux_manager_panel.dart';

// R21：tmux 面板的界面行为。远端交互用假的 TmuxService 记录，真实 tmux 上的行为见 tmux_fixture_test.dart。
void main() {
  const server = TmuxServerIdentity(
      socketPath: '/tmp/tmux-1000/default', pid: 70, startTime: 1700000000);
  TmuxSessionRow row(String id, String name, {bool mouse = false}) =>
      TmuxSessionRow(
        server: server,
        sessionId: id,
        created: 1700000100,
        windows: 2,
        attached: 1,
        activity: null,
        mouse: mouse,
        prefix: 'C-a',
        group: '',
        name: name,
      );
  TmuxProbe ready(List<TmuxSessionRow> rows) => TmuxProbe(
        availability: TmuxAvailability.ready,
        unixUser: 'alice',
        uid: 1000,
        versionLine: 'tmux 3.5a',
        version: const TmuxVersion(3, 5, 'a'),
        socketPath: '/tmp/tmux-1000/default',
        server: server,
        sessions: rows,
      );

  ActiveTerminalSession session({TmuxClientBinding? tmux}) =>
      ActiveTerminalSession(
        id: 'tab',
        host: HostProfile({
          'id': 'h',
          'hostname': '10.0.0.5',
          'port': 22,
          'username': 'alice',
        }),
        terminal: XtermTerminalAdapter(),
        verifyHostKey: (_, __, ___) async => true,
        keyboardInteractive: null,
        sshClients: [_FakeSsh()],
        tmux: tmux,
      );

  Future<({_FakeTmux service, List<TmuxTarget> attached})> pump(
    WidgetTester tester,
    TmuxProbe probe, {
    ActiveTerminalSession? active,
  }) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = _FakeTmux(probe);
    final attached = <TmuxTarget>[];
    final tab = active ?? session();
    addTearDown(tab.close);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TmuxManagerPanel(
          session: tab,
          snippets: const [],
          service: service,
          refreshInterval: const Duration(hours: 1),
          onAttach: (target) async => attached.add(target),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return (service: service, attached: attached);
  }

  testWidgets('列表：显示 ID、前缀和鼠标状态；附着带上完整目标', (tester) async {
    final r =
        await pump(tester, ready([row(r'$0', 'work'), row(r'$4', 'work2')]));
    expect(find.text('work'), findsOneWidget);
    expect(find.textContaining(r'$4 · 2 个窗口 · 1 个客户端 · 前缀键 C-a · 鼠标关'),
        findsOneWidget);
    await tester.tap(find.byTooltip('在新标签里附着').last);
    await tester.pump();
    final target = r.attached.single;
    expect(target.sessionId, r'$4');
    expect(target.server, server);
    expect(target.sessionCreated, 1700000100);
    expect(target.hostKey, '10.0.0.5:22');
    expect(target.uid, 1000);
    expect(target.socket, const TmuxSocketSpec.standard());
  });

  testWidgets('结束：确认框写明按 ID、只结束这一个；取消不发命令', (tester) async {
    final r = await pump(tester, ready([row(r'$0', 'work')]));
    Future<void> openKill() async {
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('结束会话'));
      await tester.pumpAndSettle();
    }

    await openKill();
    expect(find.textContaining(r'work（$0）里的所有窗口和程序都会被终止'), findsOneWidget);
    expect(find.textContaining('按 ID 核对后才结束'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(r.service.calls, isEmpty);

    await openKill();
    await tester.tap(find.widgetWithText(FilledButton, '结束会话'));
    await tester.pumpAndSettle();
    expect(r.service.calls.single, r'kill $0 70');
  });

  testWidgets('鼠标：显式打开，写明只改这一个会话、不改 tmux.conf', (tester) async {
    final r = await pump(tester, ready([row(r'$0', 'work')]));
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('为这个会话打开鼠标'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('只改这一个会话的 mouse 选项，不改 tmux.conf'), findsOneWidget);
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(r.service.calls.single, r'mouse $0 true');
  });

  testWidgets('新建：名字不合规就提示、不发命令；合规才建，只建不附着', (tester) async {
    final r = await pump(tester, ready(const []));
    await tester.tap(find.text('新建'));
    await tester.pumpAndSettle();
    final fields = find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField));
    await tester.enterText(fields.at(0), '#(id)');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(find.textContaining('不能含 #'), findsOneWidget);
    expect(r.service.calls, isEmpty);

    await tester.enterText(fields.at(0), '工作 1');
    await tester.enterText(fields.at(1), 'htop');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(r.service.calls.single, 'create 工作 1 htop');
    expect(r.attached, isEmpty, reason: '新建不自动附着');
    expect(find.textContaining('已建好，没有附着'), findsOneWidget);
  });

  testWidgets('版本不在实测范围：只说明，不给任何操作', (tester) async {
    await pump(
      tester,
      const TmuxProbe(
        availability: TmuxAvailability.unsupported,
        uid: 1000,
        versionLine: 'tmux 1.8',
        problem: 'tmux 1.8 早于实测过的最老版本 2.4',
      ),
    );
    expect(find.textContaining('这里不提供附着、新建和结束'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '新建'))
            .onPressed,
        isNull);
  });

  testWidgets('输出不可信：只说明，不列会话、不给操作', (tester) async {
    await pump(
      tester,
      TmuxProbe(
        availability: TmuxAvailability.failed,
        uid: 1000,
        versionLine: 'tmux 3.5a',
        problem: 'tmux 输出里出现了 2 个不同的 server，无法确定目标',
        sessions: [row(r'$0', 'work')],
      ),
    );
    expect(find.textContaining('为安全起见不提供任何操作'), findsOneWidget);
    expect(find.byTooltip('在新标签里附着'), findsNothing, reason: '不可信的输出里的会话不列出来');
  });

  testWidgets('没有 tmux：写明没有自动安装', (tester) async {
    await pump(tester,
        const TmuxProbe(availability: TmuxAvailability.missing, uid: 1000));
    expect(find.textContaining('没有自动安装'), findsOneWidget);
  });

  testWidgets('本标签附着着 tmux：显示绑定的客户端，分离只分这一个', (tester) async {
    const target = TmuxTarget(
      hostKey: '10.0.0.5:22',
      unixUser: 'alice',
      uid: 1000,
      socket: TmuxSocketSpec.standard(),
      server: server,
      sessionId: r'$0',
      sessionCreated: 1700000100,
      displayName: 'work',
    );
    final r = await pump(
      tester,
      ready([row(r'$0', 'work')]),
      active: session(
        tmux: const TmuxClientBinding(
            target: target, clientTty: '/dev/pts/3', clientPid: 4321),
      ),
    );
    expect(find.textContaining(r'本标签附着在 work（$0）'), findsOneWidget);
    expect(find.textContaining('· 本标签'), findsOneWidget);
    await tester.tap(find.text('分离本标签'));
    await tester.pumpAndSettle();
    expect(r.service.calls.single, 'detach /dev/pts/3 4321');
  });

  testWidgets('换 socket：-L 名称查那个 server；路径不合规就提示', (tester) async {
    final r = await pump(tester, ready(const []));
    await tester.tap(find.text('默认 socket'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('-S 路径'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '/tmp/x; touch /tmp/p');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.textContaining('socket 路径必须是绝对路径'), findsOneWidget);
    await tester.tap(find.text('-L 名称'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'work');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(r.service.probed.last, TmuxSocketSpec.named('work'));
    expect(find.text('-L work'), findsOneWidget);
  });
}

class _FakeSsh extends Fake implements SSHClient {
  @override
  void close() {}
}

class _FakeTmux extends TmuxService {
  _FakeTmux(this.result);

  final TmuxProbe result;
  final calls = <String>[];
  final probed = <TmuxSocketSpec>[];

  @override
  Future<TmuxProbe> probe(SSHClient client, TmuxSocketSpec socket) async {
    probed.add(socket);
    return result;
  }

  @override
  Future<void> kill(SSHClient client, TmuxTarget target) async =>
      calls.add('kill ${target.sessionId} ${target.server.pid}');

  @override
  Future<void> setMouse(SSHClient client, TmuxTarget target,
          {required bool enable}) async =>
      calls.add('mouse ${target.sessionId} $enable');

  @override
  Future<void> detach(SSHClient client, TmuxClientBinding binding) async =>
      calls.add('detach ${binding.clientTty} ${binding.clientPid}');

  @override
  Future<TmuxTarget> create(
    SSHClient client, {
    required String hostKey,
    required String unixUser,
    required int uid,
    required TmuxSocketSpec socket,
    required String name,
    String startupCommand = '',
  }) async {
    calls.add('create $name $startupCommand');
    return TmuxTarget(
      hostKey: hostKey,
      unixUser: unixUser,
      uid: uid,
      socket: socket,
      server: const TmuxServerIdentity(
          socketPath: '/tmp/tmux-1000/default', pid: 70, startTime: 1),
      sessionId: r'$9',
      sessionCreated: 2,
      displayName: name,
    );
  }
}
