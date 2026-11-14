import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plugin_api/plugin_api.dart';
import '../../application/plugin_host_session.dart';
import '../../application/plugin_registry.dart';
import '../../application/rustdesk.dart';
import '../../application/uuremote.dart';
import '../../domain/models/host.dart';
import '../../infrastructure/plugins/rustdesk_external.dart';
import '../../infrastructure/plugins/uuremote_adapter.dart';
import '../ui/components.dart';
import 'host_type_icon.dart';

enum RemoteConnectionType { rustdesk, uu }

class ConnectionTypeChoice {
  const ConnectionTypeChoice.terminal(this.protocol, {this.pluginId})
      : remote = null,
        name = null,
        tailscale = false;
  const ConnectionTypeChoice.remote(this.remote, {this.name})
      : protocol = null,
        pluginId = null,
        tailscale = false;

  /// 从 Tailscale 添加（R26）：打开 Tailscale 设置，不建主机。
  const ConnectionTypeChoice.tailscale()
      : protocol = null,
        pluginId = null,
        remote = null,
        name = null,
        tailscale = true;
  final HostProtocol? protocol;
  final String? pluginId;
  final RemoteConnectionType? remote;

  /// RustDesk、UU 的条目名称：在表单里填好带过来。
  final String? name;
  final bool tailscale;
}

/// 能当终端类型选的第三方插件。Mosh 单独占一段，不算在内。
List<PluginEntry> terminalPluginEntries(List<PluginEntry> entries) => entries
    .where(
      (e) =>
          !e.isBuiltin &&
          e.pluginId != 'shun.mosh' &&
          e.descriptor?.capabilities.contains(Capability.terminalSession) ==
              true &&
          e.descriptor?.permissions.contains(
                Permission.ownSessionEphemeralSecret,
              ) ==
              false,
    )
    .toList();

/// Mosh 现在能不能选上用：写在类型那一行下面。
String moshTypeStatus(WidgetRef ref) {
  final discovery = ref.watch(pluginHostDiscoveryProvider);
  final entries = ref.watch(pluginRegistryProvider);
  final mosh = entries.where((e) => e.pluginId == 'shun.mosh').firstOrNull;
  final ready = mosh?.status == PluginStatus.ready &&
      mosh!.descriptor!.capabilities.contains(Capability.terminalSession) &&
      mosh.descriptor!.permissions.contains(
        Permission.ownSessionEphemeralSecret,
      ) &&
      checkRoute(
        mosh.descriptor!,
        TransportKind.udp,
        RequestedRoute.systemDefault,
      ) is! RouteUnsupported;
  if (defaultTargetPlatform != TargetPlatform.android) return '仅支持 Android';
  if (discovery.isLoading) return '正在检查插件';
  if (discovery.hasError) return '插件检查失败，请重试';
  if (ready) return '仅直连';
  return mosh == null ? '未装插件' : 'Mosh 插件不可用：${mosh.status.name}';
}

/// RustDesk、UU 客户端的状态。能用就没有字（UU 始终写它只能控制什么）。
String? remoteTypeStatus(WidgetRef ref, RemoteConnectionType type) {
  switch (type) {
    case RemoteConnectionType.rustdesk:
      final rd = ref.watch(rustDeskProvider);
      return rd.notice ??
          switch (rd.app) {
            RustDeskReady() => null,
            RustDeskNotInstalled() => '未安装',
            RustDeskPlatformUnsupported() => '仅支持 Android',
            RustDeskVersionTooOld() => '版本过旧，请更新客户端',
            RustDeskSignerNeedsApproval() => '签名证书待批准',
            RustDeskSignerChanged() => '签名证书已变化，需要重新核对',
            RustDeskSignerUnsupported() => '不支持多签名客户端',
            null => '正在检查客户端',
          };
    case RemoteConnectionType.uu:
      final uu = ref.watch(uuRemoteProvider);
      return uu.notice ??
          switch (uu.app) {
            UuReady() => uu.callbackRivals.isEmpty
                ? '只能控制 Windows/macOS'
                : '回调地址冲突，绑定不可用',
            UuNotInstalled() => '未安装',
            UuPlatformUnsupported() => '仅支持 Android',
            UuVersionTooOld() => '版本过旧，请更新客户端',
            UuSchemeNotHandled() => '客户端不接受跨 App 请求',
            UuSignerNeedsApproval() => '签名证书待批准',
            UuSignerChanged() => '签名证书已变化，需要重新核对',
            UuSignerUnsupported() => '不支持多签名客户端',
            null => '正在检查客户端',
          };
  }
}

