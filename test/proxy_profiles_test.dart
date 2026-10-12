import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/proxy_profiles.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/widgets/connection_route_draft.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secrets = <String, String>{};
  const secret = ' proxy secret with spaces ';
  late VaultRepository repository;
  late VaultController controller;
  ProxyProfile proxy({String host = 'proxy.example', String id = 'p'}) =>
      ProxyProfile({
        'id': id,
        'label': 'office',
        'desktopExtra': {'preserve': true},
        'config': {
          'type': 'socks5',
          'host': host,
          'port': 1080,
          'password': secret,
          'unknownConfig': [1, 2]
        },
      });
  HostProfile host(String id) => HostProfile({
        ...HostProfile.create(
                id: id, label: id, hostname: '$id.example', username: 'ops')
            .data,
        'proxyProfileId': 'p',
        'desktopHostExtra': 'keep',
      });
  setUp(() async {
    secrets.clear();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          return secrets[key];
        case 'write':
          secrets[key!] = args['value'] as String;
          return null;
        case 'delete':
          secrets.remove(key);
          return null;
        case 'readAll':
          return secrets;
        default:
          return null;
      }
    });
    repository = await VaultRepository.open();
    controller = VaultController(repository);
    await controller.ready();
  });
  tearDown(() => controller.dispose());

  test(
      'profile update changes both next routes, preserves active plan and unknown fields',
      () async {
    final original = proxy();
    await controller.saveProxyProfile(original);
    await controller.addHosts([host('a'), host('b')]);
    final before = await controller.ready();
    final active = resolveRoutePlan(before.hosts.first,
        hosts: before.hosts, proxyProfiles: before.proxyProfiles);
    final updated = proxy(host: 'new-proxy.example');
    await Future.wait([
      controller.saveProxyProfile(updated, expected: original),
      controller.patchHost('a', {'label': 'renamed'})
    ]);
    final after = await controller.ready();
    for (final h in after.hosts) {
      final plan = resolveRoutePlan(h,
          hosts: after.hosts, proxyProfiles: after.proxyProfiles);
      expect((plan.entry as ProxyEntry).endpoint.host, 'new-proxy.example');
      expect((plan.entry as ProxyEntry).password, secret);
      expect(h.data['desktopHostExtra'], 'keep');
    }
    expect(after.hosts.first.label, 'renamed');
    expect((active.entry as ProxyEntry).endpoint.host, 'proxy.example');
    expect(after.proxyProfiles.single.data['desktopExtra'], {'preserve': true});
    expect(after.proxyProfiles.single.config!.password, secret);
  });

  test('stale edit and deleted profile cannot be overwritten or resurrected',
      () async {
    final original = proxy();
    await controller.saveProxyProfile(original);
    await controller.saveProxyProfile(proxy(host: 'updated.example'),
        expected: original);
    await expectLater(
        controller.saveProxyProfile(proxy(host: 'stale.example'),
            expected: original),
        throwsA(isA<ProxyProfileChanged>()));
    final vault = await controller.ready();
    final current = vault.proxyProfiles.single;
    await controller.deleteProxyProfile(ProxyDeletion(vault, current));
    await expectLater(controller.saveProxyProfile(original, expected: current),
        throwsA(isA<ProxyProfileChanged>()));
    expect((await controller.ready()).proxyProfiles, isEmpty);
  });

  test(
      'delete rechecks shown references, preserves hosts, removes secret and fails closed',
      () async {
    final original = proxy();
    await controller.saveProxyProfile(original);
    await controller.upsertHost(host('a'));
    final shown = ProxyDeletion(await controller.ready(), original);
    await controller.upsertHost(host('b'));
    await expectLater(controller.deleteProxyProfile(shown),
        throwsA(isA<ProxyProfileChanged>()));
    final current = await controller.ready();
    final confirmed = ProxyDeletion(current, original);
    expect(confirmed.hosts.map((h) => h.id), ['a', 'b']);
    expect(secrets.values, contains(secret));
    await controller.deleteProxyProfile(confirmed);
    final after = await controller.ready();
    expect(after.hosts.map((h) => h.toJson()),
        current.hosts.map((h) => h.toJson()));
    expect(secrets.values, isNot(contains(secret)));
    for (final h in after.hosts) {
      expect(
          () => resolveRoutePlan(h,
              hosts: after.hosts, proxyProfiles: after.proxyProfiles),
          throwsA(isA<RouteConfigException>()));
    }
    final prefs = await SharedPreferences.getInstance();
    expect(jsonEncode({for (final key in prefs.getKeys()) key: prefs.get(key)}),
        isNot(contains(secret)));
  });

  test('secret persists only in secure storage and reloads after edit',
      () async {
    await controller.saveProxyProfile(proxy());
    final prefs = await SharedPreferences.getInstance();
    expect(jsonEncode({for (final key in prefs.getKeys()) key: prefs.get(key)}),
        isNot(contains(secret)));
    final reopened = await VaultRepository.open();
    final restored = (await reopened.loadVault()).proxyProfiles.single;
    expect(restored.config!.password, secret);
    expect(restored.data['config']['unknownConfig'], [1, 2]);
  });

  test('invalid endpoint cannot be saved; queue continues after rejection',
      () async {
    await expectLater(controller.saveProxyProfile(proxy(host: 'bad host')),
        throwsA(isA<RouteConfigException>()));
    expect((await controller.ready()).proxyProfiles, isEmpty);
    await controller.saveProxyProfile(proxy());
    expect((await controller.ready()).proxyProfiles.single.id, 'p');
  });

  test(
      'draft preserves inline unknown fields, conflicts, and malformed routes until explicit change',
      () {
    for (final extra in [
      {
        'proxyConfig': {
          'type': 'socks4',
          'host': 'p',
          'port': 1080,
          'unknown': true
        }
      },
      {'proxyConfig': 'malformed'},
      {
        'hostChain': {'hostIds': 'malformed'}
      },
      {
        'hostChain': {
          'hostIds': ['']
        }
      },
    ]) {
      final target = HostProfile({...host('target').data, ...extra});
      final draft = ConnectionRouteDraft.forHost(target);
      final edited = {...target.data};
      draft.writeTo(edited);
      for (final key in extra.keys) {
        expect(edited[key], extra[key]);
      }
      expect(
          () => resolveRoutePlan(HostProfile(edited),
              hosts: [], proxyProfiles: [proxy()]),
          throwsA(isA<RouteConfigException>()));
      draft.clear();
      draft.writeTo(edited);
      expect(
          resolveRoutePlan(HostProfile(edited), hosts: [], proxyProfiles: [])
              .entry,
          isA<DirectEntry>());
    }
  });
}
