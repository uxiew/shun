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

enum RemoteConnectionType { rustdesk, uu }

class ConnectionTypeChoice {
  const ConnectionTypeChoice.terminal(this.protocol, {this.pluginId})
      : remote = null;
  const ConnectionTypeChoice.remote(this.remote)
      : protocol = null,
        pluginId = null;
  final HostProtocol? protocol;
  final String? pluginId;
  final RemoteConnectionType? remote;
}

/// Selection only: probes installed clients, never authorizes, installs or launches.
class ConnectionTypeScreen extends ConsumerStatefulWidget {
  const ConnectionTypeScreen({super.key});
  @override
  ConsumerState<ConnectionTypeScreen> createState() =>
      _ConnectionTypeScreenState();
}

class _ConnectionTypeScreenState extends ConsumerState<ConnectionTypeScreen> {
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
    final moshStatus = !android
        ? '仅支持 Android'
        : discovery.isLoading
            ? '正在检查插件'
            : discovery.hasError
                ? '插件检查失败，请重试'
                : moshReady
                    ? '可用 · 仅直连 UDP'
                    : mosh == null
                        ? '未安装 Mosh 插件，可先保存配置'
                        : 'Mosh 插件不可用：${mosh.status.name}';
    Widget choice(
      String title,
      IconData icon,
      String status,
      ConnectionTypeChoice value, {
      bool enabled = true,
    }) =>
        Card(
          child: ListTile(
            key: ValueKey('connection-type-$title'),
            leading: Icon(icon),
            title: LText(title),
            subtitle: LText(status),
            enabled: enabled,
            onTap: enabled ? () => Navigator.pop(context, value) : null,
          ),
        );
    return Scaffold(
      appBar: AppBar(title: const LText('选择连接类型')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const LText('终端'),
          choice(
            'SSH',
            Icons.lock_outline,
            '可用 · SSH 终端',
            const ConnectionTypeChoice.terminal(HostProtocol.ssh),
          ),
          choice(
            'Mosh',
            Icons.wifi_tethering,
            moshStatus,
            const ConnectionTypeChoice.terminal(HostProtocol.mosh),
          ),
          choice(
            'Telnet',
            Icons.cable,
            '可用 · 明文，仅直连',
            const ConnectionTypeChoice.terminal(HostProtocol.telnet),
          ),
          const SizedBox(height: 16),
          const LText('远程桌面'),
          const LText('使用外部 App 自己的网络；不继承 SSH 代理或跳板。未安装时可以先保存条目。'),
          choice(
            'RustDesk',
            Icons.connected_tv_outlined,
            rd.notice ??
                switch (rd.app) {
                  RustDeskReady() => '可用 · 外部客户端',
                  RustDeskNotInstalled() => '未安装，可先保存条目',
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
                      ? '可用 · 仅 Windows/macOS 目标'
                      : '回调地址冲突，绑定不可用',
                  UuNotInstalled() => '未安装，可先保存条目',
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
          const SizedBox(height: 16),
          const LText('终端插件'),
          for (final entry in entries.where(
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
          ))
            choice(
              entry.descriptor!.displayName,
              Icons.extension_outlined,
              discovery.isLoading
                  ? '正在检查插件'
                  : discovery.hasError
                      ? '插件检查失败，请重试'
                      : pluginHostAvailability(entries, entry.pluginId)
                              .problem ??
                          '可用 · 插件自己联网',
              ConnectionTypeChoice.terminal(
                HostProtocol.plugin,
                pluginId: entry.pluginId,
              ),
              enabled: android &&
                  !discovery.isLoading &&
                  !discovery.hasError &&
                  pluginHostAvailability(entries, entry.pluginId).entry != null,
            ),
        ],
      ),
    );
  }
}
