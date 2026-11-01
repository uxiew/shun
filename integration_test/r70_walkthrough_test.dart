// F31–F35 设备走查：真 App 页面、真安全存储、真 Android 触摸事件（adb input swipe），没有网络。
// 会话是塑进去的（没有真 SSH），所以证明的是界面、手势、中文字体下的布局，不是登录。
//
// 不是 CI 测试，只用 tool/r70-device.py 跑：它只认项目专用模拟器，按下面的标记截图和滑屏。
//   R70 SHOT <名字>                 截一张屏
//   R70 SWIPE <x0> <y0> <x1> <y1>    设备像素，脚本用 adb input swipe 滑一下
//   R70 TAP <x> <y>                  设备像素，脚本用 adb input tap 点一下
//   R70 BACK                         脚本按一下 Android 返回键
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shun/app.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/settings_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:shun/presentation/home_shell.dart';
import 'package:shun/presentation/widgets/first_login_dialog.dart';
import 'package:shun/presentation/widgets/host_editor.dart';
import 'package:shun/presentation/widgets/proxy_profile_editor.dart';
import 'package:shun/presentation/widgets/session_overview.dart';
import 'package:shun/presentation/widgets/system_management/server_panel_sheet.dart';

void mark(String line) => debugPrint('R70 $line');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // 默认测试框架丢掉设备发来的触摸，adb input swipe 会全部没反应，看着像手势坏了。
  binding.shouldPropagateDevicePointerEvents = true;

  Future<void> waitFor(
    WidgetTester tester,
    bool Function() condition, {
    required String what,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('等待$what超时');
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// 终端光标在闪，pumpAndSettle 等不到静止。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> shot(WidgetTester tester, String name) async {
    await settle(tester);
    await binding.delayed(const Duration(milliseconds: 400));
    await tester.pump();
    mark('SHOT $name');
    // 给脚本留出截屏时间：它读到标记才动手。
    await binding.delayed(const Duration(milliseconds: 1200));
    await tester.pump();
  }

  Future<void> swipe(
    WidgetTester tester,
    Offset from,
    Offset to,
  ) async {
    final ratio = tester.view.devicePixelRatio;
    mark('SWIPE ${(from.dx * ratio).round()} ${(from.dy * ratio).round()} '
        '${(to.dx * ratio).round()} ${(to.dy * ratio).round()}');
    // adb 是脚本这边异步发的，结果交给后面的 waitFor 判断。
    await binding.delayed(const Duration(milliseconds: 1500));
    await settle(tester);
  }

  /// adb 是脚本那边异步发的，结果交给后面的 waitFor 判断。
  Future<void> realTap(WidgetTester tester, Offset at) async {
    final ratio = tester.view.devicePixelRatio;
    mark('TAP ${(at.dx * ratio).round()} ${(at.dy * ratio).round()}');
    await binding.delayed(const Duration(milliseconds: 1200));
    await settle(tester);
  }

  Future<void> realBack(WidgetTester tester) async {
    mark('BACK');
    await binding.delayed(const Duration(milliseconds: 1200));
    await settle(tester);
  }

  ActiveTerminalSession tab(
    String id,
    HostProfile host,
    String screen, {
    bool connected = true,
  }) {
    final terminal = GhosttyTerminalAdapter();
    terminal.feed(utf8.encode(screen));
    return ActiveTerminalSession(
      id: id,
      host: host,
      terminal: terminal,
      verifyHostKey: (_, __, ___) async => true,
      keyboardInteractive: null,
    )..connected = connected;
  }

  HostProfile host(String id, String label, [Map<String, dynamic>? extra]) =>
      HostProfile({
        'id': id,
        'label': label,
        'hostname': '192.0.2.${id.hashCode % 200 + 1}',
        'username': 'root',
        'port': 22,
        'protocol': 'ssh',
        'authMethod': 'auto',
        ...?extra,
      });

  testWidgets('F31–F35 走查', (tester) async {
    final repository = await VaultRepository.open();
    final nas = host('nas', 'NAS 家里');
    final web = host('web', 'web-production-frontend-01');
    final old = host('old', '老服务器', {'identityFileId': 'k1'});
    final top = StringBuffer();
    for (var i = 0; i < 30; i++) {
      top.write('$i  进程列表一行 /usr/bin/python3 --serve --port=80${i % 10}\r\n');
    }
    final sessions = [
      tab('s1', nas, 'root@nas:~# uptime\r\n 10:00 up 3 days\r\nroot@nas:~# '),
      tab('s2', nas, top.toString()),
      tab('s3', nas, 'root@nas:~# ', connected: false),
      tab('s4', web, 'deploy@web:/srv# tail -f app.log\r\nGET /health 200\r\n'),
      tab('s5', host('db', 'postgres-primary'), 'psql (16.1)\r\n'),
      tab('s6', host('ci', 'ci-runner'), '', connected: false),
      tab('s7', host('gw', 'gateway'), r'gw$ '),
    ];
    late ProviderContainer container;
    container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      sessionControllerProvider.overrideWith(
        (ref) => _Seeded(
          ref.read(vaultControllerProvider.notifier),
          ref,
          SessionState(sessions: sessions),
        ),
      ),
    ]);
    addTearDown(container.dispose);
    final controller = container.read(vaultControllerProvider.notifier);
    final vault = await controller.ready();
    await controller.replace(VaultData.fromJson({
      ...vault.toJson(),
      'hosts': [nas.toJson(), web.toJson(), old.toJson()],
      'keys': [
        {
          'id': 'k1',
          'label': 'laptop-ed25519',
          'type': 'ED25519',
          'privateKey': 'not used here',
        },
      ],
      'identities': [
        {
          'id': 'team',
          'label': '运维共用账号',
          'username': 'ops',
          'authMethod': 'password',
          'password': 'walkthrough-only',
        },
        {
          'id': 'ask',
          'label': 'deploy-连接时问密码',
          'username': 'deploy',
          'authMethod': 'password',
        },
        {
          'id': 'key',
          'label': '笔记本密钥',
          'username': 'fodelf',
          'authMethod': 'key',
          'keyId': 'k1',
        },
      ],
    }));

    // 这些页带密码输入框，窗口默认防截屏，adb screencap 只会得到 0 字节的文件（R44）。
    // 只开在这个用完就清数据的测试 App 上。
    await container
        .read(settingsControllerProvider.notifier)
        .updateAllowSensitiveScreenshots(true);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const ShunApp(),
    ));
    await waitFor(
      tester,
      () => find.byType(HomeShell).evaluate().isNotEmpty,
      what: '首页',
      timeout: const Duration(seconds: 40),
    );
    await settle(tester);
    container.read(homeTabProvider.notifier).state = 1;
    await settle(tester);
    await shot(tester, '01-terminal');

    // ── 会话总览（F35）：真的触摸事件 ──
    final overview = find.byType(SessionOverview);
    final swipeArea = find.byKey(const ValueKey('terminal-tab-swipe'));
    final bar = tester.getRect(swipeArea);
    mark('report nav=$bar');
    await swipe(
      tester,
      bar.center,
      Offset(bar.center.dx, bar.center.dy - 420),
    );
    await waitFor(tester, () => overview.evaluate().isNotEmpty, what: '总览打开');
    await shot(tester, '02-overview-first-machine');

    // 多个卡片左右滑。
    final cards =
        tester.getRect(find.byKey(const ValueKey('overview-windows')));
    await swipe(
      tester,
      Offset(cards.right - 30, cards.center.dy),
      Offset(cards.left + 30, cards.center.dy),
    );
    await waitFor(
      tester,
      () => find.textContaining('进程列表一行').hitTestable().evaluate().isNotEmpty,
      what: '滑到第二张卡片',
    );
    await shot(tester, '03-overview-second-card');
    await swipe(
      tester,
      Offset(cards.right - 30, cards.center.dy),
      Offset(cards.left + 30, cards.center.dy),
    );
    await waitFor(
      tester,
      () => find
          .byKey(const ValueKey('overview-reconnect-s3'))
          .hitTestable()
          .evaluate()
          .isNotEmpty,
      what: '滑到断开的卡片',
    );
    await shot(tester, '04-overview-disconnected-card');

    // 机器多了 tab 条滑动。
    final machines =
        tester.getRect(find.byKey(const ValueKey('overview-machines')));
    await swipe(
      tester,
      Offset(machines.right - 20, machines.center.dy),
      Offset(machines.left + 20, machines.center.dy),
    );
    await shot(tester, '05-overview-machines-scrolled');
    await tester.tap(find.text('gateway'));
    await settle(tester);
    await shot(tester, '06-overview-last-machine');

    // 往下滑收起来：从卡片中间起手。竖向手势要穿过横向的 PageView，抢不过的话这里收不起来。
    final sheet =
        tester.getRect(find.byKey(const ValueKey('session-overview')));
    await swipe(
      tester,
      Offset(sheet.center.dx, cards.top + 60),
      Offset(sheet.center.dx, sheet.bottom - 10),
    );
    await waitFor(tester, () => overview.evaluate().isEmpty, what: '总览收起');
    await shot(tester, '07-overview-closed');

    // 从别的页面也能滑出来。
    container.read(homeTabProvider.notifier).state = 4;
    await settle(tester);
    await swipe(
      tester,
      bar.center,
      Offset(bar.center.dx, bar.center.dy - 420),
    );
    await waitFor(tester, () => overview.evaluate().isNotEmpty,
        what: '从设置页打开总览');
    await shot(tester, '08-overview-over-settings');

    // 真实点机器 tab、点卡片：切到那个会话，回到终端页。
    await realTap(
      tester,
      tester.getCenter(find.textContaining('web-production').last),
    );
    await waitFor(
      tester,
      () => find.textContaining('GET /health').evaluate().isNotEmpty,
      what: '切到第二台机器',
    );
    await realTap(
      tester,
      tester.getCenter(find.byKey(const ValueKey('overview-window-s4'))),
    );
    await waitFor(tester, () => overview.evaluate().isEmpty, what: '点卡片后收起');
    mark('report afterCard tab=${container.read(homeTabProvider)} '
        'active=${container.read(sessionControllerProvider).activeIndex}');
    expect(container.read(homeTabProvider), 1);
    expect(container.read(sessionControllerProvider).activeIndex, 3);
    await shot(tester, '09-opened-from-card');

    // 真实返回键：先关总览，App 不退出。
    await swipe(
      tester,
      bar.center,
      Offset(bar.center.dx, bar.center.dy - 420),
    );
    await waitFor(tester, () => overview.evaluate().isNotEmpty, what: '总览再次打开');
    await realBack(tester);
    await waitFor(tester, () => overview.evaluate().isEmpty, what: '返回键关总览');
    expect(find.byType(HomeShell), findsOneWidget);
    await shot(tester, '09b-back-closed-overview');

    final context = tester.element(find.byType(HomeShell));
    final navigator = Navigator.of(context);

    // ── 性能监控面板（F34）：中文字体下 tab 放不放得下 ──
    unawaited(navigator.push(MaterialPageRoute<void>(
      // 平时是底部弹层。这里没有真 SSH 所以各页都读不到数，只看 tab 放不放得下。
      builder: (_) => Scaffold(
        body: SafeArea(
          child: ServerPanelSheet(
            session: sessions.first,
            snippets: const [],
            onOpenTerminal: (_, __) async {},
            onOpenSftp: (_) {},
          ),
        ),
      ),
    )));
    await settle(tester);
    await shot(tester, '10-panel-overview');
    await tester.tap(find.text('Docker'));
    await settle(tester);
    await shot(tester, '11-panel-docker');
    navigator.pop();
    await settle(tester);

    // ── 主机编辑器（F31）──
    unawaited(navigator.push(MaterialPageRoute<void>(
      builder: (_) => const HostEditor(),
    )));
    await settle(tester);
    await shot(tester, '20-editor-new');
    navigator.pop();
    await settle(tester);

    unawaited(navigator.push(MaterialPageRoute<void>(
      builder: (_) => HostEditor(host: old),
    )));
    await settle(tester);
    // 表单是懒加载的，没滚到不存在。scrollUntilVisible 会把目标滚到顶上，所以滚回认证那段再截。
    final form = find
        .descendant(
          of: find.byType(HostEditor),
          matching: find.byType(Scrollable),
        )
        .first;
    final mode = find.byKey(const ValueKey('ssh-login-mode'));
    await tester.scrollUntilVisible(mode, 200, scrollable: form);
    await settle(tester);
    await shot(tester, '21-editor-own-key');

    await tester.tap(mode);
    await settle(tester);
    await shot(tester, '22-editor-mode-menu');
    await tester.tap(find.text('凭据').last);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('host-identity')));
    await settle(tester);
    await shot(tester, '23-credential-picker');
    await tester.tap(find.byKey(const ValueKey('credential-option-key')));
    await settle(tester);
    await shot(tester, '24-editor-credential-echo');

    await tester.tap(find.byKey(const ValueKey('host-identity')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('credential-new')));
    await settle(tester);
    await shot(tester, '25-credential-new');
    await tester.tap(find.byKey(const ValueKey('identity-auth')));
    await settle(tester);
    await tester.tap(find.text('安全密钥').last);
    await settle(tester);
    await shot(tester, '26-credential-security-key');
    navigator.pop();
    await settle(tester);
    navigator.pop();
    await settle(tester);
    if (find
        .byKey(const ValueKey('host-editor-discard'))
        .evaluate()
        .isNotEmpty) {
      await tester.tap(find.byKey(const ValueKey('host-editor-discard')));
      await settle(tester);
    }

    // ── 代理、首次登录（F31）──
    unawaited(navigator.push(MaterialPageRoute<void>(
      builder: (_) => const ProxyProfileEditor(),
    )));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('proxy-login-choice')));
    await settle(tester);
    await tester.tap(find.text('凭据').last);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('proxy-credential')));
    await settle(tester);
    await shot(tester, '30-proxy-credential-picker');
    navigator.pop();
    await settle(tester);
    navigator.pop();
    await settle(tester);

    unawaited(
        askFirstLogin(context, host('t', 'nas-tailscale', {'username': ''})));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('first-login-mode')));
    await settle(tester);
    await tester.tap(find.text('凭据').last);
    await settle(tester);
    await shot(tester, '31-first-login-credential');
    navigator.pop();
    await settle(tester);

    await tester.pumpWidget(const SizedBox());
    for (final session in sessions) {
      session.abort();
    }
    mark('DONE');
  });
}

class _Seeded extends SessionController {
  _Seeded(VaultController vaultController, Ref ref, SessionState initial)
      : super(SshService(), vaultController, ref) {
    state = initial;
  }
}
