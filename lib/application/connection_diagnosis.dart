import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import '../domain/connection_route.dart';
import '../domain/models/host.dart';
import '../domain/plugins/mosh_bootstrap.dart';
import '../domain/plugins/mosh_route.dart';
import '../domain/tailscale_ssh.dart';
import '../infrastructure/ssh/ssh_client_defaults.dart';
import '../infrastructure/ssh/ssh_identity.dart';
import '../infrastructure/ssh/ssh_login_watch.dart';
import '../infrastructure/ssh/ssh_service.dart';
import '../infrastructure/terminal/terminal_session_adapter.dart';
import '../infrastructure/tmux/tmux_protocol.dart';
import '../infrastructure/transport/proxy_transport.dart';
import 'connection_lifecycle.dart';
import 'credential_availability.dart';
import 'mosh_session.dart';
import 'plugin_host_session.dart';
import 'tailscale_catalog_refresh.dart';

/// 连接失败按什么分类（R25 连接记录只存这个名字，不存报错原话）。
///
/// 原话里有地址、主机名、服务器发来的文字（Tailscale 的 banner），存下来就违反了「只存受限元数据」（SEC12）。
/// 分类是按异常类型定的，不看文字。**名字会写进本机记录文件**：改名字等于旧记录读不出这一条（读到不认识的名字
/// 按 [other] 显示），所以只加不改。
enum ConnectionFailureKind {
  routeConfig,
  routeChanged,
  credentialUnavailable,
  identity,
  engineUnavailable,
  unreachable,
  proxy,
  hostKey,
  authFailed,
  authAborted,
  authAbortedRelayed,
  channelOpen,
  tailscaleDenied,
  tailscaleCheckNeedsUser,
  loginMode,
  loginTimeout,
  handshake,
  tmuxTarget,
  moshRoute,
  moshPlugin,
  moshServerMissing,
  moshServerPath,
  moshLocale,
  moshBootstrap,
  pluginUnavailable,
  noCommonAlgorithm,
  securityKey,
  other,
}

/// 把一次连接失败归到 [ConnectionFailureKind]。取消不算失败，调用方自己先分出去。
ConnectionFailureKind classifyConnectionFailure(Object error) {
  final cause = error is RouteHopException ? error.cause : error;
  return switch (cause) {
    MoshRouteUnsupported() => ConnectionFailureKind.moshRoute,
    MoshPluginUnavailable() => ConnectionFailureKind.moshPlugin,
    MoshBootstrapException(failure: MoshBootstrapFailure.serverMissing) =>
      ConnectionFailureKind.moshServerMissing,
    MoshBootstrapException(failure: MoshBootstrapFailure.serverPathMissing) =>
      ConnectionFailureKind.moshServerPath,
    MoshBootstrapException(failure: MoshBootstrapFailure.localeUnsupported) =>
      ConnectionFailureKind.moshLocale,
    MoshBootstrapException() => ConnectionFailureKind.moshBootstrap,
    RouteConfigException() => ConnectionFailureKind.routeConfig,
    RouteChangedException() => ConnectionFailureKind.routeChanged,
    CredentialUnavailableException() =>
      ConnectionFailureKind.credentialUnavailable,
    TerminalEngineUnavailableException() =>
      ConnectionFailureKind.engineUnavailable,
    // 放在 dartssh2 的错误前面：Tailscale 拒绝时 dartssh2 报的是「认证前连接被关闭」，
    // 按那条提示会让人去查端口填错没有。
    TailscaleLoginDenied() => ConnectionFailureKind.tailscaleDenied,
    TailscaleCheckNeedsUser() => ConnectionFailureKind.tailscaleCheckNeedsUser,
    StandardLoginFellBackToNone() ||
    StandardLoginGotCheckLink() =>
      ConnectionFailureKind.loginMode,
    SshLoginTimeout() => ConnectionFailureKind.loginTimeout,
    SshIdentityException() => ConnectionFailureKind.identity,
    ProxyHandshakeException() => ConnectionFailureKind.proxy,
    ConnectStageException() ||
    SocketException() ||
    TimeoutException() =>
      ConnectionFailureKind.unreachable,
    SSHHostkeyError() ||
    SSHAuthAbortError(reason: SSHHostkeyError()) =>
      ConnectionFailureKind.hostKey,
    SSHAuthFailError() => ConnectionFailureKind.authFailed,
    _ when isAlgorithmMismatch(cause) =>
      ConnectionFailureKind.noCommonAlgorithm,
    _ when securityKeyCauseOf(cause) != null =>
      ConnectionFailureKind.securityKey,
    SSHAuthAbortError() when error is RouteHopException && error.relayed =>
      ConnectionFailureKind.authAbortedRelayed,
    SSHAuthAbortError() => ConnectionFailureKind.authAborted,
    SSHChannelOpenError() => ConnectionFailureKind.channelOpen,
    SSHHandshakeError() || SSHSocketError() => ConnectionFailureKind.handshake,
    TmuxTargetGoneException() ||
    TmuxCommandException(exitCode: TmuxExit.missing) ||
    MoshTmuxAttachException() =>
      ConnectionFailureKind.tmuxTarget,
    PluginHostUnavailable() => ConnectionFailureKind.pluginUnavailable,
    _ => ConnectionFailureKind.other,
  };
}

