/// 终端里的连接方式（R42）：一个标签现在走 SSH 还是 Mosh、能不能切到另一种、不能的话为什么。
///
/// 这里只做判断和主机副本，不碰网络；真正切换在 [SessionController.switchTransport]。
/// 规矩（docs/08 R42）：
/// - tmux 标签原地切：同一个 tmux 会话（R21 完整身份），新的一边接上、核对过了再分离旧客户端，不重发任何输入。
/// - 普通标签另开一个新标签，原标签不动：普通 shell 跟着连接走，换不了底。
/// - Mosh 只许直连、要有批准过的 Mosh 插件；不满足时菜单里的 Mosh 项变灰并写原因。
library;

import 'package:uuid/uuid.dart';

import '../domain/host_identity.dart';
import '../domain/models/host.dart';
import '../infrastructure/ssh/ssh_service.dart';
import 'mosh_session.dart';

enum TabTransport {
  ssh('SSH'),
  mosh('Mosh');

  const TabTransport(this.label);

  /// 菜单、提示里的写法。标签条上的徽标用大写（SSH / MOSH）。
  final String label;

  HostProtocol get protocol =>
      this == TabTransport.mosh ? HostProtocol.mosh : HostProtocol.ssh;

  TabTransport get other =>
      this == TabTransport.mosh ? TabTransport.ssh : TabTransport.mosh;

  static TabTransport? ofProtocol(HostProtocol protocol) => switch (protocol) {
        HostProtocol.ssh => TabTransport.ssh,
        HostProtocol.mosh => TabTransport.mosh,
        _ => null,
      };
}

/// 这个标签走的是什么。Telnet、第三方插件标签不在 SSH / Mosh 之列，返回 null（不显示徽标）。
/// 断开了的、上次 App 被结束后放回来的标签看它的主机副本：切换开出来的标签主机上就是它的方式。
TabTransport? transportOf(ActiveTerminalSession session) {
  if (session.plugin is MoshTerminalProvider) return TabTransport.mosh;
  if (session.plugin != null) return null;
  return TabTransport.ofProtocol(session.host.protocol);
}

/// 切换开出来的主机副本上的记号。有它的临时标签 App 被结束后也放回来（和普通标签一样），
/// 「系统管理」的一次性命令标签、AI 标签没有它，照旧不放回。
const transportCopyKey = '_shunTransportCopy';

/// 保险库主机 [source] 按 [to] 连的一份临时副本：地址、账号、路线、Mosh 选项都照保险库现在的，
/// 协议换成 [to]，不带「连接后执行命令」——切换只换网络这一段怎么走，不替用户再执行命令。
/// 保险库里的主机不变；要改默认方式用 [SessionController.setDefaultTransport]。
HostProfile transportCopy(
  HostProfile source,
  TabTransport to, {
  String? label,
}) =>
    HostProfile({
      for (final entry in source.data.entries)
        if (entry.key != 'startupCommand') entry.key: entry.value,
      'id': '${to.name}-${const Uuid().v4()}',
      'label': label ?? source.label,
      'protocol': to.protocol.name,
      '_ephemeralTerminal': true,
      sourceHostIdKey: sourceHostIdOf(source),
      transportCopyKey: true,
    });

/// 一次性命令标签（「系统管理」里开的、安装 mosh 开的）：临时主机、带着那条命令、不是 tmux。
bool isManagedTerminal(ActiveTerminalSession session) =>
    session.host.data['_ephemeralTerminal'] == true &&
    session.host.data[transportCopyKey] != true &&
    session.tmux == null &&
    session.resumeTmux == null &&
    (session.host.startupCommand?.isNotEmpty ?? false);

/// 菜单里「切换到 …」这一项。
class TransportSwitchOption {
  const TransportSwitchOption({
    required this.from,
    required this.inPlace,
    this.blocked,
  });

  final TabTransport from;
  TabTransport get to => from.other;

  /// tmux 标签原地切；普通标签另开一个。
  final bool inPlace;

  /// 为什么现在切不了；null 表示能切。
  final String? blocked;
}

/// 菜单里「把 … 设为这台主机的默认」这一项。只在标签现在的方式和主机默认的不一样时才有。
class DefaultTransportOption {
  const DefaultTransportOption({required this.transport, this.blocked});

  final TabTransport transport;
  final String? blocked;
}

class TransportMenu {
  const TransportMenu({
    required this.current,
    required this.switchTo,
    this.setDefault,
    this.hostDefault,
  });

  final TabTransport current;
  final TransportSwitchOption switchTo;
  final DefaultTransportOption? setDefault;

  /// 保险库里这台主机现在的默认方式；主机已经删了时为 null。
  final TabTransport? hostDefault;
}

/// 一次正在进行的原地切换：切到哪种、到哪一步了。旧的一边这时还连着、照常能打字。
class TransportSwitchProgress {
  const TransportSwitchProgress(this.to, [this.stage]);

  final TabTransport to;
  final ConnectionStage? stage;

  String describe() {
    final step = stage?.describe();
    return step == null ? '正在切到 ${to.label}…' : '正在切到 ${to.label}：$step';
  }
}

/// 现在切不了、设不了默认：[message] 就是菜单里写的原因。还没碰服务器。
class TransportSwitchBlocked implements Exception {
  const TransportSwitchBlocked(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 切换还没完成，这条 SSH 上又开了用户没确认过的端口转发：没有切，那些转发一条没动。
class ForwardsChangedException implements Exception {
  const ForwardsChangedException();

  @override
  String toString() => '切换过程中这条 SSH 上又开了端口转发，没有切换，转发也没动。再点一次会重新列出要停掉的转发。';
}
