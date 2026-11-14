import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/connection_events.dart';
import 'package:shun/domain/host_summary.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/tailscale_ssh.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/screens/vault_screen.dart';
import 'support/prism_test_host.dart';

// R25 第四部分：主机详情里的认证和路线按连接时的真实规则写，不另拼一套。
void main() {
  HostProfile host(Map<String, Object?> extra) => HostProfile({
        'id': 'web',
        'label': 'web',
        'hostname': '192.0.2.10',
        'username': 'ops',
        'port': 22,
        'protocol': 'ssh',
        ...extra,
      });
  final key = SshKeyProfile({
    'id': 'k1',
    'label': 'laptop',
    'privateKey': '-----BEGIN OPENSSH PRIVATE KEY-----',
  });

  group('describeLogin 只写登录时真会发的', () {
    test('选「密码」又挂着私钥：只写密码（登录时不发私钥）', () {
      final h = host({
        'authMethod': 'password',
        'password': 'x',
        'identityFileId': 'k1',
      });
      expect(describeLogin(h, key), '密码');
    });

    test('选「密码」没存密码：写明登录时问', () {
      expect(describeLogin(host({'authMethod': 'password'}), null),
          '密码（没保存，登录时问你）');
    });

    test('选「私钥」私钥被删：写明连接会被拒，不写成「自动」「密码」', () {
      final h = host({
        'authMethod': 'key',
        'password': 'x',
        'identityFileId': 'gone',
      });
      expect(describeLogin(h, null), '私钥（引用的私钥已不存在，连接会被拒绝）');
      expect(
          describeLogin(h.copyWith(identityFileId: 'k1'), key), '私钥“laptop”');
    });

    test('自动：按顺序列出有的', () {
      expect(
        describeLogin(host({'password': 'x', 'identityFileId': 'k1'}), key),
        '自动：先试私钥“laptop”，再试保存的密码，都不行再问你',
      );
      expect(describeLogin(host({'password': 'x'}), null), '自动：先试保存的密码，都不行再问你');
      expect(describeLogin(host({}), null), '自动（没保存私钥和密码，登录时问你）');
    });

    test('Tailscale SSH 不发密码私钥；Telnet、插件没有 SSH 登录', () {
      expect(
        describeLogin(
            host({sshLoginModeKey: 'tailscale', 'password': 'x'}), key),
        'Tailscale SSH（不发密码和私钥）',
      );
      expect(describeLogin(host({'protocol': 'telnet'}), null), isNull);
      expect(describeLogin(host({'protocol': 'plugin'}), null), isNull);
    });
  });

  group('hostRouteStatus 和连接时算的一样', () {
    test('引用的代理、跳板被删：报错，不当成直连', () {
      final proxy = hostRouteStatus(host({'proxyProfileId': 'gone'}),
          hosts: const [], proxyProfiles: const []);
      expect(proxy.plan, isNull);
      expect(proxy.error, contains('找不到代理配置'));
      final jump = hostRouteStatus(
          host({
            'hostChain': {
              'hostIds': ['gone']
            }
          }),
          hosts: const [],
          proxyProfiles: const []);
      expect(jump.error, contains('找不到跳板机'));
    });

    test('Mosh 配了代理：算得出路线，但给出连接时会拒的原因', () {
      final status = hostRouteStatus(
          host({
            'protocol': 'mosh',
            'proxyConfig': {
              'type': 'socks5',
              'host': '127.0.0.1',
              'port': 1080
            },
          }),
          hosts: const [],
          proxyProfiles: const []);
      expect(status.plan, isNotNull);
      expect(status.error, isNotNull);
    });

    test('配得对：有路线、没错', () {
      final status =
          hostRouteStatus(host({}), hosts: const [], proxyProfiles: const []);
      expect(status.plan, isNotNull);
      expect(status.error, isNull);
    });
  });

  group('主机详情弹窗', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    Future<void> open(
        WidgetTester tester, List<Map<String, Object?>> hosts) async {
      const channel =
          MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => null);
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      SharedPreferences.setMockInitialValues({
        'shun_vault_v1': jsonEncode({
          'hosts': hosts,
          'keys': const [],
          'snippets': const [],
          'customGroups': const [],
        }),
        'shun_settings_v1': jsonEncode({'serverViewMode': 'list'}),
      });
      final repository = await VaultRepository.open();
      final container = ProviderContainer(overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
        connectionEventStoreProvider
            .overrideWithValue(MemoryConnectionEventStore(const [])),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
            localizationsDelegates: prismTestDelegates,
            builder: prismTestBuilder,
            home: Scaffold(body: VaultScreen())),
      ));
      await tester.pumpAndSettle();
    }

    Map<String, Object?> row(String id, Map<String, Object?> extra) => {
          'id': id,
          'label': id,
          'hostname': '192.0.2.10',
          'username': 'ops',
          'port': 22,
          'protocol': 'ssh',
          ...extra,
        };

    testWidgets('代理配置被删：路线一行显示连接时会报的错，不显示成直连', (tester) async {
      await open(tester, [
        row('web', {'proxyProfileId': 'gone'})
      ]);
      await tester.tap(find.text('web'));
      await tester.pumpAndSettle();
      final route = find.byKey(const ValueKey('host-detail-route'));
      expect(route, findsOneWidget);
      expect(
          find.descendant(of: route, matching: find.textContaining('找不到代理配置')),
          findsOneWidget);
      expect(
          find.descendant(of: route, matching: find.text('直连')), findsNothing);
      // 路线算不出来时工具列表只会报同一句错：不给这个入口（和 ⋮ 菜单一致）。
      expect(find.byKey(const ValueKey('host-ai-cli')), findsNothing);
    });

    testWidgets('经代理：逐段列出，代理那段注明 App 看不到后面', (tester) async {
      await open(tester, [
        row('web', {
          'proxyConfig': {'type': 'socks5', 'host': '127.0.0.1', 'port': 1080},
        })
      ]);
      await tester.tap(find.text('web'));
      await tester.pumpAndSettle();
      final route = find.byKey(const ValueKey('host-detail-route'));
      expect(
          find.descendant(of: route, matching: find.textContaining('App 看不到')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('host-ai-cli')), findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('host-detail-login')),
              matching: find.text('自动（没保存私钥和密码，登录时问你）')),
          findsOneWidget);
    });

    testWidgets('Telnet：地址不带「@」，没有 SSH 认证一行', (tester) async {
      await open(tester, [
        row('old', {'protocol': 'telnet', 'port': 23, 'username': ''})
      ]);
      await tester.tap(find.text('old'));
      await tester.pumpAndSettle();
      expect(find.text('TELNET  192.0.2.10:23'), findsOneWidget);
      expect(find.byKey(const ValueKey('host-detail-login')), findsNothing);
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('host-detail-route')),
              matching: find.text('直连')),
          findsOneWidget);
    });
  });
}
