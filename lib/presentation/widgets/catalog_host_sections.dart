import 'package:flutter/material.dart';

import '../../application/catalog_overview.dart';
import '../../application/tailscale_catalog_import.dart';
import '../../application/tailscale_catalog_refresh.dart';
import '../../domain/models/host.dart';
import '../../infrastructure/tailscale/catalog_cache.dart';
import '../localization/localized_widgets.dart';
import 'catalog_text.dart';
import 'host_address_line.dart';
import 'host_type_icon.dart';
import 'vault_host_items.dart';

/// 主机列表里的 Tailscale 一节（R43）：本机每个目录来源一组，不用进目录页就看得到。
///
/// - 组头：来源名、缓存时间和多久前、刷新、来源设置。点组头收起 / 展开，只影响显示。
/// - 导入（或关联）过的设备显示成那台主机：名字是用户起的别名，排法和主机列表一样，点了、⋮ 都和普通主机一样。
/// - 没导入的设备点了走导入页，不连接：目录里有这台设备不代表能连上，要先成为一台主机。
/// - 每行写 Tailscale 控制面已连接 / 未连接 / 不知道，用字不用绿点：这只是设备连没连 Tailscale 的
///   协调服务器，不代表手机能连到它，更不代表 SSH 开着，和真实的 SSH 连接状态是两回事。
/// - 两个来源里同名、同 IP 的设备各在各的组，不合并：认的是（来源 ID，设备 ID），不是名字和地址。
class CatalogHostSections extends StatefulWidget {
  const CatalogHostSections({
    super.key,
    required this.sources,
    required this.allHosts,
    required this.hosts,
    required this.query,
    required this.onConnect,
    required this.onMenu,
    required this.onImport,
    required this.onRefresh,
    required this.onSettings,
    this.now = DateTime.now,
  });

  final List<CatalogSourceView> sources;

  /// 保险库里全部主机（含隐藏的、搜索没命中的）：用来认哪台设备已经导入过，
  /// 藏起来的主机对应的设备不能变成「没导入」。
  final List<HostProfile> allHosts;

  /// 这一节要显示的主机：已按搜索、隐藏过滤、按主机列表的规则排好。
  final List<HostProfile> hosts;
  final String query;
  final ValueChanged<HostProfile> onConnect;
  final ValueChanged<HostProfile> onMenu;
  final void Function(CatalogCache cache, String deviceId) onImport;
  final ValueChanged<CatalogSourceView> onRefresh;
  final ValueChanged<String> onSettings;
  final DateTime Function() now;

  @override
  State<CatalogHostSections> createState() => _CatalogHostSectionsState();
}

