import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import '../domain/connection_route.dart';
import '../domain/plugins/mosh_bootstrap.dart';
import '../domain/plugins/mosh_route.dart';
import '../infrastructure/ssh/ssh_identity.dart';
import '../infrastructure/ssh/ssh_login_watch.dart';
import '../infrastructure/ssh/ssh_service.dart';
import '../infrastructure/terminal/terminal_session_adapter.dart';
import '../infrastructure/transport/proxy_transport.dart';
import 'mosh_session.dart';

/// 连接失败后给一句「下一步怎么办」（UX04）。
///
/// 只按真实的失败类型说：代理之后的链路 App 看不到，就不替它下结论；
/// 报错本身已经说清怎么改的（比如凭据解不开），返回 null，不重复。
String? connectionHint(Object error) {
  final cause = error is RouteHopException ? error.cause : error;
  return switch (cause) {
    // Mosh（X09）：都还没做任何远端动作，或者只做到了 SSH 那一段。
    MoshRouteUnsupported() =>
      '要经代理或跳板机，把这台主机的协议改回 SSH（想断线后接着用，可以配合 tmux）；要用 Mosh，把连接路径改成「直连」。',
    MoshPluginUnavailable() => 'Mosh 插件在「设置 → 插件（实验）」里管理。这一步只查了本机，还没连服务器。',
    MoshBootstrapException(failure: MoshBootstrapFailure.serverMissing) =>
      '请服务器管理员安装 mosh（Debian/Ubuntu：apt install mosh；Alpine：apk add mosh-server）。'
          '本 App 不会替你安装，也不会用 sudo。SSH 这一段是通的。',
    MoshBootstrapException(failure: MoshBootstrapFailure.localeUnsupported) =>
      '在服务器上生成一个 UTF-8 语言环境（比如 locale-gen en_US.UTF-8），再连。',
    MoshBootstrapException() =>
      '服务器上的 mosh-server 给出的连接信息不可信，没有用它；SSH 这一段是通的。检查服务器登录脚本有没有往输出里打东西。',
    RouteConfigException() => '路线配置有问题：到主机编辑器的「连接路径」里改，保存前会检查。',
    // 还没拨号就停了，和服务器、网络无关。
    TerminalEngineUnavailableException() =>
      '是这台手机上的终端引擎没能启动，还没开始连服务器。这个版本只带 Ghostty，没有别的引擎可换；「设置 → 外观」的「终端引擎」里能看到原话，「检查」可以再试一次。',
    // 放在 dartssh2 的错误前面：Tailscale 拒绝时 dartssh2 报的是「认证前连接被关闭」，
    // 按那条提示会让人去查端口填错没有。
    TailscaleLoginDenied() =>
      '到 Tailscale 后台检查访问策略里的 ssh 规则：来源要包含这次连接的来源节点（经代理时是代理出口那台，不是手机），'
          '登录用户名要在允许的列表里。',
    SshIdentityException() => '到主机编辑器重新选择私钥，或在私钥管理里补上正确的口令。',
    ProxyHandshakeException() =>
      '检查代理的地址、端口、用户名和密码。代理之后怎么走由代理决定，App 只看得到代理返回的结果。',
    ConnectStageException() ||
    SocketException() ||
    TimeoutException() =>
      '手机连不到这个地址：确认地址和端口没填错（SSH 端口和代理端口是两个不同的端口），'
          '以及当前网络——包括你开着的 VPN——能到达它。',
    SSHHostkeyError() ||
    SSHAuthAbortError(reason: SSHHostkeyError()) =>
      '服务器指纹没通过核对，已在发送任何登录信息前断开。先向管理员确认，不要为了连上而接受不认识的指纹。',
    SSHAuthFailError() =>
      '服务器拒绝了登录：确认用户名；用密码的检查密码，用私钥的确认服务器上 authorized_keys 里有这把公钥。',
    // 代理或跳板机已经回报连上，随后在登录前被关：只说「端口不是 SSH」会把人引去查端口，
    // 而实际也可能是代理、跳板机之后那一段断了（R15 在 tailnet 测试环境里撞上过，App 看不到那一段）。
    SSHAuthAbortError() when error is RouteHopException && error.relayed =>
      '代理或跳板机已经回报连上了目标，随后在登录前断开：可能这个端口上不是 SSH 服务，'
          '也可能代理或跳板机之后的那一段断了，App 看不到那一段。先确认 SSH 端口，再看代理或跳板机那边能不能连到目标。',
    SSHAuthAbortError() =>
      '对方在登录完成前断开了：确认这个端口上是 SSH 服务——常见原因是把代理端口或别的服务端口填成了 SSH 端口。',
    SSHChannelOpenError() =>
      '跳板机拒绝转发：确认跳板机允许 TCP 转发（sshd 的 AllowTcpForwarding），且下一跳地址从跳板机那边能到达。',
    UnsupportedError() => null,
    _ => null,
  };
}
