import 'package:plugin_api/plugin_api.dart' show RequestedRoute;

import '../connection_route.dart';
import '../models/host.dart';
import 'mosh_bootstrap.dart';

/// Mosh 首版只走显式直连（docs/04、docs/16）。
///
/// Mosh 先经 SSH 在远端启动 mosh-server，之后整个会话走 UDP。SOCKS5 / HTTP 代理的 CONNECT 和跳板机的
/// direct-tcpip 都只转发 TCP，承载不了这段 UDP——「SSH 经代理、跳板能通」不代表 Mosh 能通（经 TailSocks 也一样）。
/// 不是直连就在任何网络动作之前拒绝：一个连接都不拨、远端什么都不启动，也不改成直连绕过用户选的路线。
RequestedRoute requestedRouteOf(RoutePlan plan) =>
    switch ((plan.entry, plan.jumps.isEmpty)) {
      (DirectEntry(), true) => RequestedRoute.systemDefault,
      // HTTP CONNECT 和 SOCKS5 CONNECT 一样只转 TCP；plugin_api 的路线枚举里没有单独的 HTTP，按同类处理。
      (ProxyEntry(), true) => RequestedRoute.socks5Connect,
      (DirectEntry(), false) => RequestedRoute.proxyJump,
      (ProxyEntry(), false) => RequestedRoute.socks5ProxyJump,
    };

/// 返回 null 表示可以用 Mosh；否则是拒绝的原因。编辑器保存前、连接前用的是同一个判断。
MoshRouteUnsupported? moshRouteProblem(RoutePlan plan) {
  final route = requestedRouteOf(plan);
  if (route == RequestedRoute.systemDefault) return null;
  final entry = plan.entry;
  final proxy = entry is ProxyEntry
      ? '${entry.type == ProxyType.socks5 ? 'SOCKS5 代理' : 'HTTP 代理'} ${entry.endpoint.authority}'
      : null;
  final jumps = plan.jumps.map((hop) => '“${hop.host.label}”').join('、');
  return MoshRouteUnsupported(
    route,
    switch (route) {
      RequestedRoute.socks5Connect => '经$proxy',
      RequestedRoute.proxyJump => '经跳板机 $jumps',
      _ => '先经$proxy再走跳板机 $jumps',
    },
  );
}

/// 主机上 Mosh UDP 端口范围的字段。本 fork 自己加的，桌面端 Netcatty 不认识，同步时原样保留（HostProfile 不丢未知字段）。
const moshPortsKey = 'shunMoshPorts';

/// 这台主机让 mosh-server 在哪个范围里挑 UDP 端口；没填用 mosh 默认的 60001–60999。
/// 格式不对抛 [RouteConfigException]：连接前就停，不拿一个猜出来的范围去启动远端。
(int, int) moshPortRangeOf(HostProfile host) =>
    parseMoshPorts(host.data[moshPortsKey]?.toString());

/// 「60001」或「60001:60999」。空白表示用默认。
(int, int) parseMoshPorts(String? raw) {
  final text = raw?.trim() ?? '';
  if (text.isEmpty) return MoshBootstrap.defaultPortRange;
  final match = RegExp(r'^([0-9]{1,5})(?::([0-9]{1,5}))?$').firstMatch(text);
  final low = int.tryParse(match?.group(1) ?? '');
  final high = int.tryParse(match?.group(2) ?? match?.group(1) ?? '');
  if (low == null || high == null || low < 1 || high > 65535 || low > high) {
    throw RouteConfigException(
      'Mosh UDP 端口范围写得不对：$text（写成 60001，或 60001:60999）',
    );
  }
  return (low, high);
}

/// 主机上指定的 mosh-server 路径（R41）。没填 = 自动：先 PATH，再按 [MoshBootstrap.probeLocations]。同样是本 fork 加的字段。
const moshServerPathKey = 'shunMoshServerPath';

/// 主机上指定的 locale（R41）。没填 = 自动：用 [MoshBootstrap.defaultLocale]。
const moshLocaleKey = 'shunMoshLocale';

/// 交给引导命令的三个覆盖项。null 表示自动。
typedef MoshServerOptions = ({
  (int, int) portRange,
  String? serverPath,
  String? locale,
});

/// 任何一项格式不对都抛 [RouteConfigException]：连接前就停，不拿猜出来的值去远端启动 mosh-server。
MoshServerOptions moshServerOptionsOf(HostProfile host) => (
      portRange: moshPortRangeOf(host),
      serverPath: parseMoshServerPath(host.data[moshServerPathKey]?.toString()),
      locale: parseMoshLocale(host.data[moshLocaleKey]?.toString()),
    );

/// 空白返回 null（自动）。
String? parseMoshServerPath(String? raw) {
  final text = raw?.trim() ?? '';
  if (text.isEmpty) return null;
  if (!MoshBootstrap.isValidServerPath(text)) {
    throw RouteConfigException(
      'mosh-server 路径写得不对：$text（写 / 或 ~/ 开头的完整路径，如 /opt/mosh/bin/mosh-server；只能有字母、数字和 . _ + - /）',
    );
  }
  return text;
}

/// 空白返回 null（自动）。
String? parseMoshLocale(String? raw) {
  final text = raw?.trim() ?? '';
  if (text.isEmpty) return null;
  if (!MoshBootstrap.isValidLocale(text)) {
    throw RouteConfigException(
      'Mosh locale 写得不对：$text（写成 C.UTF-8、en_US.UTF-8 这类 UTF-8 locale）',
    );
  }
  return text;
}

/// 用户选的路线 Mosh 承载不了。抛出时还没有拨出任何连接。
class MoshRouteUnsupported implements Exception {
  const MoshRouteUnsupported(this.route, this.description);

  final RequestedRoute route;

  /// 这台主机的连接路径，例如「经SOCKS5 代理 127.0.0.1:1080」。只有地址，没有账号口令。
  final String description;

  @override
  String toString() => 'Mosh 只能直连，这台主机的连接路径是：$description。'
      'Mosh 会话走 UDP，代理和跳板机只转发 TCP，承载不了；'
      '没有连接服务器、没有启动 mosh-server，也不会改成直连绕过你选的路线。';
}