class _CatalogHostSectionsState extends State<CatalogHostSections> {
  final _collapsed = <String>{};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final imported = <String>{
      for (final host in widget.allHosts)
        if (CatalogBinding.of(host) case final binding?)
          '${binding.catalogId}\n${binding.deviceId}',
    };
    final query = widget.query.trim().toLowerCase();
    final groups = <Widget>[];
    for (final source in widget.sources) {
      final cache = source.cache;
      final hosts = [
        for (final host in widget.hosts)
          if (CatalogBinding.of(host)?.catalogId == cache.catalogId) host,
      ];
      final devices = [
        for (final record in cache.devices.values)
          if (!imported.contains('${cache.catalogId}\n${record.id}') &&
              _matches(record, query))
            record,
      ]..sort((a, b) => catalogDeviceName(a)
          .toLowerCase()
          .compareTo(catalogDeviceName(b).toLowerCase()));
      if (query.isNotEmpty && hosts.isEmpty && devices.isEmpty) continue;
      groups.add(_group(source, hosts, devices, small));
    }
    if (groups.isEmpty) return const SizedBox.shrink();
    return Padding(
      key: const ValueKey('vault-catalog-sections'),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LText('Tailscale 设备', style: theme.textTheme.titleSmall),
                LText(
                  '状态来自目录缓存：只说设备连没连 Tailscale 控制面，不代表手机能连上它，也不代表 SSH 开着。',
                  style: small,
                ),
              ],
            ),
          ),
          ...groups,
        ],
      ),
    );
  }

  bool _matches(CatalogDeviceRecord record, String query) {
    if (query.isEmpty) return true;
    final device = record.device;
    return [
      catalogDeviceName(record),
      device.name ?? '',
      ...device.addresses,
      ...device.tags,
    ].any((value) => value.toLowerCase().contains(query));
  }

  Widget _group(
    CatalogSourceView source,
    List<HostProfile> hosts,
    List<CatalogDeviceRecord> devices,
    TextStyle? small,
  ) {
    final cache = source.cache;
    final id = cache.catalogId;
    final collapsed = _collapsed.contains(id);
    final success = cache.lastSuccess;
    final attempt = cache.lastAttempt;
    // lastAttempt 每次读取都会覆盖：它失败就是最近一次失败（和来源页同一个读法）。
    final failedLast = attempt != null && !attempt.ok;
    final age = success == null ? null : catalogAge(success.at, widget.now());
    return Card(
      key: ValueKey('vault-catalog-$id'),
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ListTile(
            key: ValueKey('vault-catalog-toggle-$id'),
            onTap: () => setState(() =>
                collapsed ? _collapsed.remove(id) : _collapsed.add(id)),
            contentPadding: const EdgeInsets.only(left: 12, right: 4),
            leading: Icon(collapsed ? Icons.chevron_right : Icons.expand_more),
            title: Text(cache.label ?? id),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (success == null)
                  LText('还没成功读过设备列表', style: small)
                else
                  catalogLine(
                    '状态截至：',
                    [catalogTime(success.at), if (age != null) age].join(' · '),
                    style: small,
                    key: ValueKey('vault-catalog-age-$id'),
                  ),
                if (failedLast)
                  catalogLine('最近一次读取失败：', catalogTime(attempt.at),
                      style: small),
                if (!source.hasSavedCredentials)
                  LText('本机没保存凭据：点刷新会打开来源页，在那里读一次',
                      style: small),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (source.refreshing)
                  const SizedBox.square(
                    dimension: 48,
                    child: Center(
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                else
                  IconButton(
                    key: ValueKey('vault-catalog-refresh-$id'),
                    tooltip: localized(
                        source.hasSavedCredentials ? '刷新' : '去来源页读取'),
                    onPressed: () => widget.onRefresh(source),
                    icon: const Icon(Icons.refresh),
                  ),
                IconButton(
                  key: ValueKey('vault-catalog-settings-$id'),
                  tooltip: localized('来源设置'),
                  onPressed: () => widget.onSettings(id),
                  icon: const Icon(Icons.tune),
                ),
              ],
            ),
          ),
          if (!collapsed) ...[
            for (final host in hosts) _hostRow(host, cache, small),
            for (final record in devices) _deviceRow(cache, record, small),
            if (hosts.isEmpty && devices.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: LText('缓存里还没有设备。读一次设备列表后会出现在这里。', style: small),
              ),
          ],
        ],
      ),
    );
  }

  /// 这台设备在目录里的状态。不在列表里时不再拿上次的控制面状态说事。
  String _status(CatalogDeviceRecord? record) {
    if (record == null) return '目录：缓存里没有这台设备';
    if (record.missing) return '目录：最近完整列表里没有它';
    return controlPlaneText(record.device.connectedToControl);
  }

  Widget _hostRow(HostProfile host, CatalogCache cache, TextStyle? small) {
    final record = cache.devices[CatalogBinding.of(host)!.deviceId];
    return dimIfHidden(
      host,
      ListTile(
        key: ValueKey('vault-catalog-host-${host.id}'),
        onTap: () => widget.onConnect(host),
        onLongPress: () => widget.onMenu(host),
        leading: HostLeadingIcon(host: host, size: 40),
        title: LText(host.label),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            HostAddressLine(host),
            LText(_status(record),
                key: ValueKey('vault-catalog-status-${host.id}'), style: small),
          ],
        ),
        trailing:
            vaultHostMenuButton(host, () => widget.onMenu(host), Icons.more_vert),
      ),
    );
  }

  Widget _deviceRow(
      CatalogCache cache, CatalogDeviceRecord record, TextStyle? small) {
    final device = record.device;
    final address = [
      if (device.addresses.isNotEmpty) device.addresses.first,
      if (device.os != null) device.os!,
    ].join(' · ');
    final key = '${cache.catalogId}-${record.id}';
    return ListTile(
      key: ValueKey('vault-catalog-device-$key'),
      onTap: () => widget.onImport(cache, record.id),
      leading: const SizedBox.square(
        dimension: 40,
        child: Icon(Icons.devices_other_outlined),
      ),
      title: Text(catalogDeviceName(record)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (address.isNotEmpty) Text(address),
          LText(_status(record),
              key: ValueKey('vault-catalog-device-status-$key'), style: small),
          LText('还没导入：点一下导入为主机，不会连接', style: small),
        ],
      ),
      trailing: Tooltip(
        message: localized('导入'),
        child: const Icon(Icons.download_outlined),
      ),
    );
  }
}
