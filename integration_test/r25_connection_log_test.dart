// R25 / UX10、SEC12 设备验证：真 App 页面、真记录文件、真 SSH（测试环境的 ssh-edge / dante / target）。
// Direct / SOCKS / Jump 各连一次，再拿错密码经跳板连一次（失败页 →「看这台主机的连接记录」），
// 驱动脚本杀掉 ssh-edge 上的会话看断开和自动恢复记下来；从主机 ⋮ 菜单进记录页、导出预览、复制，
// 重建一遍状态看文件读得回来，最后从设置里清除全部。
//
// 不是 CI 测试，只用 tool/r25-device.py 跑：它只认项目专用模拟器，负责转端口、传测试环境凭据、
// 按下面的标记截图和杀会话，跑完清掉 App 数据。输出以 "R25 " 开头的行是证据：
//   R25 SHOT <名字>      驱动脚本截一张屏
//   R25 KILL <容器> <n>  驱动脚本杀掉那个容器里的 sshd 会话，杀完在 App 私有目录放 r25-killed-<n>
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shun/app.dart';
import 'package:shun/application/connection_events.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/screens/connection_log_screen.dart';
import 'package:shun/presentation/screens/settings_screen.dart';

const _raw = String.fromEnvironment('R25_SSH');
final Map<String, dynamic> config =
    _raw.isEmpty ? const {} : jsonDecode(_raw) as Map<String, dynamic>;

