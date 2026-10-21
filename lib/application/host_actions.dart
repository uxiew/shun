/// 主机列表里每台主机的 ⋮ 菜单（R43）：只列这台主机此刻真能做的动作。
///
/// 用不了的动作不出现（不是变灰）：
/// - 换一种方式连：SSH 主机能不能用 Mosh，和终端菜单是同一套判断（只许直连、选项合法、插件能用）；
///   按保险库现在的配置另开一个标签，不改这台主机保存的默认方式。
/// - 端口转发、文件、监控：都挂在一条已经连着的 SSH 上，这台主机没有连着的 SSH 标签就不出现。
///   菜单不替用户先去连一下——点「端口转发」不该悄悄开出一条 SSH。
/// - 测试连接：和编辑器一样只有普通 SSH 有，路线算不出来也不出现（编辑器里会写原因）。
/// - 编辑、隐藏 / 取消隐藏：每台都有。
library;

import '../domain/connection_route.dart';
import '../domain/host_identity.dart';
import '../domain/models/host.dart';
import '../domain/models/vault.dart';
import '../infrastructure/ssh/ssh_service.dart';
import 'connection_switch.dart';

enum HostMenuAction {
  connectOther,
  portForward,
  files,
  monitor,
  testConnection,
  edit,
  hide,
  unhide,
}

class HostMenu {
  const HostMenu({
    required this.host,
    this.otherTransport,
    this.sshSession,
    this.probePlan,
  });

  final HostProfile host;

  /// 能换成的另一种方式；null 表示换不了。
  final TabTransport? otherTransport;

  /// 这台主机连着的一条 SSH，端口转发、文件、监控用它；null 表示没有。
  final ActiveTerminalSession? sshSession;

  /// 测试连接要走的路线；null 表示这台测不了。
  final RoutePlan? probePlan;

  List<HostMenuAction> get actions => [
        if (otherTransport != null) HostMenuAction.connectOther,
        if (sshSession != null) ...[
          HostMenuAction.portForward,
          HostMenuAction.files,
          HostMenuAction.monitor,
        ],
        if (probePlan != null) HostMenuAction.testConnection,
        HostMenuAction.edit,
        host.hidden ? HostMenuAction.unhide : HostMenuAction.hide,
      ];
}

/// 这台主机连着的 SSH 标签，优先 [active]（用户正看着的那个）。
/// 认的是来源主机：切换方式、AI 工具开出来的临时副本也算这台的。断开的、Mosh 的不算。
ActiveTerminalSession? connectedSshSessionOf(
  HostProfile host,
  List<ActiveTerminalSession> sessions, {
  ActiveTerminalSession? active,
}) {
  bool usable(ActiveTerminalSession s) =>
      s.isSsh && s.connected && sourceHostIdOf(s.host) == host.id;
  if (active != null && usable(active)) return active;
  return sessions.where(usable).firstOrNull;
}

/// 测试连接要走的路线：只有普通 SSH 主机、路线算得出来时才有。
RoutePlan? probePlanOf(HostProfile host, VaultData vault) {
  if (host.protocol != HostProtocol.ssh) return null;
  try {
    return resolveRoutePlan(
      host,
      hosts: vault.hosts,
      proxyProfiles: vault.proxyProfiles,
      keys: vault.keys,
    );
  } on RouteConfigException {
    return null;
  }
}

/// 隐藏 / 取消隐藏只改这一个字段，主机别的设置原样留着。
HostProfile withHidden(HostProfile host, bool hidden) {
  final data = {...host.data};
  if (hidden) {
    data[hiddenHostKey] = true;
  } else {
    data.remove(hiddenHostKey);
  }
  return HostProfile(data);
}
