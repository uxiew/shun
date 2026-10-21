// R43 / UX09 设备验证：真 App 页面、真安全存储、真 SSH（测试环境的 ssh-edge）。
// Tailscale 目录 API 是本机假服务器 tool/tailscale-fixture/serve.dart：它给两个来源回同一份设备列表，
// 正好就是「两个来源里同名、同 IP、同设备 ID」。证明的是 App 发了什么、怎么显示，不证明 Tailscale 服务器的行为。
//
// 不是 CI 测试，只用 tool/r43-device.py 跑：它只认项目专用模拟器，负责起假 API、转端口、传测试环境凭据、
// 按下面的标记截图和换设备列表，跑完清掉 App 数据。输出以 "R43 " 开头的行是证据：
//   R43 SHOT <名字>   驱动脚本截一张屏
//   R43 SWAP          驱动脚本换成第二份设备列表，换好在 App 私有目录放 r43-swapped
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shun/app.dart';
import 'package:shun/application/catalog_overview.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/tailscale_catalog_access.dart';
import 'package:shun/application/tailscale_catalog_provider.dart';
import 'package:shun/application/tailscale_catalog_refresh.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/tailscale/catalog_secret_store.dart';
import 'package:shun/infrastructure/tailscale/tailscale_api.dart';
import 'package:shun/presentation/screens/tailscale_catalog_screen.dart';
import 'package:shun/presentation/widgets/catalog_import_sheet.dart';
import 'package:shun/presentation/widgets/port_forward_sheet.dart';
import 'package:shun/presentation/widgets/server_monitor_sheet.dart';

const _raw = String.fromEnvironment('R43_SSH');
final Map<String, dynamic> config =
    _raw.isEmpty ? const {} : jsonDecode(_raw) as Map<String, dynamic>;

