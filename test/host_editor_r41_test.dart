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

  testWidgets('高级：填过的组展开，没填的写「自动」，和默认值一样的不预填', (tester) async {
    await open(tester,
        host: ssh({
          'keepaliveInterval': 10,
          'sshTcpConnectTimeoutSeconds': 25,
          'startupCommand': 'uptime',
        }));
    await reveal(tester, key('advanced-startup'));
    expect(
        tester
            .widget<Text>(find.descendant(
                of: key('advanced-timeouts-state'),
                matching: find.byType(Text)))
            .data,
        '已填写');
    expect(find.text('25'), findsOneWidget);
    expect(find.text('uptime'), findsOneWidget);
    final keepalive = tester.widget<TextField>(find.descendant(
        of: field('Keepalive 间隔'), matching: find.byType(TextField)));
    expect(keepalive.controller!.text, isEmpty, reason: '等于默认值就不预填');
    expect(find.text('自动（10）'), findsOneWidget, reason: '空的字段没聚焦也写「自动」');
  });

  testWidgets('新建主机：高级全收起、都是「自动」；不动它们保存的仍是原来的默认值', (tester) async {
    await open(tester);
    await tester.enterText(field('名称'), 'web');
    await tester.enterText(field('主机名 / IP'), 'web.example.com');
    await tester.enterText(field('用户名'), 'deploy');
    await reveal(tester, key('advanced-startup'));
    expect(find.text('Keepalive 间隔'), findsNothing, reason: '收起的组不显示字段');
    for (final group in ['timeouts', 'startup']) {
      expect(
          tester
              .widget<Text>(find.descendant(
                  of: key('advanced-$group-state'),
                  matching: find.byType(Text)))
              .data,
          '自动');
    }
    // 底部栏固定在屏幕上：滚到哪里都点得到保存。
    await tester.tap(key('host-editor-save'));
    await tester.pumpAndSettle();
    expect(result!.data['keepaliveInterval'], 10);
    expect(result!.data['sshTcpConnectTimeoutSeconds'], 15);
    expect(result!.data['sshAuthReadyTimeoutSeconds'], 30);
  });

  testWidgets('收起的组里有写错的值：保存时自己展开、红字看得见、不保存', (tester) async {
    await open(tester, host: ssh({'protocol': 'mosh', moshLocaleKey: 'en_US'}));
    await reveal(tester, key('advanced-mosh'));
    expect(find.text('en_US'), findsOneWidget, reason: '填过值的组默认展开');
    await tester.tap(key('advanced-mosh'));
    await tester.pumpAndSettle();
    expect(find.text('en_US'), findsNothing);
    await tester.tap(key('host-editor-save'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.textContaining('Mosh locale 写得不对'), findsOneWidget);
  });

  testWidgets('验证状态：测试连接真跑通才「已验证」；改端口、认证回到未验证；改名称不影响', (tester) async {
    await open(tester, host: ssh());
    expect(status(tester), startsWith('未验证：点「测试连接」'));

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
    expect(status(tester), startsWith('未验证：测试通过后改了'));
    await tester.enterText(field('SSH 端口'), '22');
    await tester.pump();
    expect(status(tester), startsWith('已验证'), reason: '和测试时完全一样的配置');

    await tester.tap(key('ssh-login-mode'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('密码').last);
    await tester.pumpAndSettle();
    expect(status(tester), startsWith('未验证：测试通过后改了'));
  });

  testWidgets('Mosh 主机没有测试连接，状态说明要连接时才验证；建议指到终端里的切换（R42），不说切网不断', (tester) async {
    await open(tester, host: ssh({'protocol': 'mosh'}));
    expect(key('test-connection'), findsNothing);
    expect(status(tester), contains('Mosh 要真正连接时才验证'));
    await reveal(tester, key('protocol-advice'));
    final advice = tester.widget<Text>(find.descendant(
        of: key('protocol-advice'), matching: find.byType(Text)));
    expect(advice.data, contains('能切到 Mosh'));
    expect(advice.data, isNot(contains('漫游')));
    expect(advice.data, isNot(contains('切网不断')));
  });

  testWidgets('tmux 说明：SSH 写清普通 shell 重连是新 shell、去哪里选 tmux；不提按名字自动附着',
      (tester) async {
    await open(tester, host: ssh());
    await reveal(tester, key('advanced-tmux'));
    expect(
        tester
            .widget<Text>(find.descendant(
                of: key('advanced-tmux-state'), matching: find.byType(Text)))
            .data,
        '普通 shell');
    await tester.tap(key('advanced-tmux'));
    await tester.pumpAndSettle();
    final note = tester
        .widgetList<Text>(find.descendant(
            of: key('tmux-persistence-note'), matching: find.byType(Text)))
        .map((t) => t.data)
        .join('\n');
    expect(note, contains('重新连接得到的是一个新 shell，不是原来那个'));
    expect(note, contains('「系统管理 → tmux」'));
    expect(note, contains('只是这台手机上的历史'));
    expect(note, contains('不新建、不附着'));
    expect(note, isNot(contains('恢复原')));
  });

  testWidgets('tmux 说明：Mosh 主机说明直连是普通 shell、想留住程序先 SSH 附着 tmux 再切，不写测试连接', (tester) async {
    await open(tester, host: ssh({'protocol': 'mosh'}));
    await reveal(tester, key('advanced-tmux'));
    await tester.tap(key('advanced-tmux'));
    await tester.pumpAndSettle();
    final note = tester
        .widgetList<Text>(find.descendant(
            of: key('tmux-persistence-note'), matching: find.byType(Text)))
        .map((t) => t.data)
        .join('\n');
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
        contains('本 App 不会替你安装'));
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
    await reveal(tester, find.byType(ConnectionRouteEditor));
    await addRouteJump(tester, 'edge');
    expect(status(tester), startsWith('未验证：测试通过后改了'));
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
