import '../models/host.dart';

/// 主机协议选「插件」时用哪个第三方终端插件（所有者 2026-10-07 决定，X12）。
///
/// 只存 pluginId：证书由用户在插件页的批准记录绑定，这里不另存一份。本 fork 自己加的字段，
/// 桌面端 Netcatty 不认识，同步时原样保留（HostProfile 不丢未知字段）。
const pluginIdKey = 'xwshunPluginId';

String? pluginIdOf(HostProfile host) {
  final value = host.data[pluginIdKey]?.toString().trim();
  return value == null || value.isEmpty ? null : value;
}

/// 插件主机上残留的代理、跳板设置（多半是从桌面端同步来的，或者从 SSH 改成插件时留下的）。
///
/// 插件自己联网，这些设置对它不起作用。有就拒绝保存、拒绝连接，而不是悄悄去掉：
/// 用户选了代理，就该知道这条连接根本不经过代理。返回 null 表示没有。
String? pluginHostRouteProblem(HostProfile host) {
  final proxy = (host.proxyProfileId?.isNotEmpty ?? false) ||
      host.data['proxyConfig'] != null;
  final jumps = host.hostChainIds.isNotEmpty;
  if (!proxy && !jumps) return null;
  final what = proxy && jumps
      ? '代理和跳板机'
      : proxy
          ? '代理'
          : '跳板机';
  return '插件主机只能直连：这台主机配了$what。插件自己联网，不经过本 App 的代理和跳板；'
      '没有打开插件，也不会悄悄去掉这些设置。在编辑器里把连接路径改成直连，或者把协议改回 SSH。';
}

/// 插件主机「连到哪」的文字：只有用哪个插件，没有地址（连哪里由插件自己决定）。
String pluginHostEndpoint(HostProfile host) {
  final id = pluginIdOf(host) ?? '?';
  return '插件 $id';
}
