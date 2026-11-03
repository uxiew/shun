import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/domain/plugins/mosh_route.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/tmux/tmux_protocol.dart';
import 'package:shun/presentation/widgets/connection_probe_sheet.dart';
import 'package:shun/presentation/widgets/connection_route_editor.dart';
import 'package:shun/presentation/widgets/host_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/route_editor_actions.dart';

// R41 / UX07：底部操作栏在键盘上方点得到；没保存离开要确认；高级按组折叠、没填写「自动」；
// 「已验证」只在测试连接真的成功后、且地址/端口/认证/路线没变时显示。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  HostProfile ssh([Map<String, Object?> extra = const {}]) => HostProfile({
        'id': 'h1',
        'label': 'web',
        'hostname': 'web.example.com',
        'port': 22,
        'username': 'deploy',
        'protocol': 'ssh',
        ...extra,
      });

  late _ProbeSsh probe;
  HostProfile? result;
  var closed = false;

  Future<void> open(
    WidgetTester tester, {
    HostProfile? host,
    List<HostProfile> vaultHosts = const [],
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async => null);
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    if (vaultHosts.isNotEmpty) {
      await repository.saveVault(VaultData.fromJson({
        'hosts': [for (final h in vaultHosts) h.toJson()],
      }));
    }
    probe = _ProbeSsh();
    result = null;
    closed = false;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
        sshServiceProvider.overrideWithValue(probe),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await showModalBottomSheet<HostProfile>(
                  context: context,
                  isScrollControlled: true,
                  enableDrag: false,
                  builder: (_) => HostEditor(
                    host: host,
                    verifyHostKey: (h, a, f) async => true,
                  ),
                );
                closed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.widgetWithText(TextFormField, label);
  Finder key(String value) => find.byKey(ValueKey(value));
  String status(WidgetTester tester) => tester
      .widget<Text>(find.descendant(
          of: key('host-editor-verification'), matching: find.byType(Text)))
      .data!;

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
  }

  /// 点开高级某组组名旁的 ⓘ，返回弹层里的字，再关掉弹层。
  Future<String> groupHint(WidgetTester tester, String group) async {
    await reveal(tester, key('advanced-$group'));
    await tester.tap(find.descendant(
        of: key('advanced-$group'), matching: find.byIcon(Icons.info_outline)));
    await tester.pumpAndSettle();
    final text = tester
        .widgetList<Text>(find.descendant(
            of: find.byType(BottomSheet), matching: find.byType(Text)))
        .map((t) => t.data)
        .join('\n');
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    return text;
  }

  testWidgets('新建页没动手不报错；点过保存才标红，填好了红字马上消失', (tester) async {
    await open(tester);
    expect(find.text('必填'), findsNothing);
    expect(status(tester), '未验证');
    // 路线编辑器收在高级里，先打开再看，不然这两条怎么都过。
    await openRouteEditor(tester);
    await reveal(tester, key('route-legs'));
    expect(key('route-preview-error'), findsNothing,
        reason: '还没填地址，路线算不出来不是用户的错');
    expect(find.text('路线草稿（尚未通过校验）'), findsNothing);
    expect(find.text('2. 目标'), findsOneWidget, reason: '不画「2. @:22」这种半截东西');
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
    await tester.pumpAndSettle();

    await tester.tap(key('host-editor-save'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.text('必填'), findsNWidgets(2), reason: '名称可以不填，只有地址和用户名必填');
    expect(status(tester), '按上面红字改好才能保存');

    // 以前点过一次保存，「必填」会一直挂着，填好了也不走。
    await reveal(tester, field('主机名 / IP'));
    await tester.enterText(field('主机名 / IP'), 'web.example.com');
    await tester.enterText(field('用户名'), 'deploy');
    await tester.pumpAndSettle();
    expect(find.text('必填'), findsNothing);
    expect(status(tester), '未验证');
  });

  testWidgets('键盘弹出时底部栏在键盘上方，点得到保存', (tester) async {
    await open(tester);
    await tester.enterText(field('名称'), 'web');
    await tester.enterText(field('主机名 / IP'), 'web.example.com');
    await tester.enterText(field('用户名'), 'deploy');
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    final save = tester.getRect(key('host-editor-save'));
    expect(save.bottom, lessThanOrEqualTo(844 - 300));
    expect(tester.getRect(key('host-editor-cancel')).bottom,
        lessThanOrEqualTo(844 - 300));
    await tester.tap(key('host-editor-save'));
    await tester.pumpAndSettle();
    expect(result?.hostname, 'web.example.com');
  });

  testWidgets('没改动直接关；改了先问，继续编辑留在原处，放弃才关', (tester) async {
    await open(tester, host: ssh());
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.byType(HostEditor), findsNothing, reason: '没改动不弹确认');
    expect(closed, isTrue);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(field('名称'), 'web-renamed');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('放弃没保存的改动？'), findsOneWidget);
    await tester.tap(key('host-editor-keep-editing'));
    await tester.pumpAndSettle();
    expect(find.byType(HostEditor), findsOneWidget);
    expect(find.text('web-renamed'), findsOneWidget);

    // 系统返回键同样要问。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('放弃没保存的改动？'), findsOneWidget);
    await tester.tap(key('host-editor-keep-editing'));
    await tester.pumpAndSettle();
    expect(find.byType(HostEditor), findsOneWidget);

    await tester.tap(key('host-editor-cancel'));
    await tester.pumpAndSettle();
    await tester.tap(key('host-editor-discard'));
    await tester.pumpAndSettle();
    expect(find.byType(HostEditor), findsNothing);
    expect(result, isNull, reason: '放弃的改动不保存');
  });

  testWidgets('新建主机一个字没填：关、系统返回都不问（R25）', (tester) async {
    await open(tester);
    // 以前新建主机的创建时间每次拼草稿都取当前时间，过了 1 毫秒就算「改过」。
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('放弃没保存的改动？'), findsNothing);
    expect(find.byType(HostEditor), findsNothing);
    expect(closed, isTrue);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('放弃没保存的改动？'), findsNothing);
    expect(find.byType(HostEditor), findsNothing);
  });

  testWidgets('高级摊平：点开就看到全部；和默认值一样的不预填，空的写「自动」', (tester) async {
    await open(tester,
        host: ssh({
          'keepaliveInterval': 10,
          'sshTcpConnectTimeoutSeconds': 25,
          'startupCommand': 'uptime',
        }));
    await openAdvanced(tester);
    await reveal(tester, key('advanced-organize'));
    expect(find.text('25'), findsOneWidget);
    expect(find.text('uptime'), findsOneWidget);
    final keepalive = tester.widget<TextField>(find.descendant(
        of: field('Keepalive 间隔'), matching: find.byType(TextField)));
    expect(keepalive.controller!.text, isEmpty, reason: '等于默认值就不预填');
    expect(find.text('自动（10）'), findsOneWidget, reason: '空的字段没聚焦也写「自动」');
  });

  testWidgets('新建主机：高级收着；不动它们保存的仍是原来的默认值', (tester) async {
    await open(tester);
    await tester.enterText(field('名称'), 'web');
    await tester.enterText(field('主机名 / IP'), 'web.example.com');
    await tester.enterText(field('用户名'), 'deploy');
    await openAdvanced(tester);
    await reveal(tester, key('advanced-organize'));
    expect(
        tester
            .widget<Text>(find.descendant(
                of: key('advanced-route-state'), matching: find.byType(Text)))
            .data,
        '直连');
    // 底部栏固定在屏幕上：滚到哪里都点得到保存。
    await tester.tap(key('host-editor-save'));
    await tester.pumpAndSettle();
    expect(result!.data['keepaliveInterval'], 10);
    expect(result!.data['sshTcpConnectTimeoutSeconds'], 15);
    expect(result!.data['sshAuthReadyTimeoutSeconds'], 30);
  });

  testWidgets('高级各块：说明和字段用法在块名旁 ⓘ 里，页面上只有字段', (tester) async {
    await open(tester, host: ssh({'protocol': 'mosh'}));
    await openAdvanced(tester);
    final mosh = await groupHint(tester, 'mosh');
    expect(mosh, contains('mosh-server 路径：留空就先按 PATH 找'));
    expect(mosh, contains('Mosh UDP 端口范围：mosh-server 只在这个范围里挑 UDP 端口'));
    expect(mosh, contains('Mosh locale：留空用 en_US.UTF-8'));
    expect(find.byKey(const ValueKey('mosh-ports')), findsOneWidget);
    expect(find.textContaining('留空就先按 PATH 找'), findsNothing,
        reason: '输入框下面不再挂说明');
    expect(find.textContaining('建议留空让 App 自动处理'), findsNothing);
    final timeouts = await groupHint(tester, 'timeouts');
    expect(timeouts, contains('只管启动 mosh-server 前那段 SSH 登录'),
        reason: 'Mosh 主机的超时说明要写清只管 SSH 那段');
    expect(timeouts, contains('认证超时：SSH 身份认证的最长等待时间'));
  });

  testWidgets('高级收着时有写错的值：保存时自己打开、红字看得见、不保存', (tester) async {
    await open(tester, host: ssh({'protocol': 'mosh', moshLocaleKey: 'en_US'}));
    expect(find.text('en_US'), findsNothing, reason: '高级整块默认收起');
    await tester.tap(key('host-editor-save'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.textContaining('Mosh locale 写得不对'), findsOneWidget,
        reason: '高级收着也要自己打开，红字看得见');
  });

  testWidgets('验证状态：测试连接真跑通才「已验证」；改端口、认证回到未验证；改名称不影响', (tester) async {
    await open(tester, host: ssh());
    expect(status(tester), '未验证');

    probe.fail = true;
    await tester.tap(key('test-connection'));
    await tester.pumpAndSettle();
    Navigator.of(tester
            .element(find.byKey(const ValueKey('connection-probe-sheet'))))
        .pop();
    await tester.pumpAndSettle();
    expect(status(tester), startsWith('未验证'), reason: '失败不算验证');

    probe.fail = false;
    await tester.tap(key('test-connection'));
    await tester.pumpAndSettle();
    expect(key('probe-succeeded'), findsOneWidget);
    Navigator.of(tester
            .element(find.byKey(const ValueKey('connection-probe-sheet'))))
        .pop();
    await tester.pumpAndSettle();
    expect(status(tester), startsWith('已验证'));
    expect(probe.probes, 2);

    await tester.enterText(field('名称'), 'web-renamed');
    await tester.pump();
    expect(status(tester), startsWith('已验证'), reason: '名称不影响能不能连上');

    await tester.enterText(field('SSH 端口'), '2222');
    await tester.pump();
    expect(status(tester), startsWith('未验证：测试后改过'));
    await tester.enterText(field('SSH 端口'), '22');
    await tester.pump();
    expect(status(tester), startsWith('已验证'), reason: '和测试时完全一样的配置');

    await tester.tap(key('login-kind-tailscale'));
    await tester.pumpAndSettle();
    expect(status(tester), startsWith('未验证：测试后改过'));
  });

  testWidgets('Mosh 主机没有测试连接，状态说明要连接时才验证；建议指到终端里的切换（R42），不说切网不断',
      (tester) async {
    await open(tester, host: ssh({'protocol': 'mosh'}));
    expect(key('test-connection'), findsNothing);
    expect(status(tester), contains('Mosh 连接时才验证'));
    // 建议收进「连接类型」旁的 ⓘ（docs/dev/ui-text.md），点开才看。
    await reveal(tester, key('protocol-advice'));
    await tester.tap(key('protocol-advice'));
    await tester.pumpAndSettle();
    final advice = tester.widget<Text>(find.textContaining('能切到 Mosh'));
    expect(advice.data, isNot(contains('漫游')));
    expect(advice.data, isNot(contains('切网不断')));
  });

  testWidgets('Mosh 主机：怎么连、要装什么在「连接类型」的 ⓘ 里，页面上不常驻', (tester) async {
    await open(tester, host: ssh({'protocol': 'mosh'}));
    expect(find.textContaining('改由 Mosh 插件经 UDP 直连'), findsNothing);
    await tester.tap(key('protocol-advice'));
    await tester.pumpAndSettle();
    Finder inSheet(String text) => find.descendant(
        of: find.byType(BottomSheet), matching: find.textContaining(text));
    expect(inSheet('改由 Mosh 插件经 UDP 直连'), findsOneWidget);
    expect(inSheet('能切到 Mosh'), findsOneWidget);
  });

  /// 点开「连接类型」旁的 ⓘ，返回弹层里的字，再关掉弹层。
  Future<String> typeHint(WidgetTester tester) async {
    await tester.tap(key('protocol-advice'));
    await tester.pumpAndSettle();
    final text = tester
        .widgetList<Text>(find.descendant(
            of: find.byType(BottomSheet), matching: find.byType(Text)))
        .map((t) => t.data)
        .join('\n');
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    return text;
  }

  testWidgets('tmux 说明：SSH 写清普通 shell 重连是新 shell、去哪里选 tmux；不提按名字自动附着',
      (tester) async {
    await open(tester, host: ssh());
    final note = await typeHint(tester);
    expect(note, contains('重新连接得到的是一个新 shell，不是原来那个'));
    expect(note, contains('「性能监控 → tmux」'));
    expect(note, contains('只是这台手机上的历史'));
    expect(note, contains('不新建、不附着'));
    expect(note, isNot(contains('恢复原')));
  });

  testWidgets('tmux 说明：Mosh 主机说明直连是普通 shell、想留住程序先 SSH 附着 tmux 再切，不写测试连接',
      (tester) async {
    await open(tester, host: ssh({'protocol': 'mosh'}));
    final note = await typeHint(tester);
    expect(note, contains('开的是 mosh-server 里的普通 shell'));
    expect(note, contains('接不回原来那个'));
    expect(note, contains('还是同一个 tmux 会话'));
    expect(note, isNot(contains('测试连接')));
  });

  testWidgets('测试连接的结果里单独一块写 tmux：远端没有就说没有、不替你装', (tester) async {
    await open(tester, host: ssh());
    probe.tmux = const TmuxProbe(availability: TmuxAvailability.missing);
    await tester.tap(key('test-connection'));
    await tester.pumpAndSettle();
    expect(key('probe-succeeded'), findsOneWidget);
    expect(
        find.descendant(
            of: key('probe-tmux'), matching: find.textContaining('远端没有 tmux')),
        findsOneWidget);
  });

  test('describeProbeTmux：每种情况都说清楚，查失败不算测试连接失败；Telnet 没有这一项', () {
    ProbeOutcome with_(TmuxAvailability a,
            {List<TmuxSessionRow> sessions = const [], String? problem}) =>
        ProbeOutcome(
          tty: '/dev/pts/1',
          tmux: TmuxProbe(
              availability: a,
              versionLine: 'tmux 3.5a',
              sessions: sessions,
              problem: problem),
        );
    expect(describeProbeTmux(const ProbeOutcome(tty: null)), isNull);
    expect(describeProbeTmux(with_(TmuxAvailability.missing)),
        contains('App 不会替你装'));
    expect(describeProbeTmux(with_(TmuxAvailability.unsupported)),
        contains('tmux 3.5a 不在本 App 实测过的版本里'));
    expect(
        describeProbeTmux(with_(TmuxAvailability.noServer)), contains('还没有会话'));
    expect(describeProbeTmux(with_(TmuxAvailability.failed, problem: '输出自相矛盾')),
        endsWith('没读出来：输出自相矛盾'));
    expect(
        describeProbeTmux(
            const ProbeOutcome(tty: '/dev/pts/1', tmuxProblem: 'exec 被拒绝')),
        allOf(contains('SSH 和终端都通了'), endsWith('exec 被拒绝')));
  });

  testWidgets('验证状态：测试通过后改路线（加一台跳板）立即回到未验证', (tester) async {
    final edge = HostProfile({
      'id': 'edge',
      'label': 'edge',
      'hostname': 'edge.example.com',
      'port': 22,
      'username': 'ops',
      'protocol': 'ssh',
    });
    await open(tester, host: ssh(), vaultHosts: [edge]);
    await tester.tap(key('test-connection'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(key('connection-probe-sheet'))).pop();
    await tester.pumpAndSettle();
    expect(status(tester), startsWith('已验证'));
    await addRouteJump(tester, 'edge');
    expect(status(tester), startsWith('未验证：测试后改过'));
  });

  testWidgets('新建首屏：类型、地址、认证、名称、分组；路径、超时、标签收在高级里', (tester) async {
    await open(tester);
    Finder onScreen(Finder finder) => finder.hitTestable();
    for (final label in ['主机名 / IP', 'SSH 端口', '用户名', '密码（可选）', '名称']) {
      expect(onScreen(field(label)), findsOneWidget, reason: '$label 要在首屏');
    }
    expect(onScreen(key('host-protocol')), findsOneWidget);
    expect(onScreen(key('advanced-all')), findsOneWidget, reason: '不用滚动就能看到高级');
    expect(onScreen(key('host-group')), findsOneWidget);
    expect(field('标签（逗号分隔）'), findsNothing);
    expect(find.byType(ConnectionRouteEditor), findsNothing);
    expect(key('advanced-route'), findsNothing);
    expect(key('advanced-timeouts'), findsNothing);
    expect(find.text('连接路径、启动命令、超时等'), findsOneWidget);
  });

  testWidgets('点开高级自己滚到它：内容不能全压在底栏下面，看着像没反应', (tester) async {
    await open(tester);
    await tester.tap(key('advanced-all'));
    await tester.pumpAndSettle();
    final bar = tester.getTopLeft(key('host-editor-verification')).dy;
    expect(tester.getTopLeft(key('advanced-route')).dy, lessThan(bar));
  });

  testWidgets('F39：名称留空就用地址，地址也空时不让存', (tester) async {
    await open(tester);
    await tester.enterText(field('主机名 / IP'), 'web.example.com');
    await tester.enterText(field('用户名'), 'deploy');
    await tester.pump();
    await tester.tap(key('host-editor-save'));
    await tester.pumpAndSettle();
    expect(result!.label, 'web.example.com');
  });

  testWidgets('F39：高级收着时写明设过什么，不用点开就知道走不走代理', (tester) async {
    await open(tester,
        host: ssh({
          'proxyConfig': {'type': 'socks5', 'host': '127.0.0.1', 'port': 1080},
          'startupCommand': 'uptime',
          'tags': ['db'],
        }));
    expect(find.byType(ConnectionRouteEditor), findsNothing, reason: '编辑也是收着的');
    expect(find.text('代理 · 启动命令 · 标签和置顶'), findsOneWidget);
    await openAdvanced(tester);
    expect(find.byType(ConnectionRouteEditor), findsOneWidget,
        reason: '点开高级就全看得到');
    expect(find.text('uptime'), findsOneWidget);
  });

  testWidgets('F39：地址写错时红字在地址下面，不用去高级里找；路线组开着就不说两遍', (tester) async {
    await open(tester);
    await tester.enterText(field('主机名 / IP'), 'bad host');
    await tester.pump();
    expect(key('host-editor-route-error'), findsOneWidget);
    expect(status(tester), '按上面红字改好才能保存');
    expect(find.byType(ConnectionRouteEditor), findsNothing,
        reason: '路线是直连，没必要打开高级');
    await openRouteEditor(tester);
    expect(key('host-editor-route-error'), findsNothing);
    expect(key('route-preview-error'), findsOneWidget);
  });

  testWidgets('F39：配了代理的主机换成 Mosh，路线自己摆出来说明为什么存不了', (tester) async {
    await open(tester,
        host: ssh({
          'proxyConfig': {'type': 'socks5', 'host': '127.0.0.1', 'port': 1080},
        }));
    expect(find.byType(ConnectionRouteEditor), findsNothing);
    await chooseConnectionType(tester, 'Mosh');
    expect(find.byType(ConnectionRouteEditor), findsOneWidget);
    expect(key('route-preview-error'), findsOneWidget);
    expect(key('host-editor-route-error'), findsNothing);
  });

  testWidgets('F31：选密码时下面只有用户名和密码两个框', (tester) async {
    await open(tester, host: ssh({'password': 'pw'}));
    expect(field('密码（可选）'), findsOneWidget);
    expect(key('host-key'), findsNothing, reason: '选了密码就不摆密钥');
  });
}

/// 只替换「测试连接」：按 [fail] 成功或失败，记次数。不碰网络。
class _ProbeSsh extends SshService {
  var fail = false;
  var probes = 0;
  TmuxProbe? tmux;

  @override
  Future<ProbeOutcome> probe({
    required HostProfile host,
    List<HostProfile> hosts = const [],
    List<SshKeyProfile> keys = const [],
    List<Map<String, dynamic>> identities = const [],
    List<ProxyProfile> proxyProfiles = const [],
    RoutePlan? routePlan,
    required HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
    required ConnectionAttempt attempt,
  }) async {
    probes++;
    await Future<void>.delayed(Duration.zero);
    if (fail) throw StateError('登录被拒绝');
    return ProbeOutcome(tty: '/dev/pts/1', tmux: tmux);
  }
}