/// 连接失败后给一句「下一步怎么办」（UX04）。
///
/// 只按真实的失败类型说：代理之后的链路 App 看不到，就不替它下结论；
/// 报错本身已经说清怎么改的（比如凭据解不开），返回 null，不重复。
String? connectionHint(Object error) => _hint(classifyConnectionFailure(error));

/// Tailscale 设备连不上时的修法（F39、R77）。只给建议：不替用户改设置，也不自动重试登录。
class TailscaleFix {
  const TailscaleFix({this.text, this.command, this.openApp = false});

  /// 换掉通用提示的那句人话。null：通用提示已经说清了，只多一个「改认证方式」。
  final String? text;

  /// 要用户到服务器上自己运行的命令。
  final String? command;

  /// 给「打开 Tailscale」：手机这头的问题，修法在 Tailscale App 里。
  final bool openApp;
}

/// 这台是不是 Tailscale 设备：选了 Tailscale SSH、连着目录，或地址就是 tailnet 的。
bool isTailscaleHost(HostProfile host) =>
    sshLoginModeOf(host) == SshLoginMode.tailscale ||
    CatalogBinding.of(host) != null ||
    _isTailnetAddress(host.hostname);

/// 100.64.0.0/10 或 MagicDNS 名字。别的地址走 Tailscale 也可能，但看不出来，不瞎猜。
bool _isTailnetAddress(String address) {
  final host = address.trim().toLowerCase();
  if (host.endsWith('.ts.net')) return true;
  final parts = host.split('.').map(int.tryParse).toList();
  if (parts.length != 4 || parts.contains(null)) return false;
  return parts[0] == 100 && parts[1]! >= 64 && parts[1]! <= 127;
}

/// 这次失败是手机自己拨的哪个地址。经代理、跳板转发的那段 App 看不到，返回 null。
String? _dialledByPhone(HostProfile host, Object error, RoutePlan? route) {
  // 真实连接失败都包成 RouteHopException；跳板的第一跳也是手机拨的，但拨的不是目标地址。
  if (error is! RouteHopException) return host.hostname;
  if (error.relayed || route == null) return null;
  return route.hops.elementAtOrNull(error.hop)?.endpoint.host;
}

TailscaleFix? tailscaleFix(HostProfile host, Object error, {RoutePlan? route}) {
  if (!isTailscaleHost(host)) return null;
  // 只发了 none 认证，服务器却要密码或私钥：那边是普通 sshd，不是 Tailscale SSH。
  final cause = error is RouteHopException ? error.cause : error;
  if (cause case TailscaleLoginDenied(refusedNone: true)) {
    return const TailscaleFix(
      text: '这台多半没开 Tailscale SSH。在它上面运行下面的命令，或者改用密码、凭据。',
      command: 'sudo tailscale set --ssh',
    );
  }
  return switch (classifyConnectionFailure(error)) {
    ConnectionFailureKind.tailscaleDenied ||
    ConnectionFailureKind.tailscaleCheckNeedsUser ||
    ConnectionFailureKind.loginMode =>
      const TailscaleFix(),
    ConnectionFailureKind.unreachable
        when _isTailnetAddress(_dialledByPhone(host, error, route) ?? '') =>
      const TailscaleFix(
        text:
            '这是 Tailscale 地址，手机要先连上 tailnet：打开 Tailscale App 确认已连接，再点重试。或者改走代理、跳板。',
        openApp: true,
      ),
    _ => null,
  };
}

