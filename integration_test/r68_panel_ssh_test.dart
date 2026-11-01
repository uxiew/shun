// MON01 设备验证：真 App 页面、真安全存储、真 SSH（测试环境的 ssh-edge）、真 Android 触摸。
// 主机引用一个密码凭据，所以顺便证明手机上的安全存储读得出凭据、能登录。
//
// 只用 tool/r68-device.py 跑，它转端口、传测试环境凭据、按下面的标记动手、跑完清掉 App 数据。
//   R68 SHOT <名字>                 截一张屏
//   R68 SWIPE <x0> <y0> <x1> <y1>    设备像素，adb input swipe
//   R68 TAP <x> <y>                  设备像素，adb input tap
//   R68 BACK                         Android 返回键
//   R68 DROP                         docker restart ssh-edge：服务器那头断线
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
import 'package:shun/domain/credential_identity.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/home_shell.dart';
import 'package:shun/presentation/widgets/connection_prompts.dart';
import 'package:shun/presentation/widgets/system_management/caddy_manager_panel.dart';
import 'package:shun/presentation/widgets/system_management/docker_manager_panel.dart';
import 'package:shun/presentation/widgets/system_management/process_manager_panel.dart';
import 'package:shun/presentation/widgets/system_management/server_panel_sheet.dart';
import 'package:shun/presentation/widgets/system_management/service_manager_panel.dart';
import 'package:shun/presentation/widgets/system_management/tmux_manager_panel.dart';

const _raw = String.fromEnvironment('SHUN_FIXTURE');
final Map<String, dynamic> fixture =
    _raw.isEmpty ? const {} : jsonDecode(_raw) as Map<String, dynamic>;

