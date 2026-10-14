// Real Android secure storage, lifecycle and native bridges. Never run directly
// on a phone: tool/r39-device.py authorizes only the disposable project emulator.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:plugin_api/plugin_api.dart';
import 'package:shun/app.dart';
import 'package:shun/application/device_links.dart';
import 'package:shun/application/external_remote.dart';
import 'package:shun/application/rustdesk.dart';
import 'package:shun/application/tailscale_catalog_refresh.dart';
import 'package:shun/application/uuremote.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/device_references.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/widgets/vault_host_items.dart';
import 'package:url_launcher/url_launcher.dart';

import 'support/r39_fixture.dart';
import 'support/r39_forms.dart';
import 'support/r39_ui.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;
  testWidgets('R39 encrypted migration and real cold callback', (tester) async {
    final cfg = R39Fixture(const String.fromEnvironment('R39_CONFIG'));
    final support = await getApplicationSupportDirectory();
    final root = Directory('${support.path}/r39');
    expect(await File('${root.path}/authorized').readAsString(), cfg.runId);
    final phase = await File('${root.path}/phase').readAsString();
    expect(['seed', 'migrate', 'cold', 'verify'], contains(phase));
    Future<void> report(String status) async {
      await File('${root.path}/$phase.json').writeAsString(
          jsonEncode({
            'runId': cfg.runId,
            'phase': phase,
            'pid': pid,
            'status': status
          }),
          flush: true);
    }

    await report('started');
    final rdBackend = SecureProviderBackend(
        prefsName: 'shun_rustdesk', keychainAccount: 'shun.rustdesk');
    final uuBackend = SecureProviderBackend(
        prefsName: 'shun_uuremote', keychainAccount: 'shun.uuremote');
    final repository = await VaultRepository.open();

    if (phase == 'seed') {
      expect((await repository.loadVault()).hosts, isEmpty);
      expect(await rdBackend.read('rustdesk.entries.v2'), isNull);
      expect(await uuBackend.read('uuremote.entries.v2'), isNull);
      expect(await rdBackend.read('rustdesk.links.v1'), isNull);
      expect(await uuBackend.read('uuremote.bindings.v1'), isNull);
      final now = DateTime.now().toUtc();
      final host = HostProfile({
        ...HostProfile.create(
                id: R39Fixture.owner,
                label: 'R39 legacy',
                hostname: 'r39.invalid',
                username: 'fixture')
            .data,
        'proxyConfig': {'type': 'socks5', 'host': '127.0.0.1', 'port': 9},
        CatalogBinding.key: const CatalogBinding(
                catalogId: R39Fixture.catalog, deviceId: R39Fixture.device)
            .toJson(),
      });
      await repository.saveVault(VaultData.empty().copyWith(hosts: [
        host,
        HostProfile({
          'id': 'r39-unknown',
          'label': 'R39 unknown',
          'protocol': 'future-r39',
          'opaque': {'keep': true}
        }),
      ]));
      // Freeze the old wire shape, rather than seeding through the v2 writer.
      await rdBackend.write(
          'rustdesk.links.v1',
          jsonEncode([
            {
              'id': R39Fixture.link,
              'hostId': R39Fixture.owner,
              'peerId': cfg.peer,
              'createdAt': now.toIso8601String(),
            }
          ]));
      await uuBackend.write(
          'uuremote.bindings.v1',
          jsonEncode([
            {
              'id': R39Fixture.binding,
              'hostId': R39Fixture.owner,
              'anonymousDeviceId': cfg.oldOpaque,
              'createdAt': now.toIso8601String(),
            }
          ]));
      await uuBackend.write(
          'uuremote.pending.v1',
          jsonEncode({
            'kind': 'bind',
            'state': cfg.state,
            'nonce': cfg.nonce,
            'hostId': R39Fixture.owner,
            'createdAt': now.toIso8601String(),
            'expiresAt': now.add(uuPendingLifetime).toIso8601String(),
          }));
      await report('passed');
      return;
    }

    final oldRd = await rdBackend.read('rustdesk.links.v1');
    final oldUu = await uuBackend.read('uuremote.bindings.v1');
    final oldPending = await uuBackend.read('uuremote.pending.v1');
    expect(oldRd, isNotNull);
    expect(oldUu, isNotNull);
    expect(oldPending, isNotNull);
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    // Mount the real listener before awaiting the controllers: cold callbacks
    // are queued by Android, then delivered during controller initialization.
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container, child: const ShunApp()));
    final rd = container.read(rustDeskProvider.notifier);
    final uu = container.read(uuRemoteProvider.notifier);
    await rd.ready;
    await uu.ready;
    await r39Frames(tester);
    final vault = container.read(vaultControllerProvider.notifier);
    expect(container.read(rustDeskProvider).entries, hasLength(1));
    expect(container.read(uuRemoteProvider).entries, hasLength(1));
    final link = container.read(rustDeskProvider).links.single;
    expect(link.id, R39Fixture.link);
    expect(link.hostId, R39Fixture.owner);
    expect(link.peer.value == cfg.peer, isTrue, reason: 'RD peer preserved');
    final binding = container.read(uuRemoteProvider).bindings.single;
    expect(binding.id, R39Fixture.binding);
    expect(binding.hostId, R39Fixture.owner);
    for (final entry in [
      ...container.read(rustDeskProvider).entries,
      ...container.read(uuRemoteProvider).entries,
    ]) {
      expect(entry.sourceHostId, R39Fixture.owner);
      expect(entry.sourceCatalogId, R39Fixture.catalog);
      expect(entry.sourceDeviceId, R39Fixture.device);
      expect(entry.routeWarning, RequestedRoute.socks5Connect);
    }

    if (phase == 'migrate') {
      final pending = container.read(uuRemoteProvider).pending;
      expect(pending, isNotNull);
      expect(jsonEncode(pending!.toJson()) == oldPending, isTrue,
          reason: 'Pending identity and deadline must not change');
      expect(binding.anonymousDeviceId == cfg.oldOpaque, isTrue);
      await r39Tap(
          tester,
          find.descendant(
              of: find.byType(VaultHostCard),
              matching: find.text('R39 legacy')));
      expect(r39Key('host-rustdesk'), findsNothing);
      expect(r39Key('host-uuremote'), findsNothing);
      await tester.binding.handlePopRoute();
      await r39Frames(tester);
      await vault.deleteHost(R39Fixture.owner);
      await r39Frames(tester);
      expect(r39Key('remote-RustDesk-${R39Fixture.owner}'), findsOneWidget);
      expect(r39Key('remote-UU 远程-${R39Fixture.owner}'), findsOneWidget);
      await report('kill-ready');
      // The host kills this still-running process, not a cleanly exited test.
      await r39Gate(tester, 'kill-migrate');
      fail('Migration process should have been force-stopped');
    }

    if (phase == 'cold') {
      await r39Gate(tester, 'cold-attached');
      expect(container.read(uuRemoteProvider).pending, isNull);
      final offer = container.read(uuRemoteProvider).offer;
      expect(offer, isNotNull);
      expect(offer!.hostId, R39Fixture.owner);
      expect(offer.anonymousDeviceId == cfg.newOpaque, isTrue);
      expect(binding.anonymousDeviceId == cfg.oldOpaque, isTrue,
          reason: 'Callback alone must not replace the binding');
      await r39Tap(tester, r39Key('uu-offer-confirm'));
      expect(container.read(uuRemoteProvider).offer, isNull);
      expect(container.read(uuRemoteProvider).bindings.single.id,
          R39Fixture.binding);
      expect(
          container.read(uuRemoteProvider).bindings.single.anonymousDeviceId ==
              cfg.newOpaque,
          isTrue);
      expect(
          await launchUrl(cfg.callback, mode: LaunchMode.externalApplication),
          isTrue);
      await tester.pump(const Duration(seconds: 1));
      await r39Frames(tester);
      expect(container.read(uuRemoteProvider).offer, isNull,
          reason: 'Replayed native callback cannot create another offer');
    }
    if (phase == 'verify') {
      expect(container.read(uuRemoteProvider).pending, isNull);
      expect(container.read(uuRemoteProvider).offer, isNull);
      expect(binding.anonymousDeviceId == cfg.newOpaque, isTrue);
      await r39Forms(tester, container, cfg);
    }

    final current = await vault.ready();
    expect(current.hosts.where((h) => h.id == R39Fixture.owner), isEmpty);
    final unknown = current.hosts.singleWhere((h) => h.id == 'r39-unknown');
    expect(unknown.data, {
      'id': 'r39-unknown',
      'label': 'R39 unknown',
      'protocol': 'future-r39',
      'opaque': {'keep': true}
    });
    final links = deviceLinksOf(
        hosts: [],
        rustdesk: container.read(rustDeskProvider).links,
        uu: container.read(uuRemoteProvider).bindings,
        rustdeskEntries: container.read(rustDeskProvider).entries,
        uuEntries: container.read(uuRemoteProvider).entries);
    final record = links.recordOf(uuBindingRef(R39Fixture.binding));
    expect(record, isNotNull);
    expect(links.recordOf(rustDeskPeerRef(R39Fixture.link)), record);
    expect(
        links.recordOf(catalogDeviceRef(R39Fixture.catalog, R39Fixture.device)),
        record);
    for (final value in cfg.sensitiveValues) {
      expect(jsonEncode(current.toJson()).contains(value), isFalse,
          reason: 'Remote secrets must not appear in the vault export');
    }
    expect(await rdBackend.read('rustdesk.links.v1') == oldRd, isTrue);
    expect(await uuBackend.read('uuremote.bindings.v1') == oldUu, isTrue);
    expect(await uuBackend.read('uuremote.pending.v1') == oldPending, isTrue);
    expect(await rdBackend.read('rustdesk.entries.v2'), isNotNull);
    expect(await uuBackend.read('uuremote.entries.v2'), isNotNull);
    expect(tester.takeException(), isNull);
    await report('passed');
  }, timeout: const Timeout(Duration(minutes: 8)));
}
