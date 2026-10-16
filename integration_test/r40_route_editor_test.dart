// Real Android UI, encrypted vault and local SSH topology. Run only through
// tool/r40-route-editor.sh on the dedicated test emulator (it clears test data).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/tailscale/catalog_cache.dart';
import 'package:shun/infrastructure/tailscale/tailscale_device.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';
import 'package:shun/presentation/widgets/catalog_import_sheet.dart';
import 'package:shun/presentation/widgets/connection_route_editor.dart';
import 'package:shun/presentation/widgets/host_editor.dart';
import 'package:shun/presentation/widgets/proxy_profiles_page.dart';

const config = String.fromEnvironment('R40_CONFIG');
Finder key(String value) => find.byKey(ValueKey(value));

Future<void> frames(WidgetTester tester) async {
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
}

Future<void> reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 240,
        scrollable: find.byType(Scrollable).first, maxScrolls: 30);
  }
  await tester.ensureVisible(finder);
  await frames(tester);
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await reveal(tester, finder);
  await tester.tap(finder);
  await frames(tester);
}

Future<void> back(WidgetTester tester) async {
  if (find.byType(HostEditor).evaluate().isNotEmpty) {
    await tap(tester, find.byIcon(Icons.close));
    // R41: closing with unsaved edits asks first; this helper always meant discard.
    final discard = find.byKey(const ValueKey('host-editor-discard'));
    if (discard.evaluate().isNotEmpty) await tap(tester, discard);
  } else {
    await tester.pageBack();
  }
  await frames(tester);
}

Future<void> type(WidgetTester tester, Finder finder, String value) async {
  await reveal(tester, finder);
  await tester.enterText(finder, value);
  await frames(tester);
}

Future<void> hideKeyboard(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  await frames(tester);
}