void mark(String line) => debugPrint('R68 $line');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // 默认测试框架丢掉设备发来的触摸，adb input 会全部没反应，看着像按钮坏了。
  binding.shouldPropagateDevicePointerEvents = true;

  Future<void> waitFor(
    WidgetTester tester,
    bool Function() condition, {
    required String what,
    Duration timeout = const Duration(seconds: 30),
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
    await binding.delayed(const Duration(milliseconds: 1200));
    await tester.pump();
  }

  Future<void> realTap(WidgetTester tester, Finder target) async {
    final at = tester.getCenter(target);
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

  testWidgets('MON01 三个入口、真数据、断线', (tester) async {
    final repository = await VaultRepository.open();
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    final vaults = container.read(vaultControllerProvider.notifier);
    final vault = await vaults.ready();
    final identity = <String, dynamic>{
      'id': 'fixture-login',
      'label': 'fixture',
      'username': fixture['user'],
      'authMethod': 'password',
      'password': fixture['password'],
    };
    final data = <String, dynamic>{
      'id': 'r68',
      'label': 'r68-edge',
      'hostname': '127.0.0.1',
      'port': fixture['edgePort'],
      'username': 'nobody-here',
      'authMethod': 'password',
      'protocol': 'ssh',
    };
    useCredentialOn(data, IdentityProfile(identity));
    final host = HostProfile(data);
    await vaults.replace(VaultData.fromJson({
      ...vault.toJson(),
      'hosts': [host.toJson()],
      'identities': [identity],
    }));
    // 带密码框的页默认防截屏，adb screencap 只会得到 0 字节的文件（R44）。
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

    final sessions = container.read(sessionControllerProvider.notifier);
    final context = tester.element(find.byType(HomeShell));
    final connected = sessions.connect(host, hostKeyVerifier(context));
    final prompt = find.text('确认服务器指纹');
    await waitFor(tester, () => prompt.evaluate().isNotEmpty, what: '指纹核对框');
    expect(find.textContaining(fixture['edgeFingerprint'] as String),
        findsOneWidget);
    await tester.tap(find.text('接受并记住'));
    expect(await connected, isTrue);
    mark('report connected');
    container.read(homeTabProvider.notifier).state = 1;
    await settle(tester);
    final session = container.read(sessionControllerProvider).active!;
    expect(session.connected, isTrue);

    final panel = find.byType(ServerPanelSheet);

    /// 三个入口打开的都是同一个面板、同一个标签，概览读到真数据。
    Future<void> expectPanelOpen(String entry) async {
      await waitFor(tester, () => panel.evaluate().isNotEmpty, what: '$entry 打开');
      expect(tester.widget<ServerPanelSheet>(panel).session, same(session));
      await waitFor(
        tester,
        () => find.textContaining('Alpine').evaluate().isNotEmpty,
        what: '$entry 概览读到系统信息',
      );
      mark('report entry=$entry opened');
    }

    // 入口一：终端右上角。在这里把六页走一遍。
    await realTap(
        tester, find.byKey(const ValueKey('terminal-performance-monitor')));
    await expectPanelOpen('top-right');
    await shot(tester, '01-overview');

    final tabs = find.byKey(const ValueKey('server-panel-tabs'));
    Finder tab(String text) =>
        find.descendant(of: tabs, matching: find.text(text));
    final pageArea = tester.getCenter(panel);
    // 左滑一页：真触摸，横向手势要传到 TabBarView。
    final ratio = tester.view.devicePixelRatio;
    final fromX = (tester.view.physicalSize.width * .85).round();
    final toX = (tester.view.physicalSize.width * .15).round();
    final y = (pageArea.dy * ratio).round();
    mark('SWIPE $fromX $y $toX $y');
    await binding.delayed(const Duration(milliseconds: 1500));
    await waitFor(
      tester,
      () => find.byType(ProcessManagerPanel).evaluate().isNotEmpty,
      what: '左滑到进程页',
    );
    await waitFor(
      tester,
      () => find.textContaining('sshd').evaluate().isNotEmpty,
      what: '进程页读到 sshd',
    );
    mark('report process real data sshd');
    await shot(tester, '02-process');

    for (final (name, type, file) in [
      ('tmux', TmuxManagerPanel, '03-tmux'),
      ('Docker', DockerManagerPanel, '04-docker'),
      ('服务', ServiceManagerPanel, '05-service'),
      ('Caddy', CaddyManagerPanel, '06-caddy'),
    ]) {
      // tab 条自己能滚，靠右的 tab 可能在屏幕外面。
      await tester.ensureVisible(tab(name));
      await settle(tester);
      await realTap(tester, tab(name));
      await waitFor(
        tester,
        () => find.byType(type).evaluate().isNotEmpty,
        what: '$name 页',
      );
      await binding.delayed(const Duration(seconds: 3));
      await shot(tester, file);
      mark('report tab=$name shown');
    }
    await realBack(tester);
    await waitFor(tester, () => panel.evaluate().isEmpty, what: '返回键关面板');

    // 入口二：快捷栏「更多」。
    await realTap(tester, find.byKey(const ValueKey('terminal-action-more')));
    await shot(tester, '10-more-menu');
    await realTap(
      tester,
      find.byKey(const ValueKey('terminal-action-performance-monitor')),
    );
    await expectPanelOpen('more-menu');
    await realBack(tester);
    await waitFor(tester, () => panel.evaluate().isEmpty, what: '返回键关面板 2');

    // 入口三：主机列表的 ⋮ 菜单。
    container.read(homeTabProvider.notifier).state = 0;
    await settle(tester);
    await realTap(tester, find.byKey(const ValueKey('vault-host-menu-r68')));
    await shot(tester, '11-host-menu');
    await realTap(tester, find.byKey(const ValueKey('host-menu-monitor')));
    await expectPanelOpen('host-menu');
    await shot(tester, '12-from-host-menu');

    // 打开时断线：服务器那头没了。概览留着断开前的数，并且写明。
    expect(find.byKey(const ValueKey('monitor-disconnected')), findsNothing);
    mark('DROP');
    await waitFor(
      tester,
      () => find
          .byKey(const ValueKey('monitor-disconnected'))
          .evaluate()
          .isNotEmpty,
      what: '概览写明断开',
      timeout: const Duration(seconds: 60),
    );
    mark('report overview says disconnected');
    expect(find.textContaining('Alpine'), findsWidgets, reason: '留着断开前的数');
    await shot(tester, '20-overview-disconnected');
    await realTap(tester, tab('进程'));
    await waitFor(
      tester,
      () => find
          .byKey(const ValueKey('system-management-disconnected'))
          .evaluate()
          .isNotEmpty,
      what: '管理页整页禁用',
    );
    mark('report process page disabled');
    await shot(tester, '21-process-disconnected');
    expect(
      find.byWidgetPredicate(
        (widget) => widget is ProgressIndicator && widget.value == null,
      ),
      findsNothing,
      reason: '断了不会再读，不能一直转',
    );
    await realBack(tester);

    await tester.pumpWidget(const SizedBox());
    mark('DONE');
  }, timeout: const Timeout(Duration(minutes: 8)));
}
