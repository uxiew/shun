import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/domain/route_description.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/tailscale/catalog_cache.dart';
import 'package:shun/infrastructure/tailscale/tailscale_device.dart';
import 'package:shun/presentation/widgets/catalog_import_sheet.dart';
import 'package:shun/presentation/widgets/connection_route_editor.dart';
import 'package:shun/presentation/widgets/host_editor.dart';
import 'support/route_editor_actions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final edge = HostProfile.create(
      id: 'edge', label: 'edge', hostname: 'edge.example', username: 'ops');
  final proxy = ProxyProfile({
    'id': 'p',
    'label': 'saved-proxy',
    'config': {'type': 'socks5', 'host': 'proxy.example', 'port': 1080}
  });
  final cache = const CatalogCache(catalogId: 'catalog', tailnet: '-').merge(
      TailscaleDeviceSnapshot.parse(jsonEncode({
        'devices': [
          {
            'id': 'device',
            'hostname': 'target',
            'name': 'target.example',
            'addresses': ['100.64.0.9'],
            'os': 'linux',
          }
        ]
      })),
      DateTime.utc(2026, 10, 12));

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (_) async => null);
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<({HostProfile host, VaultData vault})> edit(
      WidgetTester tester, String scenario,
      {required bool catalog}) async {
    final repository = await VaultRepository.open();
    await repository.saveVault(VaultData(hosts: [
      edge,
      for (var i = 1; i < 3; i++)
        HostProfile.create(
            id: 'edge$i',
            label: 'edge$i',
            hostname: 'edge$i.example',
            username: 'ops')
    ], keys: [], snippets: [], customGroups: [], proxyProfiles: [
      proxy
    ]));
    HostProfile? saved;
    final target = HostProfile.create(
        id: 'target', label: 'target', hostname: '100.64.0.9', username: 'ops');
    await tester.pumpWidget(ProviderScope(
        overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
            home: Builder(
                builder: (context) => Scaffold(
                    body: TextButton(
                        onPressed: () async {
                          final result = await Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => catalog
                                      ? CatalogImportPage(
                                          cache: cache,
                                          deviceIds: const ['device'])
                                      : HostEditor(host: target)));
                          if (!catalog) saved = result as HostProfile?;
                        },
                        child: const Text('open')))))));
    await tap(tester, find.text('open'));
    expect(find.byType(ConnectionRouteEditor), findsOneWidget);
    if (catalog) {
      await tester.enterText(
          find.byKey(const ValueKey('catalog-import-username')), 'ops');
      await tester.pumpAndSettle();
    }
    expect(find.text('经代理'), findsNothing);
    expect(find.text('经跳板机'), findsNothing);
    final jumpCount = scenario.startsWith('jump')
        ? int.parse(scenario.substring(4))
        : scenario == 'combined'
            ? 1
            : 0;
    for (var i = 0; i < jumpCount; i++) {
      await addRouteJump(tester, i == 0 ? 'edge' : 'edge$i');
    }
    if (scenario == 'saved') {
      await tapRoute(tester, find.byKey(const ValueKey('route-add-proxy')));
      await tapRoute(tester, find.byKey(const ValueKey('proxy-profile-p')));
    } else if (scenario == 'custom' ||
        scenario == 'combined' ||
        scenario == 'direct-clear') {
      await createRouteProxy(tester,
          host: ' proxy.example ', password: ' secret with spaces ');
    }
    if (scenario == 'direct-clear') {
      await tapRoute(tester, find.byKey(const ValueKey('route-clear')));
    }
    await tap(
        tester,
        catalog
            ? find.byKey(const ValueKey('catalog-import-confirm'))
            : find.text('保存'));
    if (!catalog) expect(saved, isNotNull, reason: 'host form must save');
    final result = catalog ? (await repository.loadVault()).hosts.last : saved!;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    return (host: result, vault: await repository.loadVault());
  }

  for (final scenario in [
    'direct',
    'custom',
    'saved',
    'jump1',
    'jump2',
    'jump3',
    'combined',
    'direct-clear'
  ]) {
    testWidgets(
        'R40 both real pages preserve route data and preview: $scenario',
        (tester) async {
      tester.view.physicalSize = const Size(900, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final host = await edit(tester, scenario, catalog: false);
      SharedPreferences.setMockInitialValues({});
      final imported = await edit(tester, scenario, catalog: true);
      expect(imported.host.hostChainIds, host.host.hostChainIds);
      String summary(({HostProfile host, VaultData vault}) value) =>
          routeSummary(resolveRoutePlan(value.host,
              hosts: value.vault.hosts,
              proxyProfiles: value.vault.proxyProfiles));
      expect(summary(imported), summary(host));
      if (scenario == 'direct-clear' || scenario == 'direct') {
        expect(host.host.hostChainIds, isEmpty);
        expect(host.host.proxyConfig, isNull);
        expect(host.host.proxyProfileId, isNull);
      } else if (scenario == 'saved') {
        expect(host.host.proxyProfileId, 'p');
        expect(imported.host.proxyProfileId, 'p');
      } else if (scenario.startsWith('jump')) {
        expect(host.host.hostChainIds.length, int.parse(scenario.substring(4)));
      } else {
        ProxyConfig config(({HostProfile host, VaultData vault}) value) =>
            value.vault.proxyProfiles
                .singleWhere((p) => p.id == value.host.proxyProfileId)
                .config!;
        expect(config(imported).toJson(), config(host).toJson());
        expect(config(host).host, 'proxy.example');
        expect(config(host).password, ' secret with spaces ');
        expect(host.host.hostChainIds,
            scenario == 'combined' ? ['edge'] : isEmpty);
        expect(host.host.proxyConfig, isNull);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
