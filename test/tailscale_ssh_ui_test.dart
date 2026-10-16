import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/domain/tailscale_ssh.dart';
import 'package:shun/infrastructure/ssh/ssh_login_watch.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/widgets/host_editor.dart';
import 'package:shun/presentation/widgets/tailscale_check_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

// R14 界面：编辑器里明确选 Tailscale SSH；check 卡片只显示域名、只在用户点按钮时交给浏览器。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  group('编辑器：登录方式', () {
    HostProfile? result;

    Future<void> open(WidgetTester tester, {HostProfile? host}) async {
      tester.view.physicalSize = const Size(900, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorage, (call) async => null);
      SharedPreferences.setMockInitialValues({});
      final repository = await VaultRepository.open();
      await repository.saveVault(VaultData.fromJson({
        'hosts': [if (host != null) host.toJson()],
        'keys': [],
        'snippets': [],
        'customGroups': [],
      }));
      result = null;
      await tester.pumpWidget(ProviderScope(
        overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await Navigator.push<HostProfile>(
                    context,
                    MaterialPageRoute(builder: (_) => HostEditor(host: host)),
                  );
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

    Future<void> fill(WidgetTester tester, String label, String value) async {
      await tester.enterText(find.widgetWithText(TextFormField, label), value);
      await tester.pump();
    }

    testWidgets('新建主机默认普通 SSH；填 100.x 地址也不会自己变成 Tailscale SSH', (tester) async {
      await open(tester);
      await fill(tester, '名称', 'node');
      await fill(tester, '主机名 / IP', '100.101.102.103');
      await fill(tester, '用户名', 'ops');
      expect(find.byKey(const ValueKey('tailscale-login-note')), findsNothing);
      expect(find.text('认证方式'), findsOneWidget);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(result!.data.containsKey(sshLoginModeKey), isFalse);
      expect(sshLoginModeOf(result!), SshLoginMode.standard);
    });

    testWidgets('选 Tailscale SSH：密码私钥栏收起、说明来源节点；保存只多一个字段，密码和认证方式原样留着',
        (tester) async {
      final host = HostProfile({
        'id': 'h',
        'label': 'node',
        'hostname': '100.101.102.103',
        'port': 22,
        'username': 'ops',
        'protocol': 'ssh',
        'authMethod': 'key',
        'password': 'kept',
      });
      await open(tester, host: host);
      // R41：普通 SSH 的认证方式和 Tailscale SSH 并成了一个「认证方式」选择。
      await tester.tap(find.byKey(const ValueKey('ssh-login-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tailscale SSH').last);
      await tester.pumpAndSettle();
      expect(find.text('密码（可选）'), findsNothing);
      expect(find.text('SSH 私钥'), findsNothing);
      expect(
          find.byKey(const ValueKey('tailscale-login-note')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.descendant(
              of: find.byKey(const ValueKey('tailscale-source-node')),
              matching: find.byType(Text),
            ))
            .data,
        contains('这台手机'),
      );
      expect(find.text(tailscaleCatalogIsNotIdentity), findsOneWidget);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(result, isNotNull, reason: '设成私钥认证却没选私钥，在 Tailscale 模式下不拦保存');
      expect(result!.data[sshLoginModeKey], 'tailscale');
      expect(result!.data['authMethod'], 'key', reason: '桌面端认的字段不动');
      expect(result!.data['password'], 'kept');
    });

    testWidgets('经代理时，来源说明换成代理出口的节点', (tester) async {
      final host = HostProfile({
        'id': 'h',
        'label': 'node',
        'hostname': '100.101.102.103',
        'port': 22,
        'username': 'ops',
        'protocol': 'ssh',
        sshLoginModeKey: 'tailscale',
        'proxyConfig': {'type': 'socks5', 'host': '127.0.0.1', 'port': 1055},
      });
      await open(tester, host: host);
      expect(
          find.byKey(const ValueKey('tailscale-login-note')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.descendant(
              of: find.byKey(const ValueKey('tailscale-source-node')),
              matching: find.byType(Text),
            ))
            .data,
        contains('代理出口所在的节点（代理地址 127.0.0.1:1055）'),
      );
      await tester.tap(find.byKey(const ValueKey('ssh-login-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('自动（私钥 / 密码 / 交互式）').last);
      await tester.pumpAndSettle();
      expect(find.text('密码（可选）'), findsOneWidget);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(result!.data.containsKey(sshLoginModeKey), isFalse,
          reason: '改回普通 SSH 就去掉字段');
    });
  });

  group('check 卡片', () {
    TailscaleCheckPrompt prompt(String banner) => TailscaleCheckPrompt(
          hop: 0,
          hopCount: 1,
          hostLabel: 'node',
          endpoint: '100.101.102.103:22',
          sourceNode: '这台手机在 Tailscale 里的节点',
          banner: classifyAuthBanner(banner),
          deadline: DateTime(2026, 10, 1, 15, 40),
        );

    Future<List<Uri>> show(WidgetTester tester, TailscaleCheckPrompt value,
        {bool launches = true}) async {
      final launched = <Uri>[];
      await tester.pumpWidget(ProviderScope(
        overrides: [
          externalLinkLauncherProvider.overrideWithValue((uri) async {
            launched.add(uri);
            return launches;
          }),
        ],
        child: MaterialApp(
          home: Scaffold(
            body:
                SingleChildScrollView(child: TailscaleCheckCard(prompt: value)),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return launched;
    }

    testWidgets('合规链接：只显示域名，不显示 token；不点不打开，点一次交给浏览器一次', (tester) async {
      final launched = await show(
          tester,
          prompt('# Tailscale SSH requires an additional check.\n'
              '# To authenticate, visit: https://login.tailscale.com/a/abcdef123456\n'));
      expect(find.text('login.tailscale.com/a/…'), findsOneWidget);
      expect(find.textContaining('abcdef123456'), findsNothing);
      expect(find.textContaining('[link]'), findsOneWidget,
          reason: '服务器原话里链接被隐去');
      expect(launched, isEmpty, reason: '从不自动打开');
      await tester.tap(find.byKey(const ValueKey('open-check-link')));
      await tester.pumpAndSettle();
      expect(
          launched, [Uri.parse('https://login.tailscale.com/a/abcdef123456')]);
      expect(find.byKey(const ValueKey('check-link-opened')), findsOneWidget);
      expect(find.textContaining('回到 App 不代表已经通过'), findsOneWidget);
    });

    testWidgets('没有浏览器：说清楚，连接继续等', (tester) async {
      await show(
          tester,
          prompt(
              '# To authenticate, visit: https://login.tailscale.com/a/abcdef123456\n'),
          launches: false);
      await tester.tap(find.byKey(const ValueKey('open-check-link')));
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey('check-link-open-failed')), findsOneWidget);
    });

    testWidgets('不合规链接：没有打开按钮，写出原因和指向的域名', (tester) async {
      final launched = await show(
          tester,
          prompt(
              '# To authenticate, visit: https://login.tailscale.com.evil.example/a/x\n'));
      expect(find.byKey(const ValueKey('open-check-link')), findsNothing);
      expect(find.text('收到的认证链接不会打开'), findsOneWidget);
      expect(find.textContaining('域名不是 login.tailscale.com'), findsOneWidget);
      expect(find.text('login.tailscale.com.evil.example'), findsOneWidget);
      expect(launched, isEmpty);
    });
  });
}