void report(String key, Object? value) => debugPrint('R25 $key=$value');

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
  final skip = config.isEmpty ? '没给 R25_SSH，用 tool/r25-device.py 跑' : false;

  testWidgets('R25 连接记录：三条路线、失败、断开与恢复、导出脱敏、重启后还在、清除', (tester) async {
    final private = (await getApplicationSupportDirectory()).path;
    final logFile = File('$private/diagnostics/connection_events.json');
    final repository = await VaultRepository.open();
    var container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
    ]);
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
    Future<void> shot(String name) async {
      await settle(tester, 800);
      debugPrint('R25 SHOT $name');
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
    final direct = login({
      'id': 'r25-direct',
      'label': 'R25 直连',
      'hostname': '127.0.0.1',
      'port': config['edgePort'],
    });
    final socks = login({
      'id': 'r25-socks',
      'label': 'R25 SOCKS',
      'hostname': config['targetName'],
      'port': config['targetPort'],
      'proxyConfig': {
        'type': 'socks5',
        'host': '127.0.0.1',
        'port': config['socksPort'],
        'username': config['socksUser'],
        'password': config['socksPassword'],
      },
    });
    final jump = login({
      'id': 'r25-jump',
      'label': 'R25 跳板',
      'hostname': config['targetName'],
      'port': config['targetPort'],
      'hostChain': {
        'hostIds': ['r25-direct'],
      },
    });
    final wrong = login({
      'id': 'r25-wrong',
      'label': 'R25 错密码',
      'hostname': config['targetName'],
      'port': config['targetPort'],
      'password': 'r25-not-the-password',
      'hostChain': {
        'hostIds': ['r25-direct'],
      },
    });
    for (final host in [direct, socks, jump, wrong]) {
      await vault.upsertHost(host);
    }
    await settle(tester, 800);

    // 不该出现在记录文件和导出里的：密码、代理账号口令、地址、主机名字。
    final secrets = <String>[
      '${config['password']}',
      'r25-not-the-password',
      '${config['socksUser']}',
      '${config['socksPassword']}',
      '${config['targetName']}',
      '127.0.0.1',
      'R25 ',
    ];
    List<String> leaks(String text) => [
          for (final s in secrets)
            if (text.contains(s)) s
        ];

    for (final host in [direct, socks, jump]) {
      expect(await controller.connect(host, verify), isTrue, reason: host.id);
    }
    await expectLater(controller.connect(wrong, verify), throwsA(anything));
    container.read(homeTabProvider.notifier).state = 1;
    await waitFor(
        tester, () => key('connection-failure-log').evaluate().isNotEmpty,
        what: '失败页');
    await shot('01-failure-page');
    await tester.ensureVisible(key('connection-failure-log'));
    await settle(tester, 300);
    await tester.tap(key('connection-failure-log'));
    await waitFor(
        tester, () => find.byType(ConnectionLogScreen).evaluate().isNotEmpty,
        what: '失败页进记录页');
    await settle(tester);
    final failedCard = find.textContaining('失败：服务器拒绝登录');
    expect(failedCard, findsOneWidget);
    await tester.tap(failedCard);
    await settle(tester);
    report('failure.page', texts(key('connection-log-list')));
    await shot('02-failure-log');
    await tester.tap(find.byType(BackButton));
    await settle(tester);

    // 断开：杀掉 ssh-edge 上的会话。直连和跳板两个标签都经它，都会断、都会自己恢复。
    final killed = File('$private/r25-killed-1');
    if (killed.existsSync()) killed.deleteSync();
    debugPrint('R25 KILL ssh-edge 1');
    await waitFor(tester, killed.existsSync, what: '驱动脚本杀会话');
    bool restored(String hostId) =>
        container.read(connectionEventLogProvider).any((e) =>
            e.hostId == hostId &&
            e.kind == ConnectionEventKind.restore &&
            e.outcome == ConnectionOutcome.connected);
    await waitFor(tester, () => restored('r25-direct') && restored('r25-jump'),
        timeout: const Duration(seconds: 60), what: '直连和跳板自动恢复');

    // 从主机 ⋮ 菜单进「连接记录」
    container.read(homeTabProvider.notifier).state = 0;
    await settle(tester, 1000);
    final menu = key('vault-host-menu-r25-direct');
    await Scrollable.ensureVisible(tester.element(menu), alignment: 0.5);
    await settle(tester, 300);
    await tester.tap(menu);
    await waitFor(
        tester, () => key('host-menu-connectionLog').evaluate().isNotEmpty,
        what: '⋮ 菜单里有「连接记录」');
    await settle(tester);
    await tester.tap(key('host-menu-connectionLog'));
    await waitFor(
        tester, () => find.byType(ConnectionLogScreen).evaluate().isNotEmpty,
        what: '记录页');
    await settle(tester);
    report('direct.summary', texts(key('connection-log-summary')));
    await tester.tap(find.textContaining('自动恢复（第 1 次）').first);
    await settle(tester);
    report('direct.page', texts(key('connection-log-list')));
    await shot('03-direct-log');

    // 导出：先预览，预览里就是要复制的全部
    await tester.tap(key('connection-log-export'));
    await waitFor(tester,
        () => key('connection-log-export-preview').evaluate().isNotEmpty,
        what: '导出预览');
    await settle(tester);
    final preview = tester
        .widget<SelectableText>(key('connection-log-export-preview'))
        .data!;
    report('export.lines', preview.split('\n').length);
    report('export.leaks', leaks(preview));
    expect(leaks(preview), isEmpty);
    await shot('04-export-preview');
    await tester.tap(key('connection-log-copy'));
    await settle(tester, 1000);
    final copied = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    report('export.copiedMatchesPreview', copied == preview);
    expect(copied, preview);
    await tester.tap(find.byType(BackButton));
    await settle(tester);

    // 文件：真的写了盘、里面没有不该有的
    final events = container.read(connectionEventLogProvider);
    await waitFor(tester, () {
      if (!logFile.existsSync()) return false;
      final saved = jsonDecode(logFile.readAsStringSync()) as Map;
      return (saved['events'] as List).length == events.length;
    }, what: '记录写进文件');
    final onDisk = logFile.readAsStringSync();
    report('file.bytes', onDisk.length);
    report('file.events', events.length);
    report(
        'file.kinds',
        [
          for (final e in events)
            '${e.hostId}:${e.kind.name}:${e.outcome?.name ?? e.dropReason?.name}'
        ].join(','));
    report('file.leaks', leaks(onDisk));
    expect(leaks(onDisk), isEmpty);

    // 重建一遍状态（和重新打开 App 一样从文件读）：条数不变
    for (var i = controller.state.sessions.length - 1; i >= 0; i--) {
      await controller.close(i);
    }
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await settle(tester, 500);
    container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const ShunApp(),
    ));
    await settle(tester, 1500);
    await container.read(connectionEventLogProvider.notifier).ready;
    final reloaded = container.read(connectionEventLogProvider).length;
    report('reload.events', reloaded);
    expect(reloaded, events.length);

    // 从设置里看全部、清除全部
    container.read(homeTabProvider.notifier).state = 4;
    await settle(tester, 1000);
    // 设置页是懒加载的列表：安全那一节没滚到时还不在树上，得先滚过去。
    final entry = key('settings-connection-log');
    await tester.scrollUntilVisible(
      entry,
      300,
      scrollable: find
          .descendant(
              of: find.byType(SettingsScreen),
              matching: find.byType(Scrollable))
          .first,
      maxScrolls: 60,
    );
    await settle(tester, 300);
    await tester.tap(entry);
    await waitFor(
        tester, () => find.byType(ConnectionLogScreen).evaluate().isNotEmpty,
        what: '设置进记录页');
    await settle(tester);
    report('all.summary', texts(key('connection-log-summary')));
    await shot('05-all-hosts');
    await tester.tap(key('connection-log-clear'));
    await settle(tester);
    report('clear.dialog', texts(find.byType(AlertDialog)));
    await shot('06-clear-confirm');
    await tester.tap(key('connection-log-clear-confirm'));
    await waitFor(
        tester, () => key('connection-log-empty').evaluate().isNotEmpty,
        what: '清除后空了');
    report('clear.fileExists', logFile.existsSync());
    expect(logFile.existsSync(), isFalse);
    await shot('07-cleared');
  }, skip: skip != false, timeout: const Timeout(Duration(minutes: 6)));
}
