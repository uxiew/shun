import 'package:flutter/material.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../application/catalog_overview.dart';
import '../../application/tailscale_catalog_import.dart';
import '../../application/tailscale_catalog_refresh.dart';
import '../../domain/models/host.dart';
import '../../domain/models/server_stats.dart';
import '../../infrastructure/tailscale/catalog_cache.dart';
import '../localization/localized_widgets.dart';
import '../ui/components.dart';
import 'catalog_text.dart';
import 'host_address_line.dart';
import 'host_system_icon.dart';
import 'host_type_icon.dart';
import 'vault_host_items.dart';

/// 主机列表里的 Tailscale 一节（R43，R26 按所有者反馈改过）：本机每个目录来源一组。
///
/// - 组头：来源名、缓存时间和多久前、刷新、Tailscale 设置。点组头收起 / 展开。
/// - 连过（或关联）的设备显示成那台主机：名字是用户起的别名，点了、⋮ 都和普通主机一样；
///   在本机登录成功过的带「✓ 登录过」。
/// - 没连过的设备点了就按来源的默认设置建成主机并连接（F39、R76：用户不用知道有「导入」这一步），
///   用户名、密码缺的在连接时问。⋮ 能隐藏，到「设置 → 安全 → 隐藏的主机」恢复。
/// - 每行一个系统图标；第二行地址前面是在线点，写「在线」「离线 · 上次在线」，和 Tailscale App 里看到的一样（[deviceOnline]）。
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
    required this.onDeviceHide,
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

  final void Function(CatalogCache cache, CatalogDeviceRecord record)
      onDeviceHide;
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
    final colors = prism.Theme.of(context).colorScheme;
    final small = prism.AppTextStyle.subheadline
        .of(context)
        .copyWith(color: colors.onSurfaceVariant);
    final groups = <Widget>[
      for (final (index, group) in catalogSectionGroups(
        sources: widget.sources,
        allHosts: widget.allHosts,
        hosts: widget.hosts,
        query: widget.query,
      ).indexed)
        _group(group.source, group.hosts, group.devices, small,
            first: index == 0),
    ];
    if (groups.isEmpty) return const SizedBox.shrink();
    return Padding(
      key: const ValueKey('vault-catalog-sections'),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: groups,
      ),
    );
  }

  /// 一个来源一组卡片：组头（来源名、状态时间、刷新、设置）和它下面的主机、设备。
  /// 第一组带「Tailscale 设备」小标题，后面的组只留组间距。
  Widget _group(
    CatalogSourceView source,
    List<HostProfile> hosts,
    List<CatalogDeviceRecord> devices,
    TextStyle small, {
    required bool first,
  }) {
    final cache = source.cache;
    final id = cache.catalogId;
    final collapsed = _collapsed.contains(id);
    final success = cache.lastSuccess;
    final attempt = cache.lastAttempt;
    // lastAttempt 每次读取都会覆盖：它失败就是最近一次失败（和来源页同一个读法）。
    final failedLast = attempt != null && !attempt.ok;
    final age = success == null ? null : catalogAge(success.at, widget.now());
    return KeyedSubtree(
      key: ValueKey('vault-catalog-$id'),
      child: ShunSection(
        title: first ? 'Tailscale 设备' : null,
        children: [
          ShunListRow(
            key: ValueKey('vault-catalog-toggle-$id'),
            // 来源名是用户起的（或已经本地化的「未命名来源」）。
            title: catalogSourceName(cache),
            leading: Icon(collapsed ? Icons.chevron_right : Icons.expand_more),
            expanded: !collapsed,
            onTap: () => setState(
                () => collapsed ? _collapsed.remove(id) : _collapsed.add(id)),
            details: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (success == null)
                  const LText('还没成功读过设备列表')
                else
                  catalogLine(
                    '状态截至：',
                    [catalogTime(success.at), if (age != null) age].join(' · '),
                    key: ValueKey('vault-catalog-age-$id'),
                  ),
                if (failedLast)
                  catalogLine('最近一次读取失败：', catalogTime(attempt.at)),
                if (!source.hasSavedCredentials) const LText('未保存 key'),
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
                    tooltip: localized(source.hasSavedCredentials
                        ? '刷新'
                        : '去 Tailscale 设置填 key'),
                    onPressed: () => widget.onRefresh(source),
                    icon: const Icon(Icons.refresh),
                  ),
                IconButton(
                  key: ValueKey('vault-catalog-settings-$id'),
                  tooltip: localized('Tailscale 设置'),
                  onPressed: () => widget.onSettings(id),
                  icon: const Icon(Icons.tune),
                ),
              ],
            ),
          ),
          if (!collapsed) ...[
            for (final host in hosts) _hostRow(host, cache, small),
            for (final record in devices) _deviceRow(cache, record),
            if (hosts.isEmpty && devices.isEmpty)
              const ShunSectionItem(
                child: LText('缓存里还没有设备。读一次设备列表后会出现在这里。'),
              ),
          ],
        ],
      ),
    );
  }

  Widget _hostRow(HostProfile host, CatalogCache cache, TextStyle small) {
    final record = cache.devices[CatalogBinding.of(host)!.deviceId];
    final now = widget.now();
    return ShunListRow(
      key: ValueKey('vault-catalog-host-${host.id}'),
      title: host.label,
      leading:
          HostLeadingIcon(host: host, size: 40, catalogOs: record?.device.os),
      describeLeading: true,
      onTap: () => widget.onConnect(host),
      onLongPress: () => widget.onMenu(host),
      details: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PresenceLine(
            presence: deviceOnline(record),
            child: HostAddressLine(host),
          ),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                  deviceOnlineText(record, now,
                      statusAt: cache.lastSuccess?.at),
                  key: ValueKey('vault-catalog-status-${host.id}')),
              if (host.lastConnectedAt > 0) LoggedInMark(style: small),
            ],
          ),
        ],
      ),
      trailing:
          vaultHostMenuButton(host, () => widget.onMenu(host), Icons.more_vert),
    );
  }

  Widget _deviceRow(CatalogCache cache, CatalogDeviceRecord record) {
    final device = record.device;
    final key = '${cache.catalogId}-${record.id}';
    final now = widget.now();
    return ShunListRow(
      key: ValueKey('vault-catalog-device-$key'),
      title: catalogDeviceName(record),
      leading: SystemIcon(
        distro: normalizeDistroId(device.os ?? ''),
        size: 40,
        label: device.os,
      ),
      describeLeading: true,
      onTap: () => widget.onImport(cache, record.id),
      details: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PresenceLine(
            presence: deviceOnline(record),
            child:
                Text(device.addresses.isEmpty ? '—' : device.addresses.first),
          ),
          Text(deviceOnlineText(record, now, statusAt: cache.lastSuccess?.at),
              key: ValueKey('vault-catalog-device-status-$key')),
        ],
      ),
      // 只有一项的菜单仍用 Material 的：菜单项要带 key（测试和设备脚本按它点），
      // Prism 的菜单项是数据类、挂不上 key。归 R96 收口。
      trailing: PopupMenuButton<bool>(
        key: ValueKey('vault-catalog-device-menu-$key'),
        onSelected: (_) => widget.onDeviceHide(cache, record),
        itemBuilder: (context) => [
          PopupMenuItem(
            key: ValueKey('vault-catalog-device-hide-$key'),
            value: true,
            child: const LText('隐藏'),
          ),
        ],
      ),
    );
  }
}