Future<void> screenshot(WidgetTester tester, String name) async {
  final directory = await getApplicationSupportDirectory();
  final ack = File('${directory.path}/r40/$name');
  debugPrint('R40 SHOT=$name');
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!await ack.exists()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Screenshot host did not respond');
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(tester.takeException(), isNull);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;
  testWidgets(
      'R40 device route editing, proxy management and legacy conversion',
      (tester) async {
    final cfg = jsonDecode(config) as Map<String, dynamic>;
    final prefs = await SharedPreferences.getInstance();
    final cold = prefs.getBool('r40.seeded') ?? false;
    final repository = await VaultRepository.open();
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    ShunLocalizations.use('zh-CN');
    final controller = container.read(vaultControllerProvider.notifier);
    await controller.ready();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            navigatorKey: navigator,
            home: const Scaffold(
                body: Center(child: Text('R40 local fixture'))))));
    await frames(tester);

    HostProfile node(String id, String address,
            {Map<String, dynamic> extra = const {}}) =>
        HostProfile({
          ...HostProfile.create(
                  id: id,
                  label: id,
                  hostname: address,
                  username: cfg['user'] as String)
              .data,
          'authMethod': 'password',
          'password': cfg['password'],
          ...extra,
        });
    final inline = <String, dynamic>{
      'type': 'socks5',
      'host': '127.0.0.1',
      'port': 21080,
      'username': cfg['socksAuth']['username'],
      'password': cfg['socksAuth']['password'],
      'desktop-extra': {'preserve': true},
    };
    if (!cold) {
      await controller.replace(VaultData(hosts: [
        node('edge', 'ssh-edge'),
        node('hop2', cfg['hop2']['name']),
        node('hop3', cfg['hop3']['name']),
        node('legacy', cfg['target']['name'], extra: {
          'proxyConfig': inline,
          'desktop-host-extra': 'keep',
        }),
        node('peer', cfg['target']['name']),
        node('nested', 'ssh-edge', extra: {'proxyConfig': inline}),
        node('proxy-edge', 'ssh-edge', extra: {'proxyConfig': inline}),
        node('nested-b', cfg['hop2']['name'], extra: {
          'hostChain': {
            'hostIds': ['proxy-edge']
          }
        }),
        node('nested-c', cfg['hop3']['name'], extra: {
          'hostChain': {
            'hostIds': ['nested-b']
          }
        }),
        node('direct-edge', '127.0.0.1',
            extra: {'port': 22201, 'proxyConfig': inline}),
        node('choices-target', cfg['target']['name']),
        node('choices-direct', cfg['target']['name']),
        node('cycle-a', 'ssh-edge', extra: {
          'hostChain': {
            'hostIds': ['cycle-b']
          }
        }),
        node('cycle-b', cfg['hop2']['name'], extra: {
          'hostChain': {
            'hostIds': ['cycle-a']
          }
        }),
        node('unsupported', cfg['target']['name'], extra: {
          'proxyConfig': {...inline, 'type': 'desktop-unknown'},
        }),
      ], keys: [], snippets: [], customGroups: []));
    }
    Future<HostProfile> host(String id) async =>
        (await controller.ready()).hosts.singleWhere((h) => h.id == id);
    Future<void> open(Widget page) async {
      navigator.currentState!
          .push(MaterialPageRoute<void>(builder: (_) => page));
      await frames(tester);
    }

    Future<void>? hostResult;
    Future<void> edit(String id) async {
      final current = await host(id);
      // The real parent also persists the HostEditor result, outside the form.
      hostResult = navigator.currentState!
          .push<HostProfile>(
              MaterialPageRoute(builder: (_) => HostEditor(host: current)))
          .then((result) async {
        if (result != null) await controller.upsertHost(result);
      });
      await frames(tester);
    }

    Future<void> saveHost() async {
      await hideKeyboard(tester);
      await tap(tester, find.byKey(const ValueKey('host-editor-save')));
      expect(find.byType(HostEditor), findsNothing);
      await hostResult;
    }

    ConnectionRouteEditor editor() =>
        tester.widget(find.byType(ConnectionRouteEditor));
    Future<void> jump(String label) async {
      final dropdown = find.descendant(
          of: find.byType(ConnectionRouteEditor),
          matching: find.byType(DropdownButtonFormField<String>));
      await tap(tester, dropdown);
      await tap(tester, find.text(label).last);
    }

    final dials = <int>[];
    final service = SshService(dialer: (address, port, {timeout}) {
      // Never permit a test failure to dial a real user host or tailnet.
      dials.add(port);
      expect(address, '127.0.0.1');
      expect([21080, 21081, 21082, 22201], contains(port));
      return Socket.connect(address, port, timeout: timeout);
    });
    Future<void> connect(String id, List<String> hops, int entryPort) async {
      final vault = await controller.ready();
      final selected = vault.hosts.singleWhere((h) => h.id == id);
      final verified = <String>[];
      final fingerprints = {
        'edge': cfg['sshEdge']['fingerprintSha256'],
        'proxy-edge': cfg['sshEdge']['fingerprintSha256'],
        'direct-edge': cfg['sshEdge']['fingerprintSha256'],
        'nested-b': cfg['hop2']['fingerprintSha256'],
        'nested-c': cfg['hop3']['fingerprintSha256'],
        'hop2': cfg['hop2']['fingerprintSha256'],
        'hop3': cfg['hop3']['fingerprintSha256'],
        id: cfg['target']['fingerprintSha256'],
      };
      final result = await service.withVerifiedClient(
          routePlan: resolveRoutePlan(selected,
              hosts: vault.hosts, proxyProfiles: vault.proxyProfiles),
          verifyHostKey: (h, algorithm, fingerprint) async {
            expect(algorithm, 'ssh-ed25519');
            expect(fingerprint, fingerprints[h.id]);
            verified.add(h.id);
            return true;
          },
          attempt: ConnectionAttempt(),
          query: (client) async =>
              utf8.decode(await client.run('hostname')).trim());
      expect(result, 'target');
      expect(verified, [...hops, id]);
      expect(dials.last, entryPort);
      debugPrint('R40 SSH=$id hops=${hops.length} entry=$entryPort PASS');
    }

    if (!cold) {
      await edit('legacy');
      await tap(tester, key('route-save-inline'));
      await back(tester);
      await frames(tester);
      expect((await controller.ready()).proxyProfiles, isEmpty);
      await tap(tester, key('route-save-inline'));
      await type(tester, key('proxy-label'), 'Converted proxy');
      // Real Android IME, no fake viewInsets or enlarged viewport.
      await tap(tester, key('proxy-label'));
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (tester.view.viewInsets.bottom == 0) {
        if (DateTime.now().isAfter(deadline)) {
          fail('Android keyboard did not open');
        }
        await tester.pump(const Duration(milliseconds: 100));
      }
      debugPrint(
          'R40 KEYBOARD=visible width=${tester.view.physicalSize.width / tester.view.devicePixelRatio}');
      await tap(tester, key('proxy-save'));
      await hideKeyboard(tester);
      final profile = (await controller.ready()).proxyProfiles.single;
      expect(profile.config!.password == inline['password'], isTrue);
      expect(profile.data['config']['desktop-extra'], {'preserve': true});
      expect(
          equals(inline)
              .matches((await host('legacy')).data['proxyConfig'], {}),
          isTrue);
      await back(tester);
      await frames(tester);
      expect((await host('legacy')).proxyProfileId, isNull);
      expect(
          equals(inline)
              .matches((await host('legacy')).data['proxyConfig'], {}),
          isTrue);
      debugPrint(
          'R40 CONVERSION=cancel-creator-and-host-preserves-original PASS');

      await edit('legacy');
      await tap(tester, key('route-change-proxy'));
      await tap(tester, key('proxy-profile-${profile.id}'));
      await saveHost();
      final converted = await host('legacy');
      expect(converted.proxyProfileId, profile.id);
      expect(converted.data.containsKey('proxyConfig'), isFalse);
      expect(converted.data['desktop-host-extra'], 'keep');
      await connect('legacy', [], 21080);
      for (final hop in ['edge', 'hop2', 'hop3']) {
        await edit('legacy');
        await jump(hop);
        await saveHost();
        await connect('legacy', (await host('legacy')).hostChainIds, 21080);
      }
      await edit('legacy');
      await reveal(tester, key('jump-up-2'));
      expect(
          find.descendant(
              of: find.byType(ConnectionRouteEditor),
              matching: find.byType(DropdownButtonFormField<String>)),
          findsNothing);
      await tap(tester, key('jump-up-2'));
      expect(editor().draft.jumpHostIds, ['edge', 'hop3', 'hop2']);
      await tap(tester, key('jump-down-0'));
      expect(editor().draft.jumpHostIds, ['hop3', 'edge', 'hop2']);
      await tap(tester, key('jump-remove-1'));
      expect(editor().draft.jumpHostIds, ['hop3', 'hop2']);
      await jump('edge');
      expect(editor().draft.jumpHostIds, ['hop3', 'hop2', 'edge']);
      await reveal(tester, key('jump-up-1'));
      await screenshot(tester, 'chain-three');
      await saveHost();
      await connect('legacy', ['hop3', 'hop2', 'edge'], 21080);

      await edit('peer');
      await tap(tester, key('route-add-proxy'));
      await tap(tester, key('proxy-profile-${profile.id}'));
      await saveHost();
      await open(const ProxyProfilesPage());
      await tap(tester, key('proxy-edit-${profile.id}'));
      await type(tester, key('proxy-port'), '0');
      await tap(tester, key('proxy-save'));
      await reveal(tester, key('proxy-error'));
      expect(
          (await controller.ready()).proxyProfiles.single.config!.port, 21080);
      await type(tester, key('proxy-port'), '21081');
      await tap(tester, key('proxy-save'));
      await hideKeyboard(tester);
      final beforeFailure = dials.length;
      await expectLater(
          connect('peer', [], 21081), throwsA(isA<RouteHopException>()));
      expect(dials.sublist(beforeFailure), [21081]);
      // Authenticated profiles must not downgrade at a no-auth endpoint.
      // 21082 is a second adb entrance to the same authenticated fixture.
      await tap(tester, key('proxy-edit-${profile.id}'));
      await type(tester, key('proxy-port'), '21082');
      await tap(tester, key('proxy-save'));
      await hideKeyboard(tester);
      await screenshot(tester, 'proxy-manager');
      await back(tester);
      await frames(tester);
      for (final id in ['legacy', 'peer']) {
        await connect(id, (await host(id)).hostChainIds, 21082);
      }
      debugPrint('R40 PROXY=invalid-edit-rejected-shared-update PASS');

      final cache =
          const CatalogCache(catalogId: 'r40-local', tailnet: '-').merge(
              TailscaleDeviceSnapshot.parse(jsonEncode({
                'devices': [
                  for (final id in ['one', 'two'])
                    {
                      'id': id,
                      'hostname': 'catalog-$id',
                      'name': 'catalog-$id.fixture.internal',
                      'addresses': ['192.0.2.${id == 'one' ? 1 : 2}'],
                      'os': 'linux',
                    }
                ]
              })),
              DateTime.utc(2026, 10, 12));
      await open(
          CatalogImportPage(cache: cache, deviceIds: const ['one', 'two']));
      await type(tester, key('catalog-import-username'), 'fixture');
      await hideKeyboard(tester);
      await tap(tester, key('route-add-proxy'));
      await tap(tester, key('proxy-profile-${profile.id}'));
      for (final hop in ['edge', 'hop2', 'hop3']) {
        await jump(hop);
      }
      await tap(tester, key('jump-up-2'));
      await tap(tester, key('jump-remove-1'));
      expect(editor().draft.jumpHostIds, ['edge', 'hop2']);
      await screenshot(tester, 'catalog-chain');
      await tap(tester, key('catalog-import-confirm'));
      final imported = (await controller.ready())
          .hosts
          .where((h) => h.label.startsWith('catalog-'))
          .toList();
      expect(imported.length, 2);
      for (final h in imported) {
        expect(h.proxyProfileId, profile.id);
        expect(h.hostChainIds, ['edge', 'hop2']);
      }
      // Catalog addresses are documentation-only fixtures and are never dialled.
      await edit('peer');
      await jump('nested');
      await reveal(tester, key('route-preview-error'));
      expect(editor().plan, isNull);
      await tap(tester, find.byKey(const ValueKey('host-editor-save')));
      expect(find.byType(HostEditor), findsOneWidget);
      await tap(tester, key('route-clear'));
      expect(editor().draft.usesProxy, isFalse);
      expect(editor().draft.jumpHostIds, isEmpty);
      await saveHost();
      expect((await host('peer')).proxyProfileId, isNull);
      await edit('peer');
      await tap(tester, key('route-add-proxy'));
      await tap(tester, key('proxy-profile-${profile.id}'));
      await saveHost();
      debugPrint(
          'R40 ROUTES=three-hop-limit-reorder-remove-catalog-clear-nested-rejection PASS');
      await edit('choices-target');
      await jump('nested-c');
      expect(editor().plan, isNull);
      await tap(tester, key('route-confirm-jumps'));
      await screenshot(tester, 'jump-route-confirm');
      // The editor's bottom bar also has 取消 since R41; cancel the dialog itself.
      await tap(tester,
          find.descendant(of: find.byType(AlertDialog), matching: find.text('取消')));
      expect(editor().draft.confirmation, isNull);
      expect(editor().draft.jumpHostIds, ['nested-c']);
      await tap(tester, key('route-confirm-jumps'));
      await tap(tester, key('route-choice-proxy'));
      expect(
          editor().draft.jumpHostIds, ['proxy-edge', 'nested-b', 'nested-c']);
      await saveHost();
      await connect(
          'choices-target', ['proxy-edge', 'nested-b', 'nested-c'], 21080);
      expect((await host('nested-c')).hostChainIds, ['nested-b']);
      expect(
          (await host('proxy-edge')).data['proxyConfig']['password'] ==
              inline['password'],
          isTrue);
      await edit('choices-direct');
      await jump('cycle-a');
      await tap(tester, key('route-confirm-jumps'));
      await reveal(tester, key('route-choice-error'));
      expect(editor().draft.jumpHostIds, ['cycle-a']);
      await screenshot(tester, 'jump-route-cycle');
      await tap(tester, key('route-clear'));
      await jump('direct-edge');
      await tap(tester, key('route-confirm-jumps'));
      await tap(tester, key('route-choice-direct'));
      expect(editor().draft.usesProxy, isFalse);
      await saveHost();
      await connect('choices-direct', ['direct-edge'], 22201);
      debugPrint(
          'R40 CHOICES=cancel-expand-three-use-proxy-explicit-direct-cycle-block PASS');

      await edit('unsupported');
      await reveal(tester, key('route-preview-error'));
      expect(editor().plan, isNull);
      await tap(tester, key('route-save-inline'));
      expect(
          tester
              .widget<DropdownButtonFormField<ProxyType>>(
                  find.byType(DropdownButtonFormField<ProxyType>))
              .initialValue,
          isNull);
      await back(tester);
      await tap(tester, find.byKey(const ValueKey('host-editor-save')));
      expect(find.byType(HostEditor), findsOneWidget);
      await back(tester);
      expect((await host('unsupported')).data['proxyConfig']['type'],
          'desktop-unknown');
      debugPrint('R40 LEGACY=unknown-type-preserved-and-blocked PASS');
      await prefs.setString('r40.profile', profile.id);
      await prefs.setBool('r40.seeded', true);
      debugPrint('R40 DONE=seed pid=$pid');
    } else {
      final profileId = prefs.getString('r40.profile')!;
      final vault = await controller.ready();
      final profile = vault.proxyProfiles.single;
      expect(profile.id, profileId);
      expect((await host('unsupported')).data['proxyConfig']['type'],
          'desktop-unknown');
      expect(profile.config!.port, 21082);
      expect(profile.config!.password == inline['password'], isTrue);
      expect(profile.data['config']['desktop-extra'], {'preserve': true});
      expect((await host('legacy')).data['desktop-host-extra'], 'keep');
      expect((await host('legacy')).data.containsKey('proxyConfig'), isFalse);
      await connect('legacy', ['hop3', 'hop2', 'edge'], 21082);
      await connect('peer', [], 21082);
      await connect(
          'choices-target', ['proxy-edge', 'nested-b', 'nested-c'], 21080);
      await connect('choices-direct', ['direct-edge'], 22201);
      final originalNested = await host('nested-b');
      await controller.upsertHost(HostProfile({
        ...originalNested.data,
        'hostChain': {
          'hostIds': ['edge']
        }
      }));
      final beforeStale = dials.length;
      await expectLater(connect('choices-target', [], 21080),
          throwsA(isA<RouteConfigException>()));
      expect(dials.length, beforeStale);
      await edit('choices-target');
      await reveal(tester, key('route-preview-error'));
      expect(editor().plan, isNull);
      await back(tester);
      await controller.upsertHost(originalNested);
      debugPrint('R40 CHOICES=cold-confirmation-source-change-zero-dial PASS');
      debugPrint(
          'R40 COLD=reference-order-unknown-fields-encrypted-password PASS pid=$pid');
      await edit('legacy');
      await tap(tester, find.text('代理管理'));
      await tap(tester, key('proxy-delete-$profileId'));
      expect(find.textContaining('legacy · fixture@'), findsOneWidget);
      expect(find.textContaining('peer · fixture@'), findsOneWidget);
      await screenshot(tester, 'delete-impact');
      await tap(tester, find.text('取消'));
      expect((await controller.ready()).proxyProfiles.length, 1);
      await tap(tester, key('proxy-delete-$profileId'));
      await tap(tester, key('proxy-delete-confirm'));
      // Frame settling does not await Android secure-storage I/O. Observe the
      // completed deletion, with a bounded wait and the real UI error exposed.
      final deleteDeadline = DateTime.now().add(const Duration(seconds: 10));
      while (key('proxy-profile-$profileId').evaluate().isNotEmpty &&
          key('proxy-manager-error').evaluate().isEmpty &&
          DateTime.now().isBefore(deleteDeadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(key('proxy-manager-error'), findsNothing);
      expect((await controller.ready()).proxyProfiles, isEmpty);
      await back(tester);
      await frames(tester);
      await reveal(tester, key('route-preview-error'));
      expect(editor().draft.selectedProxyProfileId, profileId);
      expect(editor().plan, isNull);
      await screenshot(tester, 'missing-proxy');
      await tap(tester, find.byKey(const ValueKey('host-editor-save')));
      expect(find.byType(HostEditor), findsOneWidget);
      final count = dials.length;
      await expectLater(
          connect('legacy', [], 21081), throwsA(isA<RouteConfigException>()));
      expect(dials.length, count);
      expect((await host('legacy')).proxyProfileId, profileId);
      final secure = await vaultSecureStorage.readAll();
      expect(secure.containsKey('proxy.$profileId.password'), isFalse);
      await back(tester);
      await frames(tester);
      ShunLocalizations.use('en');
      await open(const ProxyProfilesPage());
      await tap(tester, key('proxy-create'));
      await type(tester, key('proxy-label'), 'New HTTP proxy');
      await tap(tester, find.byType(DropdownButtonFormField<ProxyType>));
      await tap(tester, find.text('HTTP').last);
      await type(tester, key('proxy-host'), '127.0.0.1');
      await type(tester, key('proxy-port'), '21081');
      await tap(tester, key('proxy-save'));
      await hideKeyboard(tester);
      expect((await controller.ready()).proxyProfiles.single.config!.type,
          ProxyType.http);
      await screenshot(tester, 'english-manager');
      debugPrint(
          'R40 DELETE=impact-cancel-confirm-keeps-reference-zero-dial-secret-removed PASS');
      debugPrint('R40 CREATE=english-http-system-keyboard PASS');
      debugPrint('R40 DONE=cold pid=$pid');
    }
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 8)));
}
