import 'connection_route.dart';
import 'models/host.dart';
import 'plugins/mosh_route.dart';
import 'security_key.dart';
import 'tailscale_ssh.dart';
import 'credential_identity.dart';

/// 主机现在的配置连接时会怎么走：算得出来给路线；算不出来，或 Mosh 配了代理、跳板，给连接时会报的那句话。
///
/// 主机详情和编辑器的预览都用它，和真正连接用的是同一个 [resolveRoutePlan]。以前主机详情自己拼代理、跳板两行：
/// 引用的代理配置被删了就不显示代理行，看着像直连；被删的跳板悄悄少一跳——真连接时这两种都会报「找不到…」。
/// 插件主机不算路线（插件自己联网），调用方自己处理。
({RoutePlan? plan, String? error}) hostRouteStatus(
  HostProfile host, {
  required List<HostProfile> hosts,
  required List<ProxyProfile> proxyProfiles,
  List<SshKeyProfile> keys = const [],
  List<Map<String, dynamic>> identities = const [],
}) {
  try {
    final plan = resolveRoutePlan(
      host,
      hosts: hosts,
      proxyProfiles: proxyProfiles,
      keys: keys,
      identities: identities,
    );
    if (plan.protocol == HostProtocol.mosh) {
      final unsupported = moshRouteProblem(plan);
      if (unsupported != null) {
        return (plan: plan, error: unsupported.toString());
      }
    }
    return (plan: plan, error: null);
  } on RouteConfigException catch (error) {
    return (plan: null, error: error.message);
  }
}

/// SSH 登录时实际会发什么，一句话。Telnet、插件主机没有 SSH 登录，返回 null。
///
/// 按连接时的真实规则写（`ssh_identity.dart` 的 `loadHopIdentities`、`ssh_service.dart` 的 `onPasswordRequest`）：
/// 选「密码」不发私钥，选「私钥」不发密码，选「自动」私钥、保存的密码都试，最后服务器问什么再问你。
/// 以前主机详情只看有没有挂私钥：选了「密码」又挂着私钥时显示「私钥」，登录时其实根本不发它。
///
/// [host] 要传展开过身份的那份（[applyHostIdentity]）；引用了身份时 [identity] 给出来，前面写上是哪个凭据。
String? describeLogin(
  HostProfile host,
  SshKeyProfile? key, {
  IdentityProfile? identity,
}) {
  final login = _describeLogin(host, key);
  if (login == null || identity == null) return login;
  return '凭据“${identity.label}”：$login';
}

String _keyText(SshKeyProfile key) => SecurityKeyStub.isStubPem(key.privateKey)
    ? '安全密钥“${key.label}”'
    : '私钥“${key.label}”';

String? _describeLogin(HostProfile host, SshKeyProfile? key) {
  if (host.protocol != HostProtocol.ssh && host.protocol != HostProtocol.mosh) {
    return null;
  }
  if (sshLoginModeOf(host) == SshLoginMode.tailscale) {
    return 'Tailscale SSH（不发密码和私钥）';
  }
  final hasPassword = host.password?.isNotEmpty == true;
  final hasKey = key != null && key.privateKey.isNotEmpty;
  switch (host.authMethod) {
    case HostAuthMethod.password:
      return hasPassword ? '密码' : '密码（没保存，登录时问你）';
    case HostAuthMethod.key:
      // 私钥被删了：连接在拨号前就被拒绝（SEC06），不会改用密码。
      return hasKey ? _keyText(key) : '私钥（引用的私钥已不存在，连接会被拒绝）';
    case HostAuthMethod.auto:
      final tries = [
        if (hasKey) _keyText(key),
        if (hasPassword) '保存的密码',
      ];
      return tries.isEmpty
          ? '自动（没保存私钥和密码，登录时问你）'
          : '自动：先试${tries.join('，再试')}，都不行再问你';
  }
}
