import 'connection_route.dart';
import 'models/host.dart';

enum RouteLegKind { phone, proxy, jump, target }

/// 路线上的一段，给界面显示用。
class RouteLeg {
  const RouteLeg(this.kind, this.title, [this.detail = '']);

  final RouteLegKind kind;
  final String title;

  /// 地址、用户名之类；目标和跳板写成 `用户@地址:SSH端口`，代理写代理自己的地址和端口，
  /// 两种端口分开写、不混在一起（R10 验收：SSH 端口与代理端口不混）。
  final String detail;
}

/// 把 [plan] 拆成「手机 → 代理 → 跳板… → 目标」一段段。只写 App 自己做的事：
/// 经代理时，代理之后怎么走由代理程序决定，App 看不到，所以代理那段注明这一点，不假装知道（UX04）。
List<RouteLeg> describeRoute(RoutePlan plan) {
  final legs = <RouteLeg>[const RouteLeg(RouteLegKind.phone, '手机')];
  final entry = plan.entry;
  if (entry is ProxyEntry) {
    final kind = entry.type == ProxyType.socks5 ? 'SOCKS5 代理' : 'HTTP 代理';
    legs.add(RouteLeg(
      RouteLegKind.proxy,
      kind,
      '${entry.endpoint.authority}（代理之后怎么走由代理决定，App 看不到）',
    ));
  }
  for (final jump in plan.jumps) {
    legs.add(RouteLeg(
      RouteLegKind.jump,
      '跳板机“${jump.host.label}”',
      '${jump.host.username}@${jump.endpoint.authority}',
    ));
  }
  final target = plan.target;
  legs.add(RouteLeg(
    RouteLegKind.target,
    '目标“${target.host.label}”',
    switch (plan.protocol) {
      HostProtocol.telnet => 'Telnet ${target.endpoint.authority}',
      // 两段走的不是同一条路：SSH 只用来启动 mosh-server，之后的会话是手机直发的 UDP（MOS03）。
      HostProtocol.mosh =>
        'SSH ${target.host.username}@${target.endpoint.authority} 启动 mosh-server，之后 Mosh 会话走 UDP 直连',
      HostProtocol.ssh =>
        'SSH ${target.host.username}@${target.endpoint.authority}',
    },
  ));
  return legs;
}

/// 一行摘要：「手机 → SOCKS5 代理 → 跳板机“edge” → 目标“web”」。
String routeSummary(RoutePlan plan) =>
    describeRoute(plan).map((leg) => leg.title).join(' → ');
