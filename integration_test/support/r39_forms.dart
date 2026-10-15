import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/plugin_discovery.dart';
import 'package:shun/application/plugin_registry.dart';
import 'package:shun/application/rustdesk.dart';
import 'package:shun/application/uuremote.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/plugins/plugin_host.dart';
import 'package:shun/infrastructure/plugins/rustdesk_external.dart';
import 'package:shun/infrastructure/plugins/uuremote_adapter.dart';
import 'package:shun/presentation/widgets/host_editor.dart';

import 'r39_fixture.dart';
import 'r39_ui.dart';

Future<void> r39Forms(
    WidgetTester tester, ProviderContainer container, R39Fixture cfg) async {
  final vault = container.read(vaultControllerProvider.notifier);
  for (final type in ['SSH', 'Mosh', 'Telnet']) {
    await r39Select(tester, type);
    expect(
        tester.widget<HostEditor>(find.byType(HostEditor)).initialProtocol.name,
        type.toLowerCase());
    expect(find.widgetWithText(TextFormField, '用户名'),
        type == 'Telnet' ? findsNothing : findsOneWidget);
    await r39Type(
        tester, find.widgetWithText(TextFormField, '名称'), 'R39 $type');
    await r39Type(
        tester, find.widgetWithText(TextFormField, '主机名 / IP'), 'r39.invalid');
    if (type != 'Telnet') {
      await r39Type(
          tester, find.widgetWithText(TextFormField, '用户名'), 'fixture');
    }
    await r39HideKeyboard(tester);
    await r39Tap(tester, find.widgetWithText(TextButton, '保存'));
    await r39WaitFor(
        tester,
        () =>
            container
                .read(vaultControllerProvider)
                .data
                ?.hosts
                .any((h) => h.label == 'R39 $type') ==
            true,
        reason: '$type save must finish before reading the vault');
    final saved =
        (await vault.ready()).hosts.singleWhere((h) => h.label == 'R39 $type');
    expect(saved.protocol.name, type.toLowerCase());
    await r39Tap(tester, find.text('R39 $type'));
    expect(r39Key('host-rustdesk'), findsNothing);
    expect(r39Key('host-uuremote'), findsNothing);
    await r39Tap(tester, find.text('编辑'));
    expect(
        tester.widget<HostEditor>(find.byType(HostEditor)).host!.id, saved.id);
    await r39Tap(tester, find.byIcon(Icons.close));
  }

  // Explicitly approve only this run's independently signed test APK. Production
  // trust lists and provider implementations remain unchanged.
  final discovery = await container.read(pluginDiscoveryProvider.future);
  await discovery.refresh();
  final echo = container
      .read(pluginRegistryProvider)
      .singleWhere((e) => e.pluginId == 'example.fixture_echo');
  expect(echo.signerDigests, {cfg.fixtureSigner});
  expect(echo.androidDebugSigned, isFalse);
  await discovery.approve(echo);
  await r39Select(tester, 'Echo fixture (test only)');
  expect(find.widgetWithText(TextFormField, '主机名 / IP'), findsNothing);
  expect(find.widgetWithText(TextFormField, '用户名'), findsNothing);
  await r39Type(tester, find.widgetWithText(TextFormField, '名称'), 'R39 plugin');
  await r39HideKeyboard(tester);
  await r39Tap(tester, find.widgetWithText(TextButton, '保存'));
  await r39WaitFor(
      tester,
      () =>
          container
              .read(vaultControllerProvider)
              .data
              ?.hosts
              .any((h) => h.label == 'R39 plugin') ==
          true,
      reason: 'Plugin save must finish before reading the vault');
  final plugin =
      (await vault.ready()).hosts.singleWhere((h) => h.label == 'R39 plugin');
  expect(plugin.protocol.name, 'plugin');
  expect(pluginIdOf(plugin), 'example.fixture_echo');
  await r39Tap(tester, find.text('R39 plugin'));
  await r39Tap(tester, find.text('编辑'));
  expect(
      tester.widget<HostEditor>(find.byType(HostEditor)).host!.id, plugin.id);
  await r39Tap(tester, find.byIcon(Icons.close));

  final hostCount = (await vault.ready()).hosts.length;
  for (final type in ['RustDesk', 'UU 远程']) {
    await r39Select(tester, type);
    await r39Type(tester, r39Key('remote-entry-name'), 'R39 new $type');
    await r39Tap(tester, r39Key('remote-entry-save'));
    await r39WaitFor(
        tester, () => r39Key('remote-entry-actions').evaluate().isNotEmpty,
        reason: 'Remote entry must be persisted and opened');
    expect(find.widgetWithText(TextFormField, '主机名 / IP'), findsNothing);
    expect(find.widgetWithText(TextFormField, '用户名'), findsNothing);
    expect((await vault.ready()).hosts, hasLength(hostCount));
    await r39Tap(tester, r39Key('remote-entry-actions'));
    await r39Tap(tester, find.text('重命名'));
    await r39Type(tester, r39Key('remote-entry-name'), 'R39 renamed $type');
    await r39Tap(tester, r39Key('remote-entry-save'));
    await r39WaitFor(
        tester,
        () => (type == 'RustDesk'
                ? container.read(rustDeskProvider).entries
                : container.read(uuRemoteProvider).entries)
            .any((e) => e.label == 'R39 renamed $type'),
        reason: 'Remote rename must be persisted');
    await tester.pageBack();
    await r39Frames(tester);
    await r39Tap(tester, find.text('R39 renamed $type'));
    if (type == 'RustDesk') {
      final rd = container.read(rustDeskProvider.notifier);
      await rd.refreshApp();
      final status = container.read(rustDeskProvider).app;
      expect(status, isA<RustDeskSignerNeedsApproval>());
      expect((status! as RustDeskSignerNeedsApproval).client.signers,
          {cfg.fixtureSigner});
      await r39Tap(tester, r39Key('rd-approve'));
      await r39WaitFor(
          tester, () => container.read(rustDeskProvider).app is RustDeskReady,
          reason: 'Test RustDesk signer approval must finish');
      await r39Type(tester, r39Key('rd-id-field'), cfg.peer);
      await r39HideKeyboard(tester);
      await r39Tap(tester, r39Key('rd-save'));
      await r39WaitFor(
          tester, () => container.read(rustDeskProvider).links.length == 2,
          reason: 'New RustDesk ID must be persisted before launching');
      await r39Frames(tester);
      await r39Tap(tester, r39Key('rd-launch'), settle: false);
      await r39Gate(tester, 'return-rustdesk');
    } else {
      final uu = container.read(uuRemoteProvider.notifier);
      await uu.refreshApp();
      final status = container.read(uuRemoteProvider).app;
      expect(status, isA<UuSignerNeedsApproval>());
      expect((status! as UuSignerNeedsApproval).signer, cfg.fixtureSigner);
      await r39Tap(tester, r39Key('uu-approve'));
      await r39WaitFor(
          tester, () => container.read(uuRemoteProvider).app is UuReady,
          reason: 'Test UU signer approval must finish');
      await r39Tap(tester, r39Key('uu-bind'), settle: false);
      await r39WaitFor(
          tester, () => r39Key('uu-offer-confirm').evaluate().isNotEmpty,
          reason: 'Native UU callback must open the offer dialog');
      await r39Tap(tester, r39Key('uu-offer-confirm'));
      await r39WaitFor(
          tester, () => container.read(uuRemoteProvider).bindings.length == 2,
          reason: 'Confirmed UU binding must be persisted');
      expect(container.read(uuRemoteProvider).pending, isNull);
      expect(container.read(uuRemoteProvider).bindings, hasLength(2));
      await r39Tap(tester, r39Key('uu-launch-fullscreen'), settle: false);
      await r39Gate(tester, 'return-uu');
    }
    await tester.pageBack();
    await r39Frames(tester);
  }
  // Deleting the source SSH entry must not silently remove its route warning.
  // Exercise the migrated entry itself, not only a newly created lookalike.
  for (final type in ['RustDesk', 'UU 远程']) {
    final isRd = type == 'RustDesk';
    final prefix = isRd ? 'rd' : 'uu';
    await r39Tap(tester, r39Key('remote-$type-${R39Fixture.owner}'));
    final launch = r39Key(isRd ? 'rd-launch' : 'uu-launch-fullscreen');
    await r39Tap(tester, launch);
    expect(r39Key('$prefix-route-accept'), findsOneWidget);
    await r39Tap(tester, find.text('取消'));
    expect(
        isRd
            ? container.read(rustDeskProvider).attempts[R39Fixture.owner]
            : container.read(uuRemoteProvider).attempts[R39Fixture.owner],
        isNull);
    await r39Tap(tester, launch);
    await r39Tap(tester, r39Key('$prefix-route-accept'), settle: false);
    await r39Gate(
        tester, isRd ? 'return-migrated-rustdesk' : 'return-migrated-uu');
    await tester.pageBack();
    await r39Frames(tester);
  }
  await r39Gate(tester, 'shot-entries');
}
