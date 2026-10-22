import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/connection_announcements.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/screens/terminal_screen.dart';
import 'package:shun/presentation/screens/vault_screen.dart';

import 'support/test_terminal.dart';

/// UX02 在真机（Pixel 9 Pro、TalkBack）上查出来的几处：断线、重连不播报；标签的 × 读成「删除」、
/// 只有 43dp；主机卡片的「更多操作」40dp；断线横幅半透明，和下面终端里的字叠在一起。
void main() {
  ActiveTerminalSession tab(String id, {String label = 'box', String? hostId}) {
    final terminal = newTestTerminal();
    addTearDown(terminal.dispose);
    return ActiveTerminalSession(
      id: id,
      host: HostProfile({
        'id': hostId ?? 'h-$id',
        'label': label,
        'hostname': 'box.example.com',
        'port': 22,
        'username': 'ops',
        'protocol': 'ssh',
      }),
      terminal: terminal,
      verifyHostKey: (_, __, ___) async => true,
      keyboardInteractive: null,
    );
  }

  group('要念什么', () {
    test('断开、自动恢复中、重新连上、恢复没成功各一句；状态没变的不念', () {
      final a = tab('a', label: 'web');
      final b = tab('b', label: 'db');
      final before = tabLinkStates(SessionState(sessions: [a, b]));

      a.connected = false;
      var now = SessionState(sessions: [a, b], recovering: const {'a'});
      expect(connectionAnnouncements(before, now), ['“web”断开了，正在自动恢复']);

      final recovering = tabLinkStates(now);
      expect(connectionAnnouncements(recovering, now), isEmpty);
      now = SessionState(sessions: [a, b]);
      expect(
          connectionAnnouncements(recovering, now), ['“web”没能自动恢复，可以点「重新连接」']);

      final held = tabLinkStates(now);
      a.connected = true;
      expect(connectionAnnouncements(held, now), ['“web”重新连上了']);

      b.connected = false;
      expect(
          connectionAnnouncements(tabLinkStates(SessionState(sessions: [a])),
              SessionState(sessions: [a, b])),
          isEmpty,
          reason: '新出现的标签不念：它有自己的等待页');
    });

    test('用户自己关的不念', () {
      final a = tab('a');
      final before = tabLinkStates(SessionState(sessions: [a]));
      a
        ..closedByUser = true
        ..connected = false;
      expect(connectionAnnouncements(before, SessionState(sessions: [a])),
          isEmpty);
    });
  });

  group('终端页', () {
    late _Controller controller;

    Future<void> open(WidgetTester tester, List<ActiveTerminalSession> tabs,
        {bool talkBack = false}) async {
      SharedPreferences.setMockInitialValues({});
      final repository = await VaultRepository.open();
      final messenger = tester.binding.defaultBinaryMessenger;
      const pip = MethodChannel('top.xdwa.shun/picture_in_picture');
      messenger.setMockMethodCallHandler(pip, (call) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(pip, null));
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      if (talkBack) {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(accessibleNavigation: true);
        addTearDown(
            tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      }
      // 同 terminal_transport_ui_test：让 flterm 的空闲任务不等动画。
      final strategy = tester.binding.schedulingStrategy;
      tester.binding.schedulingStrategy = (
              {required int priority, required SchedulerBinding scheduler}) =>
          true;
      addTearDown(() => tester.binding.schedulingStrategy = strategy);
      final container = ProviderContainer(overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
        sessionControllerProvider.overrideWith((ref) => controller =
            _Controller(ref.read(vaultControllerProvider.notifier), ref,
                SessionState(sessions: tabs))),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: TerminalScreen())),
      ));
      await tester.pump(const Duration(milliseconds: 500));
    }

    // 尺寸在这里验不了：真机上的 43dp 是长名字标签顶到标签条右边、点击区被裁掉的；测试里量到的
    // 语义区域不管裁没裁都是 48×48（10-22 试过：把末尾边距去掉也过）。改完在真机上用 uiautomator 量。
    testWidgets('标签的 × 读「关闭标签“名字”」，不读「删除」', (tester) async {
      final handle = tester.ensureSemantics();
      await open(tester, [tab('a')]);
      // 名字挂在 tooltip 上：Android 把它当 content-desc 给 TalkBack 读（真机上以前读出「删除」就是它）。
      final close = find.byTooltip('关闭标签“box”');
      expect(close, findsOneWidget);
      expect(find.byTooltip('删除'), findsNothing);
      final node = tester.getSemantics(close);
      expect(node.tooltip, '关闭标签“box”');
      handle.dispose();
    });

    testWidgets('名字很长也不把 × 挤出标签条：标签名超宽显示省略号，读屏读全名', (tester) async {
      final handle = tester.ensureSemantics();
      // 真机上就是这个名字：两个同主机的标签，第一个叫「……#1」，× 只露出 23dp。
      const name = '测试环境（本机 Docker）';
      await open(tester, [
        tab('a', label: name, hostId: 'same'),
        tab('b', label: name, hostId: 'same'),
      ]);
      final strip = tester.getRect(find
          .descendant(
              of: find.byKey(const ValueKey('terminal-tab-strip')),
              matching: find.byType(Scrollable))
          .first);
      final close = tester.getRect(find.byTooltip('关闭标签“$name”').first);
      expect(close.right, lessThanOrEqualTo(strip.right),
          reason: '× $close，标签条 $strip');
      expect(find.bySemanticsLabel(RegExp('$name #1')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('断开的标签读屏读得出「已断开」，不只靠橙色图标', (tester) async {
      final handle = tester.ensureSemantics();
      final a = tab('a')..connected = false;
      await open(tester, [a]);
      expect(find.bySemanticsLabel(RegExp('已断开')), findsWidgets);
      handle.dispose();
    });

    testWidgets('读屏开着：断线、重连上都主动念；关着时不念', (tester) async {
      final a = tab('a');
      await open(tester, [a], talkBack: true);
      tester.takeAnnouncements();

      a.connected = false;
      controller.publish(SessionState(sessions: [a], recovering: const {'a'}));
      await tester.pump();
      expect(tester.takeAnnouncements(),
          [isAccessibilityAnnouncement('“box”断开了，正在自动恢复')]);

      a.connected = true;
      controller.publish(SessionState(sessions: [a]));
      await tester.pump();
      expect(tester.takeAnnouncements(),
          [isAccessibilityAnnouncement('“box”重新连上了')]);
    });

    testWidgets('读屏关着不念', (tester) async {
      final a = tab('a');
      await open(tester, [a]);
      a.connected = false;
      controller.publish(SessionState(sessions: [a], recovering: const {'a'}));
      await tester.pump();
      expect(tester.takeAnnouncements(), isEmpty);
    });

    testWidgets('断线横幅不透明，不让下面终端里的字透出来', (tester) async {
      final a = tab('a')..connected = false;
      await open(tester, [a]);
      final banner = find.byKey(const ValueKey('terminal-connection-banner'));
      expect(banner, findsOneWidget);
      final material = tester.widget<Material>(
          find.descendant(of: banner, matching: find.byType(Material)).first);
      expect(material.color!.a, 1.0);
    });
  });

  testWidgets('主机卡片的「更多操作」至少 48×48（网格、列表都是）', (tester) async {
    const channel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    SharedPreferences.setMockInitialValues({
      'shun_vault_v1': jsonEncode({
        'hosts': [
          {
            'id': 'web',
            'label': 'web',
            'hostname': '192.0.2.10',
            'username': 'root',
            'protocol': 'ssh',
          }
        ],
        'keys': const [],
        'snippets': const [],
        'customGroups': const [],
      }),
    });
    final repository = await VaultRepository.open();
    await tester.pumpWidget(ProviderScope(
      overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
      child: const MaterialApp(home: Scaffold(body: VaultScreen())),
    ));
    await tester.pumpAndSettle();
    final menu = find.byKey(const ValueKey('vault-host-menu-web'));
    expect(menu, findsOneWidget);
    final size = tester.getSize(menu);
    expect(size.width, greaterThanOrEqualTo(48), reason: '$size');
    expect(size.height, greaterThanOrEqualTo(48), reason: '$size');
  });
}

class _Controller extends SessionController {
  _Controller(VaultController vault, Ref ref, SessionState initial)
      : super(SshService(), vault, ref) {
    state = initial;
  }

  void publish(SessionState value) => state = value;
}
