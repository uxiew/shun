import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/host_trust.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/screens/known_hosts_screen.dart';
import 'package:shun/presentation/widgets/connection_event_text.dart';

// SEC14 的页面和规则部分：列出来、删一条、删完按第一次见重新核对；页面不能改、不能加。

const acceptedAt = 1767225600000;

Map<String, dynamic> record(
  String hostname, {
  int port = 22,
  String fingerprint = 'SHA256:aaa',
}) =>
    {
      'hostname': hostname,
      'port': port,
      'keyType': 'ssh-ed25519',
      'fingerprint': fingerprint,
      'acceptedAt': acceptedAt,
    };

/// 只实现保险库页面用到的几个方法。
class _FakeRepository implements VaultRepository {
  _FakeRepository(this.stored);
  VaultData stored;

  @override
  VaultData? loadVaultPreview() => stored;

  @override
  Future<VaultData> loadVault() async => stored;

  @override
  Future<void> saveVault(VaultData vault, {bool remote = false}) async =>
      stored = vault;

  @override
  Set<String> get unreadableSecrets => const {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<_FakeRepository> pumpScreen(
    WidgetTester tester,
    List<Map<String, dynamic>> known,
  ) async {
    final repository = _FakeRepository(VaultData.fromJson({
      'hosts': const [],
      'keys': const [],
      'snippets': const [],
      'customGroups': const [],
      'identities': const [],
      'knownHosts': known,
      'otherField': 'keep',
    }));
    await tester.pumpWidget(ProviderScope(
      overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
      child: const MaterialApp(home: KnownHostsScreen()),
    ));
    await tester.pumpAndSettle();
    return repository;
  }

  group('规则', () {
    test('withoutKnownHost 按规范写法删同一台的所有记录，别的端口、别的名字不动', () {
      final left = withoutKnownHost(
        [
          record('Web.Example.com'),
          record('web.example.com.', fingerprint: 'SHA256:old'),
          record('web.example.com', port: 2222),
          record('other.example.com'),
        ],
        hostname: 'web.example.com',
        port: 22,
      );
      expect(left.map(knownHostLabel), [
        'web.example.com:2222',
        'other.example.com:22',
      ]);
    });

    test('没写端口的按 22 算，和 checkHostKey 一个口径', () {
      final left = withoutKnownHost(
        [
          {'hostname': 'old.example.com', 'fingerprint': 'SHA256:x'},
        ],
        hostname: 'old.example.com',
        port: 22,
      );
      expect(left, isEmpty);
    });

    test('删完再连按第一次见：必须用户核对，拒绝就不放行、不写记录', () async {
      final known = withoutKnownHost(
        [record('web.example.com')],
        hostname: 'web.example.com',
        port: 22,
      );
      var prompts = 0;
      final saves = <List<Map<String, dynamic>>>[];
      final allowed = await verifyHostKeyWithKnownHosts(
        knownHosts: known,
        hostname: 'web.example.com',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:aaa',
        confirmNew: () async {
          prompts++;
          return false;
        },
        onChanged: (_) async => fail('不该按指纹变了处理'),
        save: (value) async => saves.add(value),
      );
      expect(allowed, isFalse);
      expect(prompts, 1);
      expect(saves, isEmpty);
    });

    test('IPv6 加方括号，按主机名再按端口排', () {
      expect(knownHostLabel(record('2001:db8::1')), '[2001:db8::1]:22');
      expect(
        sortedKnownHosts([
          record('b.example.com'),
          record('a.example.com', port: 2222),
          record('A.example.com'),
        ]).map(knownHostLabel),
        ['A.example.com:22', 'a.example.com:2222', 'b.example.com:22'],
      );
    });
  });

  group('页面', () {
    testWidgets('没有记录时只有一句话', (tester) async {
      await pumpScreen(tester, const []);
      expect(find.text('还没有接受过服务器'), findsOneWidget);
    });

    testWidgets('列出主机:端口、类型、指纹、接受时间', (tester) async {
      await pumpScreen(tester, [record('web.example.com', port: 2222)]);
      expect(find.text('web.example.com:2222'), findsOneWidget);
      expect(find.text('ssh-ed25519'), findsOneWidget);
      expect(find.text('SHA256:aaa'), findsOneWidget);
      final at = DateTime.fromMillisecondsSinceEpoch(acceptedAt);
      expect(find.text(formatConnectionEventTime(at)), findsOneWidget);
    });

    testWidgets('没有任何能改指纹、加记录的入口', (tester) async {
      await pumpScreen(tester, [record('web.example.com')]);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.byIcon(Icons.add), findsNothing);
      expect(find.byIcon(Icons.edit), findsNothing);
    });

    testWidgets('取消不删；确认后只删那一台，别的记录和保险库字段不动', (tester) async {
      final repository = await pumpScreen(tester, [
        record('web.example.com'),
        record('other.example.com'),
      ]);
      final web = find.byKey(const ValueKey('known-host-web.example.com:22'));
      final delete =
          find.descendant(of: web, matching: find.byIcon(Icons.delete_outline));

      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(knownHostsFromExtras(repository.stored.extras), hasLength(2));

      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(find.text('删除 web.example.com:22 的指纹？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();

      final left = knownHostsFromExtras(repository.stored.extras);
      expect(left.map(knownHostLabel), ['other.example.com:22']);
      expect(repository.stored.extras['otherField'], 'keep');
      expect(web, findsNothing);
    });
  });
}
