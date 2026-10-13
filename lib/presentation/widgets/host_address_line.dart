import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/plugin_host_session.dart';
import '../../application/plugin_registry.dart';
import '../../domain/models/host.dart';
import '../../domain/plugins/plugin_host.dart';
import '../localization/localized_widgets.dart';

/// 主机条目上「连到哪」那一行。普通主机是 `user@host:port`；插件主机写用的哪个插件，插件现在用不了时标「不可用」，
/// 点条目连接时等待卡片上写原因（X12）。插件主机没有地址可写：连哪里由插件自己的设置页决定。
class HostAddressLine extends ConsumerWidget {
  const HostAddressLine(
    this.host, {
    super.key,
    this.withProtocol = false,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  final HostProfile host;

  /// 前面加协议名（`SSH  user@host:port`）。
  final bool withProtocol;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (host.protocol == HostProtocol.unknown) {
      return LText('不支持的连接类型',
          key: const ValueKey('unsupported-host-address'),
          style: style,
          maxLines: maxLines,
          overflow: overflow,
          textAlign: textAlign);
    }
    if (host.protocol != HostProtocol.plugin) {
      final address = '${host.username}@${host.hostname}:${host.port}';
      return LText(
        withProtocol
            ? '${host.protocol.name.toUpperCase()}  $address'
            : address,
        style: style,
        maxLines: maxLines,
        overflow: overflow,
        textAlign: textAlign,
      );
    }
    ref.watch(pluginHostDiscoveryProvider);
    final entries = ref.watch(pluginRegistryProvider);
    final id = pluginIdOf(host);
    final available = pluginHostAvailability(entries, id);
    final named = entries
        .where((e) => !e.isBuiltin && e.pluginId == id)
        .map((e) => e.descriptor?.displayName)
        .whereType<String>()
        .firstOrNull;
    final plugin = localized('插件');
    final unavailable = localized('不可用');
    // 插件自己起的名字不翻译，所以这里不用 LText 整句翻。
    return Text(
      '$plugin ${named ?? id ?? '?'}${available.problem == null ? '' : ' · $unavailable'}',
      key: const ValueKey('plugin-host-address'),
      style: style,
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
    );
  }
}
