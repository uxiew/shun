import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/widgets/host_editor.dart';
import 'package:shun/presentation/widgets/host_address_line.dart';
import 'package:shun/presentation/widgets/host_system_icon.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/route_editor_actions.dart';

// R10 / R40 / UX01：链式编辑；实时显示按当前填写算出的路线；
// SSH 端口和代理端口分开写、分开显示；路线有矛盾时不让保存。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  HostProfile saved(String id, {Map<String, Object?> extra = const {}}) =>
      HostProfile({
        'id': id,
        'label': id,
        'hostname': '$id.example.com',
        'port': 22,
        'username': 'ops',
        'protocol': 'ssh',
        ...extra,
      });

  HostProfile? result;
  late VaultRepository repository;

  Future<void> open(
    WidgetTester tester, {
    HostProfile? host,
    bool verify = false,
    HostProtocol initialProtocol = HostProtocol.ssh,
  }) async {
    tester.view.physicalSize = const Size(900, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async => null);
    SharedPreferences.setMockInitialValues({});
    repository = await VaultRepository.open();
    await repository.saveVault(VaultData.fromJson({
      'hosts': [
        saved('edge').toJson(),
        saved('proxied-jump', extra: {
          'proxyConfig': {'type': 'socks5', 'host': '10.0.0.9', 'port': 1080},
        }).toJson(),
        if (host != null) host.toJson(),
      ],
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
                  MaterialPageRoute(
                    builder: (_) => HostEditor(
                      host: host,
                      initialProtocol: initialProtocol,
                      verifyHostKey:
                          verify ? (_, __, ___) async => false : null,
                    ),
                  ),
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

  Future<void> fillTarget(WidgetTester tester) async {
    await fill(tester, '名称', 'web');
    await fill(tester, '主机名 / IP', 'web.example.com');
    await fill(tester, '用户名', 'deploy');
    await fill(tester, 'SSH 端口', '2222');
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
  }

  String preview(WidgetTester tester) => tester
      .widgetList<Text>(find.descendant(
        of: find.byKey(const ValueKey('route-preview')),
        matching: find.byType(Text),
      ))
      .map((text) => text.data ?? '')
      .join(' | ');

  testWidgets(
      'R39 unknown type opens read-only without interpreting SSH fields',
      (tester) async {
    final opaque = saved('opaque', extra: {
      'protocol': 'future-desktop',
      'port': 'provider-specific',
      'hostChain': {'hostIds': 'opaque-format'},
      'futureOptions': {'keep': true},
    });
    await open(tester, host: opaque, verify: true);
    expect(find.text('不支持的连接类型'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
    expect(find.text('保存'), findsNothing);
    expect(find.text('测试连接'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(result, isNull);
    final stored = (await repository.loadVault())
        .hosts
        .singleWhere((h) => h.id == opaque.id);
    expect(stored.toJson(), opaque.toJson());
  });

  testWidgets('R39 unknown list display never reads opaque SSH endpoint fields',
      (tester) async {
    final host = saved('opaque', extra: {
      'protocol': 'future-desktop',
      'port': 'provider-specific',
    });
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
            home: Scaffold(
      body:
          Column(children: [HostAddressLine(host), HostSystemIcon(host: host)]),
    ))));
    expect(find.text('不支持的连接类型'), findsOneWidget);
    expect(find.byIcon(Icons.help_outline), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'R39 Telnet only requires its endpoint, not an unused SSH username',
      (tester) async {
    await open(tester, initialProtocol: HostProtocol.telnet);
    await tester.pumpAndSettle();
    await fill(tester, '名称', 'Telnet device');
    await fill(tester, '主机名 / IP', 'telnet.example');
    expect(find.widgetWithText(TextFormField, '用户名'), findsNothing);
    expect(find.widgetWithText(TextFormField, '密码（可选）'), findsNothing);
    await fill(tester, 'Telnet 端口', '0');
    await save(tester);
    expect(result, isNull);
    await fill(tester, 'Telnet 端口', '23');
    await save(tester);
    expect(result!.protocol, HostProtocol.telnet);
    expect(result!.username, isEmpty);
  });

  testWidgets('默认直连：摘要是 手机 → 目标；保存后没有代理和跳板', (tester) async {
    await open(tester);
    await fillTarget(tester);
    expect(preview(tester), contains('1. 手机'));
    expect(preview(tester), contains('2. 目标“web”'));
    expect(preview(tester), contains('SSH deploy@web.example.com:2222'));
    await save(tester);
    expect(result, isNotNull);
    expect(result!.data.containsKey('proxyConfig'), isFalse);
    expect(result!.data.containsKey('hostChain'), isFalse);
  });

  testWidgets('经代理：SSH 端口和代理端口分开填、分开显示；保存各归各', (tester) async {
    await open(tester);
    await fillTarget(tester);
    expect(find.widgetWithText(TextFormField, 'SSH 端口'), findsOneWidget);
    await createRouteProxy(tester);
    expect(find.widgetWithText(TextFormField, '代理端口'),
        findsNothing); // separate form
    expect(preview(tester), contains('2. SOCKS5 代理'));
    expect(preview(tester), contains('127.0.0.1:1080（代理之后怎么走由代理决定，App 看不到）'));
    expect(preview(tester), contains('SSH deploy@web.example.com:2222'));
    await save(tester);
    expect(result!.port, 2222);
    final config = (await repository.loadVault())
        .proxyProfiles
        .singleWhere((p) => p.id == result!.proxyProfileId)
        .config!;
    expect(config.port, 1080);
    expect(config.type, ProxyType.socks5);
    expect(result!.data.containsKey('hostChain'), isFalse);
  });

  testWidgets('代理端口填成 22、或与目标完全相同：提示可能填混了（不拦保存）', (tester) async {
    await open(tester);
    await fillTarget(tester);
    await createRouteProxy(tester, port: '22');
    expect(find.byKey(const ValueKey('route-preview-warning')), findsOneWidget);
    expect(preview(tester), contains('代理端口填的是 22'));
    await createRouteProxy(tester, host: 'web.example.com', port: '2222');
    expect(preview(tester), contains('可能把两者填混了'));
  });

  testWidgets('缺失跳板：摘要报原因，保存被拒绝', (tester) async {
    await open(tester,
        host: saved('missing-chain', extra: {
          'hostChain': {
            'hostIds': ['missing']
          }
        }));
    expect(find.byKey(const ValueKey('route-preview-error')), findsOneWidget);
    await save(tester);
    expect(result, isNull);
    expect(find.textContaining('找不到跳板机'), findsWidgets);
  });

  testWidgets('添加跳板与代理：摘要 手机 → 代理 → 跳板 → 目标；两样都保存', (tester) async {
    await open(tester);
    await fillTarget(tester);
    await addRouteJump(tester, 'edge');
    await createRouteProxy(tester);
    final text = preview(tester);
    expect(text, contains('1. 手机'));
    expect(text, contains('2. SOCKS5 代理'));
    expect(text, contains('3. 跳板机“edge”'));
    expect(text, contains('4. 目标“web”'));
    await save(tester);
    expect(result!.hostChainIds, ['edge']);
    expect(result!.proxyProfileId, isNotNull);
    expect((await repository.loadVault()).proxyProfiles.single.config!.host,
        '127.0.0.1');
  });

  testWidgets('跳板机自己带了代理：摘要说明不会隐式套用，保存被拒绝', (tester) async {
    await open(tester);
    await fillTarget(tester);
    await addRouteJump(tester, 'proxied-jump');
    expect(preview(tester), contains('自己配置了代理，经它连接时不会隐式套用'));
    await save(tester);
    expect(result, isNull);
  });

  testWidgets('从「经代理」切回「直连」：保存时真的去掉代理，不留看不见的旧设置', (tester) async {
    await open(
      tester,
      host: saved('existing', extra: {
        'proxyConfig': {'type': 'socks5', 'host': '127.0.0.1', 'port': 1080},
      }),
    );
    expect(preview(tester), contains('SOCKS5 代理'), reason: '按已有数据打开在「经代理」');
    await tester.tap(find.byKey(const ValueKey('route-clear')));
    await tester.pumpAndSettle();
    await save(tester);
    expect(result!.data.containsKey('proxyConfig'), isFalse);
    expect(result!.data.containsKey('proxyProfileId'), isFalse);
  });

  testWidgets('已有代理和跳板：直接显示完整链，不出现旧模式开关', (tester) async {
    await open(
      tester,
      host: saved('combo', extra: {
        'hostChain': {
          'hostIds': ['edge'],
        },
        'proxyConfig': {'type': 'socks5', 'host': '127.0.0.1', 'port': 1080},
      }),
    );
    expect(find.byKey(const ValueKey('entry-proxy-switch')), findsNothing);
    expect(preview(tester), contains('2. SOCKS5 代理'));
    expect(preview(tester), contains('3. 跳板机“edge”'));
  });

  testWidgets('Mosh 可以选（X09 起有插件）；Telnet 注明只能直连，保存去掉代理', (tester) async {
    await open(
      tester,
      host: saved('old-telnet', extra: {
        'protocol': 'telnet',
        'port': 23,
        'proxyConfig': {'type': 'socks5', 'host': '127.0.0.1', 'port': 1080},
      }),
    );
    final mosh = tester
        .widget<SegmentedButton<HostProtocol>>(
            find.byType(SegmentedButton<HostProtocol>))
        .segments
        .firstWhere((segment) => segment.value == HostProtocol.mosh);
    expect(mosh.enabled, isTrue);
    expect(find.byKey(const ValueKey('telnet-direct-only')), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Telnet 端口'), findsOneWidget);
    await save(tester);
    expect(result!.data.containsKey('proxyConfig'), isFalse);
  });

  group('X09 Mosh 主机', () {
    Future<void> chooseMosh(WidgetTester tester) async {
      await tester.tap(find.text('Mosh'));
      await tester.pumpAndSettle();
    }

    testWidgets('只能直连：选了代理或跳板，摘要说明原因，保存被拒绝；不会悄悄去掉代理改成直连', (tester) async {
      await open(tester);
      await fillTarget(tester);
      await chooseMosh(tester);
      expect(find.byKey(const ValueKey('mosh-note')), findsOneWidget);
      await createRouteProxy(tester, port: '1055');
      expect(preview(tester), contains('Mosh 只能直连'));
      expect(preview(tester), contains('经SOCKS5 代理 127.0.0.1:1055'));
      await save(tester);
      expect(result, isNull, reason: '存下来也连不上：保存前就拦住');

      await tapRoute(tester, find.byKey(const ValueKey('route-remove-proxy')));
      await addRouteJump(tester, 'edge');
      expect(preview(tester), contains('经跳板机 “edge”'));
      await save(tester);
      expect(result, isNull);
    });

    testWidgets('直连：摘要写明两段（SSH 启动 mosh-server、之后 UDP），端口范围存进主机；没有「测试连接」',
        (tester) async {
      await open(tester, verify: true);
      await fillTarget(tester);
      expect(find.byKey(const ValueKey('test-connection')), findsOneWidget);
      await chooseMosh(tester);
      expect(find.byKey(const ValueKey('test-connection')), findsNothing,
          reason: '测试连接只测 SSH 那段，给 Mosh 主机一个「通过」会误导');
      expect(preview(tester), contains('启动 mosh-server，之后 Mosh 会话走 UDP 直连'));
      // R41：端口范围在默认收起的「高级 → Mosh 启动参数」里。
      await tester.tap(find.byKey(const ValueKey('advanced-mosh')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('mosh-ports')), '60001:70000');
      await save(tester);
      expect(result, isNull);
      expect(find.textContaining('Mosh UDP 端口范围写得不对'), findsOneWidget);
      await tester.enterText(
          find.byKey(const ValueKey('mosh-ports')), '60101:60108');
      await save(tester);
      expect(result!.protocol, HostProtocol.mosh);
      expect(result!.data['shunMoshPorts'], '60101:60108');
    });

    testWidgets('R39 SSH/Mosh 保存并重开：保留 Mosh 选项和身份字段', (tester) async {
      await open(
        tester,
        host: saved('old-mosh', extra: {
          'protocol': 'mosh',
          'shunMoshPorts': '60001',
          'authMethod': 'password',
          'desktop-extra': {'preserve': true},
        }),
      );
      await tester.tap(find.text('SSH'));
      await tester.pumpAndSettle();
      await save(tester);
      expect(result!.protocol, HostProtocol.ssh);
      expect(result!.data['shunMoshPorts'], '60001');
      final ssh = result!;
      await open(tester, host: ssh);
      await chooseMosh(tester);
      expect(
          tester
              .widget<TextFormField>(find.byKey(const ValueKey('mosh-ports')))
              .controller!
              .text,
          '60001');
      await save(tester);
      expect(result!.protocol, HostProtocol.mosh);
      expect(result!.username, ssh.username);
      expect(result!.authMethod, ssh.authMethod);
      expect(result!.data['desktop-extra'], {'preserve': true});
    });
  });
}