/// 每个来源这一节要列的主机和没导入的设备，按 [CatalogHostSections] 的规矩：
/// [hosts] 是已经按搜索、隐藏过滤好的；设备按名字、地址、标签搜，没导入、没隐藏的才列。
/// 搜索时一行都没有的来源不在结果里；没在搜时每个来源都在（空的显示「缓存里还没有设备」）。
/// 首页拿它判断「搜不到」：有来源、但这次一行都没有，就该说「没有匹配的主机」，不是一片空白。
List<
    ({
      CatalogSourceView source,
      List<HostProfile> hosts,
      List<CatalogDeviceRecord> devices,
    })> catalogSectionGroups({
  required List<CatalogSourceView> sources,
  required List<HostProfile> allHosts,
  required List<HostProfile> hosts,
  required String query,
}) {
  final imported = _boundDevices(allHosts);
  final needle = query.trim().toLowerCase();
  return [
    for (final source in sources)
      if (_groupOf(source, imported, hosts, needle) case final group?) group,
  ];
}

({
  CatalogSourceView source,
  List<HostProfile> hosts,
  List<CatalogDeviceRecord> devices,
})? _groupOf(
  CatalogSourceView source,
  Set<String> imported,
  List<HostProfile> allVisible,
  String query,
) {
  final cache = source.cache;
  final hosts = [
    for (final host in allVisible)
      if (CatalogBinding.of(host)?.catalogId == cache.catalogId) host,
  ];
  final devices = [
    for (final record in cache.devices.values)
      if (!imported.contains('${cache.catalogId}\n${record.id}') &&
          !cache.hiddenDevices.contains(record.id) &&
          _matches(record, query))
        record,
  ]..sort((a, b) => catalogDeviceName(a)
      .toLowerCase()
      .compareTo(catalogDeviceName(b).toLowerCase()));
  if (query.isNotEmpty && hosts.isEmpty && devices.isEmpty) return null;
  return (source: source, hosts: hosts, devices: devices);
}

Set<String> _boundDevices(List<HostProfile> hosts) => {
      for (final host in hosts)
        if (CatalogBinding.of(host) case final binding?)
          '${binding.catalogId}\n${binding.deviceId}',
    };

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

/// 隐藏了、还没连过的设备。连过的已经是主机，跟着主机自己的隐藏走，不在这里重复一行。
List<({CatalogCache cache, CatalogDeviceRecord record})> hiddenCatalogDevices(
  List<CatalogSourceView> sources,
  List<HostProfile> allHosts,
) {
  final bound = _boundDevices(allHosts);
  return [
    for (final source in sources)
      for (final id in source.cache.hiddenDevices)
        if (source.cache.devices[id] case final record?
            when !bound.contains('${source.catalogId}\n$id'))
          (cache: source.cache, record: record),
  ];
}
