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

  Future<HostProfile> edit(WidgetTester tester, String scenario,
      {required bool catalog}) async {
    final repository = await VaultRepository.open();
    await repository.saveVault(VaultData(
        hosts: [edge],
        keys: [],
        snippets: [],
        customGroups: [],
        proxyProfiles: [proxy]));
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
    if (scenario == 'combined') {
      await tap(tester, find.text('经跳板机'));
      await tap(
          tester,
          find.byKey(
              ValueKey(catalog ? 'catalog-import-jump-0' : 'add-jump-host')));
      await tap(tester, find.text('edge').last);
      // Added hosts must leave the dropdown without leaving an invalid value.
      expect(tester.takeException(), isNull);
      await tap(tester, find.text('先经代理连第一台跳板机（高级）'));
    } else {
      await tap(tester, find.text('经代理'));
    }
    if (catalog) {
      expect(
          tester
              .widget<TextButton>(
                  find.byKey(const ValueKey('catalog-import-confirm')))
              .onPressed,
          isNull,
          reason: 'catalog retains its explicit unselected proxy default');
    }
    final editor = find.byType(ConnectionRouteEditor);
    final dropdown = find
        .descendant(
            of: editor, matching: find.byType(DropdownButtonFormField<String>))
        .last;
    if (scenario == 'saved' || catalog) {
      await tap(tester, dropdown);
      await tap(
          tester,
          find
              .text(scenario == 'saved'
                  ? (catalog ? 'saved-proxy' : '已保存 · saved-proxy')
                  : '自定义 HTTP / SOCKS5 代理')
              .last);
    }
    if (scenario != 'saved') {
      await tester.enterText(
          find.byKey(
              ValueKey(catalog ? 'catalog-import-proxy-host' : 'proxy-host')),
          ' proxy.example ');
      await tester.enterText(
          find.byKey(
              ValueKey(catalog ? 'catalog-import-proxy-port' : 'proxy-port')),
          '1080');
      final password = find.descendant(
          of: editor,
          matching: find.byWidgetPredicate(
              (w) => w is TextField && w.decoration?.labelText == '代理密码（可选）'));
      await tester.enterText(password, ' secret with spaces ');
      await tester.pumpAndSettle();
    }
    if (scenario == 'direct-clear') await tap(tester, find.text('直连'));
    await tap(
        tester,
        catalog
            ? find.byKey(const ValueKey('catalog-import-confirm'))
            : find.text('保存'));
    if (!catalog) expect(saved, isNotNull, reason: 'host form must save');
    final result = catalog ? (await repository.loadVault()).hosts.last : saved!;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    return result;
  }

  for (final scenario in ['custom', 'saved', 'combined', 'direct-clear']) {
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
      for (final key in ['hostChain', 'proxyProfileId', 'proxyConfig']) {
        expect(imported.data[key], host.data[key], reason: key);
      }
      String summary(HostProfile h) => routeSummary(
          resolveRoutePlan(h, hosts: [edge, h], proxyProfiles: [proxy]));
      expect(summary(imported), summary(host));
      if (scenario == 'direct-clear') {
        expect(host.hostChainIds, isEmpty);
        expect(host.proxyConfig, isNull);
        expect(host.proxyProfileId, isNull);
      } else if (scenario == 'saved') {
        expect(host.proxyProfileId, 'p');
        expect(host.proxyConfig, isNull);
      } else {
        expect(host.proxyConfig!.host, 'proxy.example');
        expect(host.proxyConfig!.password, ' secret with spaces ');
        expect(host.hostChainIds, scenario == 'combined' ? ['edge'] : isEmpty);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
