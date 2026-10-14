import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_api/plugin_api.dart';
import 'package:shun/application/device_links.dart';
import 'package:shun/application/external_remote.dart';
import 'package:shun/application/plugin_registry.dart';
import 'package:shun/application/rustdesk.dart';
import 'package:shun/application/tailscale_catalog_refresh.dart';
import 'package:shun/application/uuremote.dart';
import 'package:shun/domain/device_references.dart';
import 'package:shun/domain/plugins/builtin_plugins.dart';
import 'package:shun/domain/remote_entry.dart';
import 'package:shun/infrastructure/plugins/rustdesk_external.dart';
import 'package:shun/infrastructure/plugins/uuremote_adapter.dart';
import 'package:shun/infrastructure/storage/remote_entry_store.dart';

import 'rustdesk_fakes.dart';
import 'uuremote_fakes.dart';

final now = DateTime.utc(2026, 10, 13, 10);
const hosts = [
  RemoteControlHost(
      id: 'old',
      label: '工作机',
      sshRoute: RequestedRoute.socks5ProxyJump,
      catalogId: 'catalog-a',
      deviceId: 'node-a')
];

Map<String, Object?> rdRow([String owner = 'old']) => RustDeskLink(
        id: 'rd-link',
        hostId: owner,
        peer: RustDeskPeerId.parse('123456789'),
        createdAt: now)
    .toJson();
Map<String, Object?> uuRow() => UuBinding(
        id: 'uu-binding',
        hostId: 'old',
        anonymousDeviceId: 'opaque-local-secret',
        createdAt: now)
    .toJson();
UuPendingRequest request(UuCallbackKind kind) => UuPendingRequest(
    kind: kind,
    state: 'abcdefghijklmnopqrstuv',
    nonce: kind == UuCallbackKind.bind ? 'nonce-original' : null,
    hostId: 'old',
    bindingId: kind == UuCallbackKind.control ? 'uu-binding' : null,
    createdAt: now,
    expiresAt: now.add(const Duration(minutes: 10)));
PluginRegistry registry() =>
    PluginRegistry(policy: AdmissionPolicy(builtinIds: BuiltinPlugins.ids));

class FailingBackend extends MemoryBackend {
  bool failWrite = false;
  bool failReadBack = false;
  bool persisted = false;
  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw StateError('backend-secret-must-not-leak');
    await super.write(key, value);
    if (key.endsWith('.entries.v2')) persisted = true;
  }

  @override
  Future<String?> read(String key) async {
    if (failReadBack && persisted && key.endsWith('.entries.v2')) {
      throw StateError('backend-secret-must-not-leak');
    }
    return super.read(key);
  }
}