/// 「连接类型」里「更多」点开的面板（F39）。SSH、Mosh、Telnet 在表单上点一下就换，不在这里。
/// [terminalsOnly]：编辑已有主机时只能在终端类型里换，RustDesk、UU、Tailscale 不是同一种记录。
Future<ConnectionTypeChoice?> showConnectionTypeSheet(
  BuildContext context, {
  required HostProtocol current,
  String? currentPluginId,
  RemoteConnectionType? currentRemote,
  bool terminalsOnly = false,
}) =>
    showModalBottomSheet<ConnectionTypeChoice>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => ConnectionTypeSheet(
        current: current,
        currentPluginId: currentPluginId,
        currentRemote: currentRemote,
        terminalsOnly: terminalsOnly,
      ),
    );

/// Selection only: probes installed clients, never authorizes, installs or launches.
class ConnectionTypeSheet extends ConsumerStatefulWidget {
  const ConnectionTypeSheet({
    super.key,
    required this.current,
    this.currentPluginId,
    this.currentRemote,
    this.terminalsOnly = false,
  });

  final HostProtocol current;
  final String? currentPluginId;
  final RemoteConnectionType? currentRemote;
  final bool terminalsOnly;

  @override
  ConsumerState<ConnectionTypeSheet> createState() =>
      _ConnectionTypeSheetState();
}

class _ConnectionTypeSheetState extends ConsumerState<ConnectionTypeSheet> {
  late final AppLifecycleListener _lifecycle;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
    _lifecycle = AppLifecycleListener(onResume: _refresh);
  }

  void _refresh() {
    ref.invalidate(pluginHostDiscoveryProvider);
    unawaited(
      ref
          .read(rustDeskProvider.notifier)
          .refreshApp()
          .catchError((Object _) {}),
    );
    unawaited(
      ref
          .read(uuRemoteProvider.notifier)
          .refreshApp()
          .catchError((Object _) {}),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final discovery = ref.watch(pluginHostDiscoveryProvider);
    final entries = ref.watch(pluginRegistryProvider);
    final android = defaultTargetPlatform == TargetPlatform.android;
    final terminalPlugins = terminalPluginEntries(entries);
    bool selected(ConnectionTypeChoice value) => value.remote != null
        ? value.remote == widget.currentRemote
        : widget.currentRemote == null &&
            value.protocol != null &&
            value.protocol == widget.current &&
            value.pluginId == widget.currentPluginId;
    // 状态只写限制和问题；能用就不写「可用」（docs/dev/ui-text.md）。
    // R88：一类一组分组卡片（和设置页同一套），当前那项打勾、读屏报「已选中」。
    Widget choice(
      String title,
      IconData icon,
      String? status,
      ConnectionTypeChoice value, {
      bool enabled = true,
    }) =>
        ShunListRow(
          key: ValueKey('connection-type-$title'),
          leading: Icon(icon),
          title: title,
          subtitle: status,
          selected: selected(value),
          enabled: enabled,
          onTap: enabled ? () => Navigator.pop(context, value) : null,
        );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (terminalPlugins.isNotEmpty)
            ShunSection(
              title: '终端插件',
              children: [
                for (final entry in terminalPlugins)
                  choice(
                    entry.descriptor!.displayName,
                    hostProtocolIcon(HostProtocol.plugin)!,
                    discovery.isLoading
                        ? '正在检查插件'
                        : discovery.hasError
                            ? '插件检查失败，请重试'
                            : pluginHostAvailability(entries, entry.pluginId)
                                .problem,
                    ConnectionTypeChoice.terminal(
                      HostProtocol.plugin,
                      pluginId: entry.pluginId,
                    ),
                    enabled: android &&
                        !discovery.isLoading &&
                        !discovery.hasError &&
                        pluginHostAvailability(entries, entry.pluginId).entry !=
                            null,
                  ),
              ],
            ),
          if (!widget.terminalsOnly) ...[
            ShunSection(
              title: '从 Tailscale 添加',
              hint:
                  '填一个 Tailscale 的 key，自动列出 tailnet 里的设备，点一下就导入并连接。只读设备列表，不开 VPN。',
              children: [
                choice(
                  'Tailscale',
                  Icons.hub_outlined,
                  null,
                  const ConnectionTypeChoice.tailscale(),
                ),
              ],
            ),
            ShunSection(
              title: '远程桌面',
              hint: '交给手机上的外部 App 去连，用它自己的网络，不走 SSH 的代理或跳板。没装也能先保存条目。',
              children: [
                choice(
                  'RustDesk',
                  Icons.connected_tv_outlined,
                  remoteTypeStatus(ref, RemoteConnectionType.rustdesk),
                  const ConnectionTypeChoice.remote(
                      RemoteConnectionType.rustdesk),
                ),
                choice(
                  'UU 远程',
                  Icons.desktop_windows_outlined,
                  remoteTypeStatus(ref, RemoteConnectionType.uu),
                  const ConnectionTypeChoice.remote(RemoteConnectionType.uu),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