void report(String key, Object? value) => debugPrint('R43 $key=$value');

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
  // 点不中（被搜索框、提示条挡住）就直接失败，不要等到后面超时才发现。
  WidgetController.hitTestWarningShouldBeFatal = true;
  final skip = config.isEmpty ? '没给 R43_SSH，用 tool/r43-device.py 跑' : false;

  testWidgets('R43 主机列表：类型角标、Tailscale 分节、⋮ 菜单、隐藏、移除来源', (tester) async {
    final repository = await VaultRepository.open();
    final client = http.Client();
    addTearDown(client.close);
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      tailscaleCatalogAccessProvider.overrideWithValue(TailscaleCatalogAccess(
        const TailscaleCatalogSecretStore(FlutterSecureCatalogBackend()),
        // ignore: invalid_use_of_visible_for_testing_member
        (credential) => TailscaleCatalogClient.fixture(
          client,
          Uri.parse('http://127.0.0.1:18480'),
          credential,
        ),
      )),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const ShunApp(),
    ));
    await settle(tester, 1500);
    container.read(homeTabProvider.notifier).state = 0;

    final vault = container.read(vaultControllerProvider.notifier);
    final controller = container.read(sessionControllerProvider.notifier);
    final catalog = container.read(tailscaleCatalogProvider);
    final overview = container.read(catalogOverviewProvider.notifier);
    Finder key(String value) => find.byKey(ValueKey(value));
    String texts(Finder within) => tester
        .widgetList<Text>(find.descendant(
            of: within, matching: find.byType(Text), matchRoot: true))
        .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
        .where((t) => t.isNotEmpty)
        .join(' | ');
    /// 滚到屏幕中间再点：贴着列表顶边会被搜索框压住，贴着底边会被提示条、底栏压住。
    Future<void> reveal(Finder finder) async {
      tester
          .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first)
          .clearSnackBars();
      await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<void> shot(String name) async {
      await settle(tester, 800);
      debugPrint('R43 SHOT $name');
      await settle(tester, 1200);
    }

    HostProfile saved(String id) =>
        container.read(vaultControllerProvider).data!.hosts.firstWhere((h) => h.id == id);

    Future<List<String>> openMenu(String hostId) async {
      await reveal(key('vault-host-menu-$hostId'));
      await tester.tap(key('vault-host-menu-$hostId'));
      final items = find.byWidgetPredicate((w) =>
          w is ListTile &&
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('host-menu-'));
      await waitFor(tester, () => items.evaluate().isNotEmpty, what: '⋮ 菜单');
      await settle(tester);
      return [
        for (final e in items.evaluate())
          (e.widget.key! as ValueKey<String>).value.substring('host-menu-'.length),
      ];
    }

    Future<void> closeSheet() async {
      await tester.tapAt(const Offset(20, 60));
      await settle(tester);
    }

    // ---- 两个来源：Home 存了 OAuth client（能直接刷新），Work 只用 token 读过一次 ----
    const home = 'ts-r43home';
    const work = 'ts-r43work';
    await catalog.addSource(catalogId: home, label: 'Home');
    await catalog.addSource(catalogId: work, label: 'Work');
    final homeRead = await catalog.refreshWithOAuthClient(
      home,
      const OAuthClientCredential(clientId: 'r43-client', clientSecret: 'r43-not-a-secret'),
      persist: true,
    );
    expect(homeRead.error, isNull);
    expect(homeRead.persistRefusal, isNull, reason: '假服务器回报只有 devices:core:read，应该存下');
    expect((await catalog.refreshWithToken(work, 'r43-token')).error, isNull);
    await overview.reload();
    await settle(tester, 1000);
    expect(key('vault-catalog-$home'), findsOneWidget);
    expect(key('vault-catalog-$work'), findsOneWidget);
    report('groups.home', texts(key('vault-catalog-toggle-$home')));
    report('groups.work', texts(key('vault-catalog-toggle-$work')));
    for (final source in [home, work]) {
      for (final id in ['2001', '2002', '2003']) {
        report('device.$source.$id',
            texts(key('vault-catalog-device-$source-$id')));
      }
    }
    final sections = key('vault-catalog-sections');
    expect(find.descendant(of: sections, matching: find.textContaining('在线')),
        findsNothing);
    expect(find.descendant(of: sections, matching: find.textContaining('离线')),
        findsNothing);
    await shot('01-two-sources');

    // ---- 没导入的设备点了走导入页，不连接；两个来源的同一台各导一次，各用各的账号 ----
    Future<HostProfile> importDevice(String source, String user) async {
      final row = key('vault-catalog-device-$source-2001');
      await reveal(row);
      await tester.tap(row);
      await waitFor(tester, () => find.byType(CatalogImportPage).evaluate().isNotEmpty,
          what: '导入页');
      await settle(tester);
      report('import.$source.sessions', controller.state.sessions.length);
      expect(controller.state.sessions, isEmpty, reason: '点设备只开导入页，不连');
      await tester.enterText(key('catalog-import-username'), user);
      await tester.enterText(key('catalog-import-port'), '${config['port']}');
      await settle(tester);
      if (source == home) await shot('02-import-page');
      await tester.tap(key('catalog-import-confirm'));
      await waitFor(tester, () => find.byType(CatalogImportPage).evaluate().isEmpty,
          what: '导入完成');
      await settle(tester);
      return container.read(vaultControllerProvider).data!.hosts.singleWhere((h) =>
          CatalogBinding.of(h)?.catalogId == source &&
          CatalogBinding.of(h)?.deviceId == '2001');
    }

    final homeHost = await importDevice(home, '${config['user']}');
    final workHost = await importDevice(work, 'r43-other');
    report('hosts', '${homeHost.label}=${homeHost.username}@${homeHost.hostname}:${homeHost.port} '
        '${workHost.label}=${workHost.username}@${workHost.hostname}:${workHost.port}');
    expect(homeHost.id, isNot(workHost.id));
    expect(homeHost.hostname, workHost.hostname, reason: '同 IP 也是两台主机');
    // 导入不收密码；像用户那样去编辑器填，这里直接写进保险库。顺手把别名改成中文。
    await vault.updateHost(homeHost.id, (h) => HostProfile({
          ...h.data,
          'label': '家里 edge',
          'password': config['password'],
          'authMethod': 'password',
        }));
    await vault.updateHost(
        workHost.id, (h) => HostProfile({...h.data, 'label': '公司 edge'}));
    await settle(tester, 800);
    expect(find.descendant(of: key('vault-catalog-$home'), matching: find.text('家里 edge')),
        findsOneWidget);
    expect(find.descendant(of: key('vault-catalog-$work'), matching: find.text('公司 edge')),
        findsOneWidget);
    report('type.ssh', key('host-type-ssh').evaluate().length);
    report('status.home', texts(key('vault-catalog-status-${homeHost.id}')));
    report('status.work', texts(key('vault-catalog-status-${workHost.id}')));
    await shot('03-imported');

    // ---- ⋮ 菜单：没连着时没有转发 / 文件 / 监控 ----
    final idle = await openMenu(homeHost.id);
    report('menu.idle', idle.join(','));
    expect(idle, isNot(contains('portForward')));
    expect(idle, containsAll(['testConnection', 'edit', 'hide']));
    final mosh = await controller.otherTransportFor(saved(homeHost.id));
    report('menu.idle.otherTransport', mosh?.name);
    expect(idle.contains('connectOther'), mosh != null,
        reason: '「用 Mosh 连接」只在真能换时出现');
    await shot('04-menu-idle');
    await closeSheet();

    // ---- 连上 Home 那台：它的菜单多出转发 / 文件 / 监控；同 IP 的 Work 那台没有 ----
    expect(
        await controller.connect(saved(homeHost.id),
            (_, __, fingerprint) async => fingerprint == config['fingerprint']),
        isTrue);
    final shell = controller.state.sessions.single;
    await waitFor(tester, () => shell.terminal.allText().contains(r'$'), what: '远端提示符');
    container.read(homeTabProvider.notifier).state = 0;
    await settle(tester, 1000);
    final connected = await openMenu(homeHost.id);
    report('menu.connected', connected.join(','));
    expect(connected, containsAll(['portForward', 'files', 'monitor']));
    await shot('05-menu-connected');
    await tester.tap(key('host-menu-portForward'));
    await waitFor(tester, () => find.byType(PortForwardSheet).evaluate().isNotEmpty,
        what: '端口转发');
    await shot('06-port-forward');
    await closeSheet();

    // 文件：切到文件页，左栏就是这台主机连着的那条 SSH（不另开连接、不切终端标签）。
    await openMenu(homeHost.id);
    await tester.tap(key('host-menu-files'));
    await waitFor(tester, () => container.read(homeTabProvider) == 2, what: '切到文件页');
    await waitFor(tester, () => container.read(sftpNavigationRequestProvider) == null,
        what: '文件页接住请求');
    await settle(tester, 2000);
    final pane = texts(key('sftp-left-pane'));
    report('files.leftPane', pane.split(' | ').take(8).join(' | '));
    expect(pane, contains('家里 edge'));
    expect(controller.state.sessions, hasLength(1), reason: '用的是已有的 SSH，没有另开');
    await shot('06b-files');
    container.read(homeTabProvider.notifier).state = 0;
    await settle(tester, 1000);

    // 性能监控：同一条 SSH。
    await openMenu(homeHost.id);
    await tester.tap(key('host-menu-monitor'));
    await waitFor(tester, () => find.byType(ServerMonitorSheet).evaluate().isNotEmpty,
        what: '性能监控');
    await settle(tester, 3000);
    await shot('06c-monitor');
    await closeSheet();

    // 测试连接：和编辑器里的一样弹指纹确认（上面 connect 用的是测试自己的核对，没记住）。
    // 框里的指纹先和测试环境的对上再点接受。
    await openMenu(homeHost.id);
    await tester.tap(key('host-menu-testConnection'));
    final accept = find.text('接受并记住');
    await waitFor(tester,
        () => accept.evaluate().isNotEmpty || key('probe-succeeded').evaluate().isNotEmpty,
        timeout: const Duration(seconds: 40), what: '指纹确认或测试结果');
    if (accept.evaluate().isNotEmpty) {
      final shown = tester
          .widget<SelectableText>(find.descendant(
              of: find.byType(AlertDialog), matching: find.byType(SelectableText)))
          .data!;
      expect(shown, contains('${config['fingerprint']}'));
      report('probe.fingerprintMatches', true);
      await tester.tap(accept);
    }
    await waitFor(tester,
        () => key('probe-succeeded').evaluate().isNotEmpty ||
            key('probe-failed').evaluate().isNotEmpty,
        timeout: const Duration(seconds: 40), what: '测试连接结果');
    report('probe.succeeded', key('probe-succeeded').evaluate().isNotEmpty);
    expect(key('probe-succeeded'), findsOneWidget);
    expect(controller.state.sessions, hasLength(1), reason: '测试连接不开标签');
    await shot('06d-probe');
    await closeSheet();

    final other = await openMenu(workHost.id);
    report('menu.work', other.join(','));
    expect(other, isNot(contains('portForward')),
        reason: '同名同 IP 的另一台主机不借用这条 SSH');
    await closeSheet();

    // ---- 刷新 Home：只在点的时候发；控制面变成未连接，SSH 照样连着；用户字段不动；Work 不动 ----
    final homeBefore = jsonDecode(jsonEncode(saved(homeHost.id).data));
    final workBefore = jsonDecode(jsonEncode(saved(workHost.id).data));
    final swapped = File('${(await getApplicationSupportDirectory()).path}/r43-swapped');
    if (swapped.existsSync()) swapped.deleteSync();
    debugPrint('R43 SWAP');
    await waitFor(tester, swapped.existsSync, what: '驱动脚本换设备列表');
    await reveal(key('vault-catalog-refresh-$home'));
    await tester.tap(key('vault-catalog-refresh-$home'));
    await tester.pump(const Duration(milliseconds: 30));
    report('refresh.spinner', key('vault-catalog-refresh-$home').evaluate().isEmpty);
    await waitFor(tester, () => key('vault-catalog-refresh-$home').evaluate().isNotEmpty,
        what: '刷新结束');
    await settle(tester, 800);
    report('refresh.home', texts(key('vault-catalog-toggle-$home')));
    report('refresh.status.home', texts(key('vault-catalog-status-${homeHost.id}')));
    report('refresh.status.work', texts(key('vault-catalog-status-${workHost.id}')));
    report('refresh.ssh.connected', shell.connected);
    expect(shell.connected, isTrue);
    final homeAfter = jsonDecode(jsonEncode(saved(homeHost.id).data));
    for (final field in ['label', 'username', 'port', 'hostname', 'password', 'authMethod']) {
      expect((homeAfter as Map)[field], (homeBefore as Map)[field], reason: field);
    }
    expect(jsonDecode(jsonEncode(saved(workHost.id).data)), workBefore);
    expect(texts(key('vault-catalog-status-${homeHost.id}')), contains('未连接'));
    expect(texts(key('vault-catalog-status-${workHost.id}')), contains('已连接'),
        reason: 'Work 没刷新，还是它自己缓存里的说法');
    await shot('07-after-refresh');

    // ---- 收起一组只影响显示 ----
    await reveal(key('vault-catalog-toggle-$work'));
    await tester.tap(key('vault-catalog-toggle-$work'));
    await settle(tester);
    report('collapse.workHostVisible',
        key('vault-catalog-host-${workHost.id}').evaluate().isNotEmpty);
    expect(key('vault-catalog-host-${workHost.id}'), findsNothing);
    expect(shell.connected, isTrue);
    await tester.tap(key('vault-catalog-toggle-$work'));
    await settle(tester);

    // ---- 隐藏 Work 那台，底部能找回来 ----
    await openMenu(workHost.id);
    await tester.tap(key('host-menu-hide'));
    await settle(tester, 1000);
    expect(key('vault-catalog-host-${workHost.id}'), findsNothing);
    expect(key('vault-catalog-device-$work-2001'), findsNothing,
        reason: '藏起来的主机对应的设备不变成「没导入」');
    await reveal(key('vault-show-hidden'));
    report('hidden.footer', texts(key('vault-show-hidden')));
    await shot('08-hidden');
    await tester.tap(key('vault-show-hidden'));
    await settle(tester);
    expect(key('vault-hidden-host-${workHost.id}'), findsOneWidget);
    await openMenu(workHost.id);
    await tester.tap(key('host-menu-unhide'));
    await settle(tester, 1000);
    expect(saved(workHost.id).hidden, isFalse);

    // ---- 移除 Home 来源：它的主机回到普通列表，正连着的 SSH 不断 ----
    await reveal(key('vault-catalog-settings-$home'));
    await tester.tap(key('vault-catalog-settings-$home'));
    await waitFor(tester, () => find.byType(CatalogSourceScreen).evaluate().isNotEmpty,
        what: '来源页');
    await settle(tester);
    await tester.tap(find.descendant(
        of: find.byType(CatalogSourceScreen),
        matching: find.byType(PopupMenuButton<String>)));
    await settle(tester);
    await tester.tap(find.text('移除这个来源'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, '移除来源'));
    await waitFor(tester, () => find.byType(CatalogSourceScreen).evaluate().isEmpty,
        what: '回到主机列表');
    await settle(tester, 1000);
    expect(key('vault-catalog-$home'), findsNothing);
    expect(key('vault-catalog-host-${homeHost.id}'), findsNothing);
    expect(key('vault-host-menu-${homeHost.id}'), findsOneWidget, reason: '回到普通列表');
    expect(CatalogBinding.of(saved(homeHost.id))?.catalogId, home, reason: '关联留着');
    report('remove.ssh.connected', shell.connected);
    expect(shell.connected, isTrue);
    controller.typeInto(shell.id, 'echo R43-$home-ALIVE\r');
    await waitFor(tester,
        () => 'R43-$home-ALIVE'.allMatches(shell.terminal.allText()).length >= 2,
        what: '移除来源后终端还能用');
    report('remove.ssh.echo', true);
    await shot('09-after-remove');

    await controller.close(0);
    await settle(tester, 800);
    await catalog.removeSource(work);
  }, skip: skip != false, timeout: const Timeout(Duration(minutes: 6)));
}