void main() {
  test(
      'RustDesk migration preserves IDs, explicit sources, route warning and v1 recovery copy',
      () async {
    final backend = MemoryBackend();
    final original = jsonEncode([rdRow()]);
    backend.values['rustdesk.links.v1'] = original;
    backend.values['rustdesk.trust.v1'] = 'preserve-trust';
    final store = RustDeskStore(backend);
    await store.local.initialize(() async => hosts);
    final entry = store.local.entries.single;
    expect(entry.id, 'old');
    expect(entry.label, '工作机');
    expect(entry.sourceHostId, 'old');
    expect(entry.sourceCatalogId, 'catalog-a');
    expect(entry.sourceDeviceId, 'node-a');
    expect(entry.routeWarning, RequestedRoute.socks5ProxyJump);
    expect((await store.links()).single.toJson(), rdRow());
    expect(backend.values['rustdesk.links.v1'], original);
    expect(backend.values['rustdesk.trust.v1'], 'preserve-trust');
    await store.local
        .initialize(() async => throw StateError('do not reread vault'));
    expect(store.local.entries, hasLength(1));
    await store.local.deleteEntry('old');
    await store.local.initialize(() async => hosts);
    expect(store.local.entries, isEmpty,
        reason: 'v1 must never resurrect deleted entries');
    expect(await store.links(), isEmpty);
  });

  test('orphaned legacy owner still becomes a usable independent entry',
      () async {
    final backend = MemoryBackend();
    backend.values['rustdesk.links.v1'] = jsonEncode([rdRow('removed-ssh')]);
    final c = RustDeskController(
        platform: FakeRustDeskPlatform(),
        store: RustDeskStore(backend),
        registry: registry(),
        hosts: () async => []);
    addTearDown(c.dispose);
    await c.ready;
    expect(c.state.entries.single.id, 'removed-ssh');
    await c.launch('removed-ssh');
    expect(c.state.attempts['removed-ssh']!.phase,
        ExternalLaunchPhase.launchedUnverified);
  });

  for (final failure in ['before-write', 'after-write']) {
    test(
        'migration interruption $failure is retryable without duplicate records or loss',
        () async {
      final backend = FailingBackend();
      final original = jsonEncode([rdRow()]);
      backend.values['rustdesk.links.v1'] = original;
      backend.failWrite = failure == 'before-write';
      backend.failReadBack = failure == 'after-write';
      final store = RustDeskStore(backend);
      await expectLater(store.local.initialize(() async => hosts),
          throwsA(isA<RemoteEntryStorageException>()));
      expect(() => store.local.entries,
          throwsA(isA<RemoteEntryStorageException>()));
      expect(backend.values['rustdesk.links.v1'], original);
      backend.failWrite = backend.failReadBack = false;
      final restarted = RustDeskStore(backend);
      await restarted.local.initialize(() async => hosts);
      expect(restarted.local.entries, hasLength(1));
      expect((await restarted.links()).single.peer.value, '123456789');
    });
  }

  test(
      'malformed and ambiguous legacy records block migration without overwriting either source',
      () async {
    for (final rows in [
      '{bad-json',
      jsonEncode([rdRow(), rdRow()]),
      jsonEncode([
        rdRow(),
        {...rdRow(), 'id': 'other'}
      ]),
      jsonEncode([
        {...rdRow(), 'peerId': 'rustdesk://password/secret'}
      ])
    ]) {
      final backend = MemoryBackend();
      backend.values['rustdesk.links.v1'] = rows;
      final store = RustDeskStore(backend);
      await expectLater(store.local.initialize(() async => hosts),
          throwsA(isA<RemoteEntryStorageException>()));
      expect(backend.values, {'rustdesk.links.v1': rows});
    }
  });

  test(
      'corrupt v2 never falls back to potentially stale v1 or accepts new writes',
      () async {
    final backend = MemoryBackend();
    backend.values.addAll({
      'rustdesk.links.v1': jsonEncode([rdRow()]),
      'rustdesk.entries.v2': '{bad-json'
    });
    final platform = FakeRustDeskPlatform();
    final c = RustDeskController(
        platform: platform,
        store: RustDeskStore(backend),
        registry: registry(),
        hosts: () async => hosts);
    addTearDown(c.dispose);
    await c.ready;
    expect(c.state.notice, contains('迁移失败'));
    await expectLater(
        c.createEntry('new'), throwsA(isA<RemoteEntryStorageException>()));
    await expectLater(
        c.launch('old'), throwsA(isA<RemoteEntryStorageException>()));
    expect(platform.launched, isEmpty);
    expect(backend.values['rustdesk.entries.v2'], '{bad-json');
  });

  for (final kind in UuCallbackKind.values) {
    test(
        'UU ${kind.name} pending migration keeps owner/state/nonce/expiry across a cold restart',
        () async {
      final backend = MemoryBackend();
      backend.values['uuremote.bindings.v1'] =
          jsonEncode(kind == UuCallbackKind.bind ? [] : [uuRow()]);
      backend.values['uuremote.pending.v1'] =
          jsonEncode(request(kind).toJson());
      backend.values['uuremote.approvedSigner.v1'] = 'cert-a';
      final store = UuRemoteStore(backend);
      await store.local.initialize(() async => hosts);
      expect((await store.pending())!.toJson(), request(kind).toJson());
      expect(store.local.entries.single.id, 'old');
      final platform = FakePlatform();
      final c = UuRemoteController(
          platform: platform,
          store: UuRemoteStore(backend),
          registry: registry(),
          hosts: () async => [],
          now: () => now.add(const Duration(minutes: 3)));
      addTearDown(c.dispose);
      await c.ready;
      expect(c.state.pending!.expiresAt, now.add(const Duration(minutes: 10)));
      expect(platform.launched, isEmpty,
          reason: 'migration must not resend authorization or control');
      final callback =
          '${UuRequests.callback(kind, request(kind).state)}&${kind == UuCallbackKind.bind ? 'nonce=nonce-original&anonymous_device_id=opaque-new-secret' : 'status=success'}';
      platform.deliver(callback);
      await Future<void>.delayed(Duration.zero);
      expect(c.state.pending, isNull);
      if (kind == UuCallbackKind.bind) {
        expect(c.state.offer!.hostId, 'old');
        await c.confirmOffer();
        expect(c.state.bindings.single.anonymousDeviceId, 'opaque-new-secret');
        expect(platform.launched, isEmpty);
      } else {
        expect(c.state.attempts['old']!.phase,
            ExternalLaunchPhase.providerReportedSuccess);
      }
      platform.deliver(callback);
      await Future<void>.delayed(Duration.zero);
      expect(c.state.notice, contains('没有对应的请求'));
      expect(c.state.offer, isNull);
    });
  }

  test(
      'expired UU pending is not revived; mismatched control binding blocks migration',
      () async {
    final backend = MemoryBackend();
    backend.values['uuremote.pending.v1'] =
        jsonEncode(request(UuCallbackKind.bind).toJson());
    final c = UuRemoteController(
        platform: FakePlatform(),
        store: UuRemoteStore(backend),
        registry: registry(),
        hosts: () async => [],
        now: () => now.add(const Duration(minutes: 11)));
    addTearDown(c.dispose);
    await c.ready;
    expect(c.state.pending, isNull);
    expect(c.state.entries, hasLength(1));
    final other = MemoryBackend();
    other.values['uuremote.bindings.v1'] = jsonEncode([uuRow()]);
    other.values['uuremote.pending.v1'] = jsonEncode(
        {...request(UuCallbackKind.control).toJson(), 'hostId': 'different'});
    await expectLater(UuRemoteStore(other).local.initialize(() async => hosts),
        throwsA(isA<RemoteEntryStorageException>()));
    expect(other.values.containsKey('uuremote.entries.v2'), isFalse);
  });

  test(
      'independent RustDesk creates, renames, persists and launches with no SSH data or route lookup',
      () async {
    final backend = MemoryBackend();
    final platform = FakeRustDeskPlatform();
    final c = RustDeskController(
        platform: platform,
        store: RustDeskStore(backend),
        registry: registry(),
        hosts: () async => throw StateError('new entries must not read SSH'));
    addTearDown(c.dispose);
    await c.ready;
    final id = await c.createEntry(' only remote ');
    await c.saveLink(id, '123 456 789');
    await c.renameEntry(id, 'renamed');
    expect(c.state.entries.single.label, 'renamed');
    expect(platform.launched, isEmpty);
    await c.launch(id);
    expect(platform.launched.single.$1, 'rustdesk://connect/123456789');
    final reopened = RustDeskStore(backend);
    await reopened.local.initialize(() async => throw StateError('no vault'));
    expect(reopened.local.entries.single.sourceHostId, isNull);
    expect((await reopened.links()).single.hostId, id);
    expect(reopened.local.entries.single.toJson().toString(),
        isNot(contains('123456789')));
  });

  test(
      'UU delete atomically revokes only its pending callback, including after cold restart',
      () async {
    final backend = MemoryBackend();
    final platform = FakePlatform();
    final c = UuRemoteController(
        platform: platform,
        store: UuRemoteStore(backend),
        registry: registry(),
        hosts: () async => []);
    addTearDown(c.dispose);
    await c.ready;
    await c.approveSigner('cert-a');
    final ids = await Future.wait([c.createEntry('one'), c.createEntry('two')]);
    await c.startBind(ids.first);
    final pending = c.state.pending!;
    await c.deleteEntry(ids.last);
    expect(c.state.pending!.state, pending.state);
    await c.deleteEntry(ids.first);
    expect(c.state.entries, isEmpty);
    expect(c.state.pending, isNull);
    final store = UuRemoteStore(backend);
    await store.local.initialize(() async => []);
    expect(await store.pending(), isNull);
    platform.deliver(
        '${UuRequests.callback(UuCallbackKind.bind, pending.state)}&nonce=${pending.nonce}&anonymous_device_id=opaque');
    await Future<void>.delayed(Duration.zero);
    expect(c.state.offer, isNull);
  });

  test('legacy deleted binding can still have a pending control callback',
      () async {
    final backend = MemoryBackend();
    backend.values['uuremote.bindings.v1'] = jsonEncode([
      {...uuRow(), 'id': 'other-binding', 'hostId': 'other'}
    ]);
    backend.values['uuremote.pending.v1'] =
        jsonEncode(request(UuCallbackKind.control).toJson());
    backend.values['uuremote.approvedSigner.v1'] = 'cert-a';
    final platform = FakePlatform();
    final c = UuRemoteController(
        platform: platform,
        store: UuRemoteStore(backend),
        registry: registry(),
        hosts: () async => hosts,
        now: () => now);
    addTearDown(c.dispose);
    await c.ready;
    expect(c.state.notice, isNull);
    expect(c.state.pending?.hostId, 'old');
    expect(c.state.entries.map((e) => e.id), containsAll(['old', 'other']));
    platform.deliver(
        '${UuRequests.callback(UuCallbackKind.control, request(UuCallbackKind.control).state)}&status=failure&reason=device_not_found');
    await Future<void>.delayed(Duration.zero);
    expect(c.state.pending, isNull);
    expect(c.state.bindings.single.id, 'other-binding');
    expect(c.state.bindings.single.valid, isTrue);
    expect(platform.launched, isEmpty);
  });

  test(
      'device references survive migration and SSH deletion; equal names never link new entries',
      () async {
    final rdBackend = MemoryBackend()
      ..values['rustdesk.links.v1'] = jsonEncode([rdRow()]);
    final uuBackend = MemoryBackend()
      ..values['uuremote.bindings.v1'] = jsonEncode([uuRow()]);
    final rd = RustDeskStore(rdBackend);
    final uu = UuRemoteStore(uuBackend);
    await rd.local.initialize(() async => hosts);
    await uu.local.initialize(() async => hosts);
    final links = deviceLinksOf(
        hosts: const [
          CatalogHost(
              id: 'old',
              label: '工作机',
              hostname: 'host',
              binding:
                  CatalogBinding(catalogId: 'catalog-a', deviceId: 'node-a'))
        ],
        uu: await uu.bindings(),
        rustdesk: await rd.links(),
        uuEntries: uu.local.entries,
        rustdeskEntries: rd.local.entries);
    expect(
        links.records.single.refs,
        containsAll([
          uuBindingRef('uu-binding'),
          rustDeskPeerRef('rd-link'),
          catalogDeviceRef('catalog-a', 'node-a'),
          sshHostRef('old', displayName: '工作机')
        ]));
    final orphan = deviceLinksOf(
        hosts: [],
        uu: await uu.bindings(),
        rustdesk: await rd.links(),
        uuEntries: uu.local.entries,
        rustdeskEntries: rd.local.entries);
    expect(orphan.records.single.refs, hasLength(3));
    expect(orphan.records.single.refs.toString(),
        isNot(contains('opaque-local-secret')));
    final independent = deviceLinksOf(
        hosts: [],
        uu: await uu.bindings(),
        rustdesk: await rd.links(),
        uuEntries: const [RemoteEntry(id: 'old', label: 'same')],
        rustdeskEntries: const [RemoteEntry(id: 'old', label: 'same')]);
    expect(independent.records, isEmpty);
  });
}
