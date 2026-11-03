// R25 / UX04 设备验证：从常见错误进诊断与帮助，再看实际引擎、代理路线。真 App 页面、真 SSH（测试环境的 ssh-edge、
// dante、target）。四种常见失败各连一次：直连密码错、经 SOCKS 密码错、代理连不上、代理配置被删；每种看失败页的
// 提示、「这次实际走的路线」和连接记录；再看主机详情的路线、设置里的终端引擎、「选择连接类型」列的支持清单。
//
// 不是 CI 测试，只用 tool/r25-ux04-device.py 跑：它只认项目专用模拟器，负责转端口、传测试环境凭据、截图，
// 跑完清掉 App 数据。输出以 "UX04 " 开头的行是证据：
//   UX04 SHOT <名字>   驱动脚本截一张屏
//   UX04 <键>=<值>     页面上实际显示的字
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shun/app.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/screens/app_log_screen.dart';
import 'package:shun/presentation/widgets/connection_type_sheet.dart';
import 'package:shun/presentation/screens/settings_screen.dart';

const _raw = String.fromEnvironment('UX04_SSH');
final Map<String, dynamic> config =
    _raw.isEmpty ? const {} : jsonDecode(_raw) as Map<String, dynamic>;

void report(String key, Object? value) => debugPrint('UX04 $key=$value');

