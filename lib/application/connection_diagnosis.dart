import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import '../domain/connection_route.dart';
import '../infrastructure/ssh/ssh_identity.dart';
import '../infrastructure/ssh/ssh_login_watch.dart';
import '../infrastructure/ssh/ssh_service.dart';
import '../infrastructure/transport/proxy_transport.dart';

/// 连接失败后给一句「下一步怎么办」（UX04）。
///
/// 只按真实的失败类型说：代理之后的链路 App 看不到，就不替它下结论；
/// 报错本身已经说清怎么改的（比如凭据解不开），返回 null，不重复。
String? connectionHint(Object error) {
  final cause = error is RouteHopException ? error.cause : error;
  return switch (cause) {
    RouteConfigException() => '路线配置有问题：到主机编辑器的「连接路径」里改，保存前会检查。',
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
    SSHAuthAbortError() =>
      '对方在登录完成前断开了：确认这个端口上是 SSH 服务——常见原因是把代理端口或别的服务端口填成了 SSH 端口。',
    SSHChannelOpenError() =>
      '跳板机拒绝转发：确认跳板机允许 TCP 转发（sshd 的 AllowTcpForwarding），且下一跳地址从跳板机那边能到达。',
    UnsupportedError() => null,
    _ => null,
  };
}