/// 连接记录里的「下一步」（R25）。记录里没有报错原话，所以失败页上「原话已经说清」的那几类也要有一句。
///
/// 都只是建议：没有一条会替用户改路线、改成直连或自动重试（R25 验收「失败不给自动直连入口」）。
String failureNextStep(ConnectionFailureKind kind) =>
    _hint(kind) ??
    switch (kind) {
      ConnectionFailureKind.routeChanged =>
        '断线期间这台主机的地址、代理、跳板机或登录身份改过，自动恢复只走原来那条路线，所以停了。点「重新连接」按现在的配置连。',
      ConnectionFailureKind.credentialUnavailable =>
        '这条路线要用的密码或私钥在本机安全存储里解不开，没有拨号。到主机编辑器重新填一次密码或重新选私钥。',
      ConnectionFailureKind.tailscaleCheckNeedsUser =>
        'Tailscale 要求重新做 check，自动恢复不替你打开链接。关掉这个标签，从主机列表重新连接。',
      ConnectionFailureKind.loginMode =>
        '服务器没要密码就放行，或者要你去浏览器认证：普通 SSH 不接受这两种登录。这台机器开着 Tailscale SSH 的话，在编辑器里把登录方式改成「Tailscale SSH」。',
      ConnectionFailureKind.loginTimeout =>
        '在期限内没等到登录结果。服务器很慢或者在等你做 Tailscale check 时会这样；可以在主机编辑页「高级 → 超时与保活」里把「认证超时」调大。',
      ConnectionFailureKind.handshake =>
        'SSH 握手中途断了：网络不稳、服务器正在重启时会这样。断线后的自动恢复会自己再试；一直这样的话先确认这个端口上是 SSH 服务。',
      ConnectionFailureKind.tmuxTarget =>
        '原来的 tmux 会话不在了（或者核对没通过），没有新建也没有附着别的。到 tmux 面板里自己选一个会话。',
      ConnectionFailureKind.pluginUnavailable =>
        '本机的插件不可用：到「设置 → 插件 → 插件（实验）」看它装着没有、批准了没有。这一步还没连服务器。',
      _ => '这类失败没有现成的建议。当时的失败页上有完整原话，这里只记了分类。',
    };

/// 一句话说是哪类失败，给连接记录的列表用。
String failureLabel(ConnectionFailureKind kind) => switch (kind) {
      ConnectionFailureKind.routeConfig => '路线配置有问题',
      ConnectionFailureKind.routeChanged => '断线期间路线改了',
      ConnectionFailureKind.credentialUnavailable => '凭据解不开',
      ConnectionFailureKind.identity => '私钥读不出来',
      ConnectionFailureKind.engineUnavailable => '终端引擎没启动',
      ConnectionFailureKind.unreachable => '连不到地址',
      ConnectionFailureKind.proxy => '代理握手失败',
      ConnectionFailureKind.hostKey => '指纹没通过核对',
      ConnectionFailureKind.authFailed => '服务器拒绝登录',
      ConnectionFailureKind.authAborted ||
      ConnectionFailureKind.authAbortedRelayed =>
        '登录前被断开',
      ConnectionFailureKind.channelOpen => '跳板机拒绝转发',
      ConnectionFailureKind.tailscaleDenied => 'Tailscale 拒绝登录',
      ConnectionFailureKind.tailscaleCheckNeedsUser => '要重新做 Tailscale check',
      ConnectionFailureKind.loginMode => '登录方式不对',
      ConnectionFailureKind.loginTimeout => '等登录结果超时',
      ConnectionFailureKind.handshake => 'SSH 握手中断',
      ConnectionFailureKind.tmuxTarget => 'tmux 会话不在了',
      ConnectionFailureKind.moshRoute => 'Mosh 只能直连',
      ConnectionFailureKind.moshPlugin => 'Mosh 插件不可用',
      ConnectionFailureKind.moshServerMissing => '服务器上没有 mosh-server',
      ConnectionFailureKind.moshServerPath => 'mosh-server 路径不对',
      ConnectionFailureKind.moshLocale => '服务器缺 UTF-8 locale',
      ConnectionFailureKind.moshBootstrap => 'mosh-server 的回应不可信',
      ConnectionFailureKind.pluginUnavailable => '插件不可用',
      ConnectionFailureKind.noCommonAlgorithm => '服务器只支持旧算法',
      ConnectionFailureKind.securityKey => '安全密钥',
      ConnectionFailureKind.other => '其他错误',
    };