/// 真实时钟下一帧一帧地等：终端光标在闪，pumpAndSettle 等不到「静止」。
Future<void> waitFor(WidgetTester tester, bool Function() condition,
    {Duration timeout = const Duration(seconds: 30),
    String what = '条件'}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待$what超时');
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> settle(WidgetTester tester, [int ms = 600]) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;
  final skip =
      config.isEmpty ? '没给 UX04_SSH，用 tool/r25-ux04-device.py 跑' : false;

  testWidgets('UX04：常见错误 → 提示、实际路线、连接记录；主机详情、引擎、支持清单', (tester) async {
    final repository = await VaultRepository.open();
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const ShunApp(),
    ));
    await settle(tester, 1500);

    final vault = container.read(vaultControllerProvider.notifier);
    final controller = container.read(sessionControllerProvider.notifier);
    Finder key(String value) => find.byKey(ValueKey(value));
    String texts(Finder within) => tester
        .widgetList<Text>(find.descendant(
            of: within, matching: find.byType(Text), matchRoot: true))
        .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
        .where((t) => t.isNotEmpty)
        .join(' | ');
    String selectable(Finder within) => tester
        .widgetList<SelectableText>(
            find.descendant(of: within, matching: find.byType(SelectableText)))
        .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
        .join(' | ');
    Future<void> shot(String name) async {
      await settle(tester, 800);
      debugPrint('UX04 SHOT $name');
      await settle(tester, 1200);
    }

    final fingerprints = {
      '127.0.0.1': config['edgeFingerprint'],
      config['targetName']: config['targetFingerprint'],
    };
    Future<bool> verify(HostProfile host, String _, String fingerprint) async =>
        fingerprint == fingerprints[host.hostname];

    HostProfile login(Map<String, Object?> data) => HostProfile({
          'username': config['user'],
          'password': config['password'],
          'authMethod': 'password',
          'protocol': 'ssh',
          ...data,
        });
    final socks = {
      'type': 'socks5',
      'host': '127.0.0.1',
      'port': config['socksPort'],
      'username': config['socksUser'],
      'password': config['socksPassword'],
    };
    final ok = login({
      'id': 'ux04-ok',
      'label': 'UX04 直连',
      'hostname': '127.0.0.1',
      'port': config['edgePort'],
    });
    // 四种常见错误。密码错的两台选「密码」：服务器拒绝后不再换别的方式。
    final cases = <(String, HostProfile)>[
      (
        'wrong-direct',
        login({
          'id': 'ux04-wrong-direct',
          'label': 'UX04 直连密码错',
          'hostname': '127.0.0.1',
          'port': config['edgePort'],
          'password': 'ux04-not-the-password',
        })
      ),
      (
        'wrong-socks',
        login({
          'id': 'ux04-wrong-socks',
          'label': 'UX04 经代理密码错',
          'hostname': config['targetName'],
          'port': config['targetPort'],
          'password': 'ux04-not-the-password',
          'proxyConfig': socks,
        })
      ),
      (
        'proxy-down',
        login({
          'id': 'ux04-proxy-down',
          'label': 'UX04 代理连不上',
          'hostname': config['targetName'],
          'port': config['targetPort'],
          // 模拟器自己的 1 号端口没人听：代理那一跳就连不上。
          'proxyConfig': {...socks, 'port': 1},
        })
      ),
      (
        'proxy-deleted',
        login({
          'id': 'ux04-proxy-deleted',
          'label': 'UX04 代理已删',
          'hostname': config['targetName'],
          'port': config['targetPort'],
          'proxyProfileId': 'ux04-gone',
        })
      ),
    ];
    await vault.upsertHost(ok);
    for (final (_, host) in cases) {
      await vault.upsertHost(host);
    }
    await settle(tester, 800);

    // 先连一台好的：引擎建过终端，设置里才有版本号。
    expect(await controller.connect(ok, verify), isTrue);
    container.read(homeTabProvider.notifier).state = 1;
    await settle(tester, 1000);
    report('ok.tab', texts(key('terminal-tab-strip')));

    for (final (name, host) in cases) {
      await expectLater(controller.connect(host, verify), throwsA(anything),
          reason: name);
      container.read(homeTabProvider.notifier).state = 1;
      await waitFor(
          tester, () => key('connection-failure-log').evaluate().isNotEmpty,
          what: '$name 失败页');
      await settle(tester);
      report('$name.status', texts(key('terminal-connection-status-dialog')));
      report('$name.hint', texts(key('connection-failure-hint')));
      report('$name.route', texts(key('route-legs')));
      await shot('$name-1-failure');
      await tester.ensureVisible(key('connection-failure-log'));
      await settle(tester, 300);
      await tester.tap(key('connection-failure-log'));
      await waitFor(
          tester, () => find.byType(AppLogScreen).evaluate().isNotEmpty,
          what: '$name 记录页');
      await settle(tester);
      report('$name.log', texts(key('app-log-list')));
      await shot('$name-2-log');
      await tester.tap(find.byType(BackButton));
      await settle(tester);
      final pending = controller.state.pendingConnections
          .where((p) => p.host.id == host.id)
          .toList();
      for (final p in pending) {
        controller.dismissPending(p.id);
      }
      await settle(tester);
    }

    // 主机详情：经代理的逐段列，代理已删的写连接时会报的那句。
    container.read(homeTabProvider.notifier).state = 0;
    await settle(tester, 1000);
    for (final label in ['UX04 经代理密码错', 'UX04 代理已删']) {
      final tile = find.text(label);
      await tester.scrollUntilVisible(tile, 200,
          scrollable: find.byType(Scrollable).first, maxScrolls: 30);
      await settle(tester, 300);
      await tester.tap(tile);
      await waitFor(
          tester, () => key('host-detail-route').evaluate().isNotEmpty,
          what: '$label 详情');
      await settle(tester);
      report('details.$label.route',
          '${texts(key('host-detail-route'))} | ${selectable(key('host-detail-route'))}');
      report('details.$label.login', selectable(key('host-detail-login')));
      await shot(label.contains('已删') ? 'details-deleted' : 'details-socks');
      Navigator.of(tester.element(key('host-detail-route'))).pop();
      await settle(tester);
    }

    // 支持清单：表单顶上「更多」的面板，只看不选。
    await tester.tap(find.byTooltip('添加连接'));
    await settle(tester);
    await tester.tap(key('host-type-more'));
    await waitFor(
        tester, () => find.byType(ConnectionTypeSheet).evaluate().isNotEmpty,
        what: '类型面板');
    await settle(tester, 2000);
    report('types', texts(find.byType(ConnectionTypeSheet)));
    await shot('types');
    await tester.binding.handlePopRoute();
    await settle(tester);
    await tester.tap(find.byIcon(Icons.close));
    await settle(tester);

    // 实际引擎：设置 → 终端 → 终端引擎。
    container.read(homeTabProvider.notifier).state = 4;
    await settle(tester, 1000);
    final engine = key('terminal-engine-status');
    await tester.scrollUntilVisible(
      engine,
      300,
      scrollable: find
          .descendant(
              of: find.byType(SettingsScreen),
              matching: find.byType(Scrollable))
          .first,
      maxScrolls: 60,
    );
    await settle(tester, 300);
    report('engine', texts(engine));
    await shot('engine');

    for (var i = controller.state.sessions.length - 1; i >= 0; i--) {
      await controller.close(i);
    }
    await settle(tester, 500);
  }, skip: skip != false, timeout: const Timeout(Duration(minutes: 6)));
}
