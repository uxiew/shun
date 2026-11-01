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
import '../localization/localized_widgets.dart';
import 'hint.dart';
import 'host_type_icon.dart';

enum RemoteConnectionType { rustdesk, uu }

class ConnectionTypeChoice {
  const ConnectionTypeChoice.terminal(this.protocol, {this.pluginId})
      : remote = null,
        tailscale = false;
  const ConnectionTypeChoice.remote(this.remote)
      : protocol = null,
        pluginId = null,
        tailscale = false;

  /// 从 Tailscale 添加（R26）：打开 Tailscale 设置，不建主机。
  const ConnectionTypeChoice.tailscale()
      : protocol = null,
        pluginId = null,
        remote = null,
        tailscale = true;
  final HostProtocol? protocol;
  final String? pluginId;
  final RemoteConnectionType? remote;
  final bool tailscale;
}

/// 新建连接表单顶上的「连接类型」点开的面板（F39，取代原来挡在表单前的整页）。
/// [terminalsOnly]：编辑已有主机时只能在终端类型里换，RustDesk、UU、Tailscale 不是同一种记录。
Future<ConnectionTypeChoice?> showConnectionTypeSheet(
  BuildContext context, {
  required HostProtocol current,
  String? currentPluginId,
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
        terminalsOnly: terminalsOnly,
      ),
    );

/// Selection only: probes installed clients, never authorizes, installs or launches.
class ConnectionTypeSheet extends ConsumerStatefulWidget {
  const ConnectionTypeSheet({
    super.key,
    required this.current,
    this.currentPluginId,
    this.terminalsOnly = false,
  });

  final HostProtocol current;
  final String? currentPluginId;
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
    final rd = ref.watch(rustDeskProvider);
    final uu = ref.watch(uuRemoteProvider);
    final android = defaultTargetPlatform == TargetPlatform.android;
    final mosh = entries.where((e) => e.pluginId == 'shun.mosh').firstOrNull;
    final moshReady = mosh?.status == PluginStatus.ready &&
        mosh!.descriptor!.capabilities.contains(Capability.terminalSession) &&
        mosh.descriptor!.permissions.contains(
          Permission.ownSessionEphemeralSecret,
        ) &&
        checkRoute(
          mosh.descriptor!,
          TransportKind.udp,
          RequestedRoute.systemDefault,
        ) is! RouteUnsupported;
    final terminalPlugins = entries
        .where(
          (e) =>
              !e.isBuiltin &&
              e.pluginId != 'shun.mosh' &&
              e.descriptor?.capabilities.contains(
                    Capability.terminalSession,
                  ) ==
                  true &&
              e.descriptor?.permissions.contains(
                    Permission.ownSessionEphemeralSecret,
                  ) ==
                  false,
        )
        .toList();
    final moshStatus = !android
        ? '仅支持 Android'
        : discovery.isLoading
            ? '正在检查插件'
            : discovery.hasError
                ? '插件检查失败，请重试'
                : moshReady
                    ? '仅直连'
                    : mosh == null
                        ? '未装插件'
                        : 'Mosh 插件不可用：${mosh.status.name}';
    bool selected(ConnectionTypeChoice value) =>
        value.protocol != null &&
        value.protocol == widget.current &&
        (value.protocol != HostProtocol.plugin ||
            value.pluginId == widget.currentPluginId);
    // 状态只写限制和问题；能用就不写「可用」（docs/dev/ui-text.md）。
    Widget choice(
      String title,
      IconData icon,
      String? status,
      ConnectionTypeChoice value, {
      bool enabled = true,
    }) =>
        ListTile(
          key: ValueKey('connection-type-$title'),
          leading: Icon(icon),
          title: LText(title),
          subtitle: status == null ? null : LText(status),
          trailing: selected(value) ? const Icon(Icons.check) : null,
          enabled: enabled,
          onTap: enabled ? () => Navigator.pop(context, value) : null,
        );
    Widget section(String title, {String? hint}) => Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            8,
            16,
            hint == null ? 8 : 0,
          ),
          child: HintTitle(
            title,
            hint: hint,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        );
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        section('终端'),
        choice(
          'SSH',
          hostProtocolIcon(HostProtocol.ssh)!,
          null,
          const ConnectionTypeChoice.terminal(HostProtocol.ssh),
        ),
        choice(
          'Mosh',
          hostProtocolIcon(HostProtocol.mosh)!,
          moshStatus,
          const ConnectionTypeChoice.terminal(HostProtocol.mosh),
        ),
        choice(
          'Telnet',
          hostProtocolIcon(HostProtocol.telnet)!,
          '明文，仅直连',
          const ConnectionTypeChoice.terminal(HostProtocol.telnet),
        ),
        for (final entry in terminalPlugins)
          choice(
            entry.descriptor!.displayName,
            hostProtocolIcon(HostProtocol.plugin)!,
            discovery.isLoading
                ? '正在检查插件'
                : discovery.hasError
                    ? '插件检查失败，请重试'
                    : pluginHostAvailability(entries, entry.pluginId).problem,
            ConnectionTypeChoice.terminal(
              HostProtocol.plugin,
              pluginId: entry.pluginId,
            ),
            enabled: android &&
                !discovery.isLoading &&
                !discovery.hasError &&
                pluginHostAvailability(entries, entry.pluginId).entry != null,
          ),
        if (!widget.terminalsOnly) ...[
          const SizedBox(height: 8),
          section(
            '从 Tailscale 添加',
            hint:
                '填一个 Tailscale 的 key，自动列出 tailnet 里的设备，点一下就导入并连接。只读设备列表，不开 VPN。',
          ),
          choice(
            'Tailscale',
            Icons.hub_outlined,
            null,
            const ConnectionTypeChoice.tailscale(),
          ),
          const SizedBox(height: 8),
          section(
            '远程桌面',
            hint: '交给手机上的外部 App 去连，用它自己的网络，不走 SSH 的代理或跳板。没装也能先保存条目。',
          ),
          choice(
            'RustDesk',
            Icons.connected_tv_outlined,
            rd.notice ??
                switch (rd.app) {
                  RustDeskReady() => null,
                  RustDeskNotInstalled() => '未安装',
                  RustDeskPlatformUnsupported() => '仅支持 Android',
                  RustDeskVersionTooOld() => '版本过旧，请更新客户端',
                  RustDeskSignerNeedsApproval() => '签名证书待批准',
                  RustDeskSignerChanged() => '签名证书已变化，需要重新核对',
                  RustDeskSignerUnsupported() => '不支持多签名客户端',
                  null => '正在检查客户端',
                },
            const ConnectionTypeChoice.remote(RemoteConnectionType.rustdesk),
          ),
          choice(
            'UU 远程',
            Icons.desktop_windows_outlined,
            uu.notice ??
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
                },
            const ConnectionTypeChoice.remote(RemoteConnectionType.uu),
          ),
        ],
      ],
    );
  }
}