String? _hint(ConnectionFailureKind kind) => switch (kind) {
      // Mosh（X09）：都还没做任何远端动作，或者只做到了 SSH 那一段。
      ConnectionFailureKind.moshRoute =>
        '要经代理或跳板机，把这台主机的协议改回 SSH（想断线后接着用，可以配合 tmux）；要用 Mosh，把连接路径改成「直连」。',
      ConnectionFailureKind.moshPlugin =>
        'Mosh 插件在「设置 → 插件 → 插件（实验）」里管理。这一步只查了本机，还没连服务器。',
      // R42 起能在 App 里确认后装（所有者 10-17 同意）；以前这里还写着「不会替你安装」。
      ConnectionFailureKind.moshServerMissing =>
        '点下面的「看安装命令」：认出了服务器的系统就给出对应命令，可以复制了自己装，也可以点「安装…」、确认后在新开的 SSH 标签里装一次（sudo 密码在那个终端里自己输）。'
            'SSH 这一段是通的。',
      ConnectionFailureKind.moshServerPath =>
        '在服务器上用 command -v mosh-server 查实际位置，把完整路径填到主机编辑页「高级 → Mosh 启动参数」里；清空就改回自动查找。SSH 这一段是通的。',
      ConnectionFailureKind.moshLocale =>
        '服务器上没有要用的 UTF-8 locale（没填时用 en_US.UTF-8）。先在服务器上用 locale -a 看有哪些 UTF-8 locale（很多系统自带 C.UTF-8），填到主机编辑页「高级 → Mosh 启动参数」的 locale 里；或者让管理员生成一个（比如 locale-gen en_US.UTF-8）。',
      ConnectionFailureKind.moshBootstrap =>
        '服务器上的 mosh-server 给出的连接信息不可信，没有用它；SSH 这一段是通的。检查服务器登录脚本有没有往输出里打东西。',
      ConnectionFailureKind.routeConfig => '路线配置有问题：到主机编辑器的「连接路径」里改，保存前会检查。',
      // 还没拨号就停了，和服务器、网络无关。
      ConnectionFailureKind.engineUnavailable =>
        '是这台手机上的终端引擎没能启动，还没开始连服务器。这个版本只带 Ghostty，没有别的引擎可换；「设置 → 终端」的「终端引擎」里能看到原话，「检查」可以再试一次。',
      ConnectionFailureKind.tailscaleDenied =>
        '到 Tailscale 后台检查访问策略里的 ssh 规则：来源要包含这次连接的来源节点（经代理时是代理出口那台，不是手机），'
            '登录用户名要在允许的列表里。',
      ConnectionFailureKind.identity => '到主机编辑器重新选择凭据，或在「凭据」里补上私钥的口令。',
      ConnectionFailureKind.proxy =>
        '检查代理的地址、端口、用户名和密码。代理之后怎么走由代理决定，App 只看得到代理返回的结果。',
      ConnectionFailureKind.unreachable =>
        '手机连不到这个地址：确认地址和端口没填错（SSH 端口和代理端口是两个不同的端口），'
            '以及当前网络——包括你开着的 VPN——能到达它。',
      ConnectionFailureKind.hostKey =>
        '服务器指纹没通过核对，已在发送任何登录信息前断开。先向管理员确认，不要为了连上而接受不认识的指纹。',
      ConnectionFailureKind.authFailed =>
        '服务器拒绝了登录：确认用户名；用密码的检查密码，用私钥的确认服务器上 authorized_keys 里有这把公钥。',
      // 代理或跳板机已经回报连上，随后在登录前被关：只说「端口不是 SSH」会把人引去查端口，
      // 而实际也可能是代理、跳板机之后那一段断了（R15 在 tailnet 测试环境里撞上过，App 看不到那一段）。
      ConnectionFailureKind.authAbortedRelayed =>
        '代理或跳板机已经回报连上了目标，随后在登录前断开：可能这个端口上不是 SSH 服务，'
            '也可能代理或跳板机之后的那一段断了，App 看不到那一段。先确认 SSH 端口，再看代理或跳板机那边能不能连到目标。',
      ConnectionFailureKind.authAborted =>
        '对方在登录完成前断开了：确认这个端口上是 SSH 服务——常见原因是把代理端口或别的服务端口填成了 SSH 端口。',
      ConnectionFailureKind.noCommonAlgorithm =>
        '这台服务器只认已淘汰的算法（CBC 加密、SHA-1 密钥交换、ssh-rsa 主机密钥），本 App 不再使用，重试也没用。升级服务器上的 SSH 才能连。',
      ConnectionFailureKind.securityKey =>
        '点「重新连接」，再按提示贴上或插上钥匙。这一步要你本人碰钥匙，App 不会自动重试。',
      ConnectionFailureKind.channelOpen =>
        '跳板机拒绝转发：确认跳板机允许 TCP 转发（sshd 的 AllowTcpForwarding），且下一跳地址从跳板机那边能到达。',
      _ => null,
    };
