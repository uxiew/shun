import 'descriptor.dart';

/// 用户为这次会话选定的路由。
enum RequestedRoute { systemDefault, socks5Connect, proxyJump, socks5ProxyJump }

/// 会话的传输类型：路由能力不能跨类型"继承"（docs/04 V3 段）。
enum TransportKind {
  /// TCP 字节流，可以复用宿主的 RoutePlan（SSH/SFTP）。
  byteStream,

  /// UDP（Mosh）。SOCKS5 CONNECT 和 ProxyJump 都只转发 TCP，不能承载它。
  udp,

  /// 外部 App 自己管网络和账号。
  providerManaged,
}

sealed class RouteDecision {
  const RouteDecision();
}

class RouteAllowed extends RouteDecision {
  const RouteAllowed();
}

/// 在任何远端动作（比如 mosh-server bootstrap）之前就拒绝，不偷偷改走直连。
class RouteUnsupported extends RouteDecision {
  const RouteUnsupported(this.reason);
  final String reason;
}

RouteDecision checkRoute(
  PluginDescriptor provider,
  TransportKind transport,
  RequestedRoute requested,
) {
  if (transport == TransportKind.providerManaged ||
      provider.supportedRoutes.contains(RouteSupport.providerManaged)) {
    return requested == RequestedRoute.systemDefault
        ? const RouteAllowed()
        : const RouteUnsupported(
            '外部 App 使用自己的网络和账号，不会经过这里配置的 SOCKS/跳板；'
            '要求整次远控都走代理时无法满足',
          );
  }
  if (transport == TransportKind.udp &&
      requested != RequestedRoute.systemDefault) {
    return const RouteUnsupported(
      'UDP 会话（如 Mosh）不能经 SOCKS5 CONNECT 或 ProxyJump 承载；'
      '首版只支持显式直连，不会改为直连代替',
    );
  }
  final needed = switch (requested) {
    RequestedRoute.systemDefault => RouteSupport.systemDefault,
    RequestedRoute.socks5Connect => RouteSupport.socks5Connect,
    RequestedRoute.proxyJump => RouteSupport.proxyJump,
    RequestedRoute.socks5ProxyJump => RouteSupport.socks5ProxyJump,
  };
  return provider.supportedRoutes.contains(needed)
      ? const RouteAllowed()
      : RouteUnsupported('${provider.pluginId} 未声明支持 ${needed.wire}');
}
