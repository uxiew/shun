import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/catalog_overview.dart';
import '../../application/host_actions.dart';
import '../../application/tailscale_catalog_import.dart';
import '../../application/tailscale_catalog_provider.dart';
import '../../application/vault_controller.dart';
import '../../domain/models/host.dart';
import '../../domain/models/server_stats.dart';
import '../localization/localized_widgets.dart';
import '../widgets/catalog_host_sections.dart';
import '../widgets/empty_state.dart';
import '../widgets/host_address_line.dart';
import '../widgets/host_system_icon.dart';

/// 隐藏的主机和 Tailscale 设备都在这里恢复（所有者 11-02）。连接页不再有入口：藏起来就是不想看见。
class HiddenHostsScreen extends ConsumerStatefulWidget {
  const HiddenHostsScreen({super.key});

  @override
  ConsumerState<HiddenHostsScreen> createState() => _HiddenHostsScreenState();
}

class _HiddenHostsScreenState extends ConsumerState<HiddenHostsScreen> {
  @override
  void initState() {
    super.initState();
    // 从设置页进来时总览可能还是旧的缓存。
    unawaited(ref.read(catalogOverviewProvider.notifier).reload());
  }

  Future<void> _restoreDevice(String catalogId, String deviceId) async {
    try {
      await ref
          .read(tailscaleCatalogProvider)
          .setDeviceHidden(catalogId, deviceId, hidden: false);
      await ref.read(catalogOverviewProvider.notifier).reload();
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final allHosts =
        ref.watch(vaultControllerProvider).data?.hosts ?? const <HostProfile>[];
    final hosts = allHosts.where((host) => host.hidden).toList()
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    final devices =
        hiddenCatalogDevices(ref.watch(catalogOverviewProvider), allHosts);
    return Scaffold(
      appBar: AppBar(title: const LText('隐藏的主机')),
      body: hosts.isEmpty && devices.isEmpty
          ? const EmptyState(
              icon: Icons.visibility_outlined,
              title: '没有隐藏的主机',
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
              children: [
                for (final host in hosts)
                  ListTile(
                    key: ValueKey('hidden-host-${host.id}'),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    leading: HostSystemIcon(host: host, size: 40),
                    title: Text(host.label),
                    subtitle: HostAddressLine(host),
                    trailing: TextButton(
                      key: ValueKey('hidden-restore-${host.id}'),
                      onPressed: () => unawaited(ref
                          .read(vaultControllerProvider.notifier)
                          .updateHost(host.id,
                              (current) => withHidden(current, false))),
                      child: const LText('恢复显示'),
                    ),
                  ),
                for (final (:cache, :record) in devices)
                  ListTile(
                    key: ValueKey(
                        'hidden-device-${cache.catalogId}-${record.id}'),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    leading: SystemIcon(
                      distro: normalizeDistroId(record.device.os ?? ''),
                      size: 40,
                      label: record.device.os,
                    ),
                    title: Text(catalogDeviceName(record)),
                    subtitle: Text(record.device.addresses.firstOrNull ?? '—'),
                    trailing: TextButton(
                      key: ValueKey(
                          'hidden-restore-${cache.catalogId}-${record.id}'),
                      onPressed: () =>
                          _restoreDevice(cache.catalogId, record.id),
                      child: const LText('恢复显示'),
                    ),
                  ),
              ],
            ),
    );
  }
}
