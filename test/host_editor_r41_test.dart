import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/plugins/mosh_route.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/widgets/host_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  Future<void> open(WidgetTester tester, {HostProfile? host}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async => null);
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
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

  testWidgets('Mosh 主机没有测试连接，状态说明要连接时才验证；建议不提还没做的终端内切换', (tester) async {
    await open(tester, host: ssh({'protocol': 'mosh'}));
    expect(key('test-connection'), findsNothing);
    expect(status(tester), contains('Mosh 要真正连接时才验证'));
    await reveal(tester, key('protocol-advice'));
    final advice = tester.widget<Text>(find.descendant(
        of: key('protocol-advice'), matching: find.byType(Text)));
    expect(advice.data, isNot(contains('连上后能切')));
  });
}

/// 只替换「测试连接」：按 [fail] 成功或失败，记次数。不碰网络。
class _ProbeSsh extends SshService {
  var fail = false;
  var probes = 0;

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
    return const ProbeOutcome(tty: '/dev/pts/1');
  }
}
