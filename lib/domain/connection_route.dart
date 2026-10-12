import 'dart:convert';

import 'dart:io' show InternetAddress, InternetAddressType;

import 'models/host.dart';
import 'tailscale_ssh.dart' show sshLoginModeKey;

part 'jump_route_choices.dart';

/// 路由配置无法按用户的选择执行。一律在拨号前抛出，不会退回直连。
class RouteConfigException implements Exception {
  const RouteConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 跳板机最多几跳（产品初始上限，见 plan/v3/docs/04）。超过就拨号前拒绝。
const maxJumpHosts = 3;

enum EndpointKind { ipv4, ipv6, domain }

/// 校验过的 host:port。地址规则只在这里定义一处（NET04）：
///
/// - IPv4、IPv6 字面量按地址处理；IPv6 可以带方括号，保存的是去掉方括号的写法。
/// - 域名只收 ASCII 字母、数字、`-`、`_`，总长不超过 253、每段不超过 63。
///   中文等国际化域名**不**自动转 Punycode：转换规则有多个版本，猜错就连到另一台机器，
///   所以直接拒绝，让用户填 `xn--` 开头的写法。
/// - 空白、控制字符（含 NUL）、带 `%` 网卡后缀的 IPv6、各段全是数字却不是合法 IPv4 的，都拒绝。
///
/// 这里只做语法检查，不解析 DNS：经代理或跳板到达的名字要由代理或上一跳去解析。
class Endpoint {
  const Endpoint._(this.host, this.port, this.kind);

  /// [what] 是报错里用来指明哪台机器的前缀，例如 `目标“web”`。
  factory Endpoint.parse(String rawHost, Object? rawPort,
      {required String what}) {
    final port = _parsePort(rawPort, what);
    var host = rawHost;
    if (host.isEmpty) throw RouteConfigException('$what的地址为空');
    if (_blankOrControl.hasMatch(host)) {
      throw RouteConfigException('$what的地址里有空格或控制字符');
    }
    final bracketed = host.startsWith('[') || host.endsWith(']');
    if (bracketed) {
      if (!host.startsWith('[') || !host.endsWith(']')) {
        throw RouteConfigException('$what的地址方括号不成对：$host');
      }
      host = host.substring(1, host.length - 1);
    }
    if (host.contains('%')) {
      throw RouteConfigException('$what的 IPv6 地址带 % 网卡后缀，不支持：$host');
    }
    final address = InternetAddress.tryParse(host);
    if (address != null) {
      final kind = address.type == InternetAddressType.IPv6
          ? EndpointKind.ipv6
          : EndpointKind.ipv4;
      if (bracketed && kind != EndpointKind.ipv6) {
        throw RouteConfigException('$what的地址方括号只能用于 IPv6：$rawHost');
      }
      return Endpoint._(host, port, kind);
    }
    if (bracketed || host.contains(':')) {
      throw RouteConfigException('$what的地址不是合法的 IPv6：$rawHost');
    }
    if (!_ascii.hasMatch(host)) {
      throw RouteConfigException(
        '$what的地址含非 ASCII 字符。国际化域名请填写 xn-- 开头的 Punycode 写法：$host',
      );
    }
    final name = host.endsWith('.') ? host.substring(0, host.length - 1) : host;
    if (name.length > 253) {
      throw RouteConfigException('$what的域名超过 253 个字符');
    }
    final labels = name.split('.');
    for (final label in labels) {
      if (label.isEmpty ||
          label.length > 63 ||
          !_label.hasMatch(label) ||
          label.startsWith('-') ||
          label.endsWith('-')) {
        throw RouteConfigException('$what的域名格式不对：$host');
      }
    }
    if (labels.every(_digits.hasMatch)) {
      throw RouteConfigException('$what的地址像 IPv4 但不合法：$host');
    }
    return Endpoint._(host, port, EndpointKind.domain);
  }

  final String host;
  final int port;
  final EndpointKind kind;

  /// `host:port`；IPv6 加方括号，否则 `::1:22` 分不清哪段是端口。
  String get authority =>
      kind == EndpointKind.ipv6 ? '[$host]:$port' : '$host:$port';

  /// 同一台机器的同一个端口（域名不区分大小写）。不做 DNS，所以名字和 IP 不会被判成相同。
  bool sameAs(Endpoint other) =>
      port == other.port && host.toLowerCase() == other.host.toLowerCase();

  @override
  String toString() => authority;

  static int _parsePort(Object? raw, String what) {
    final value = switch (raw) {
      int value => value,
      double value when value.isFinite && value == value.roundToDouble() =>
        value.toInt(),
      _ => null,
    };
    // 字符串 "22" 也拒绝：数据里的端口本该是数字，是字符串说明来源有问题，不替它猜。
    if (value == null) throw RouteConfigException('$what的端口格式无效：$raw');
    if (value < 1 || value > 65535) {
      throw RouteConfigException('$what的端口超出 1–65535：$value');
    }
    return value;
  }

  static final _blankOrControl = RegExp(r'[\s\x00-\x1f\x7f]');
  static final _ascii = RegExp(r'^[\x21-\x7e]+$');
  static final _label = RegExp(r'^[A-Za-z0-9_-]+$');
  static final _digits = RegExp(r'^[0-9]+$');
}

/// 手机上的第一条 TCP 连接怎么建。
sealed class RouteEntry {
  const RouteEntry();
}

/// 直接连第一跳。走系统默认网络，用户自己开着的 VPN 照常生效。
final class DirectEntry extends RouteEntry {
  const DirectEntry();

  @override
  String toString() => 'DirectEntry';
}

/// 先连代理，再由代理 CONNECT 到第一跳。
final class ProxyEntry extends RouteEntry {
  const ProxyEntry({
    required this.type,
    required this.endpoint,
    this.username,
    this.password,
  });

  final ProxyType type;
  final Endpoint endpoint;
  final String? username;
  final String? password;

  /// 不含用户名和密码：这个对象可能进日志或报错。
  @override
  String toString() => 'ProxyEntry(${type.name} ${endpoint.authority})';
}

/// 路线上的一台机器。登录身份只从这里取，和代理的账号密码无关。
class RouteHop {
  const RouteHop._(this.host, this.endpoint, this.key);

  /// 算路线那一刻的主机配置深拷贝。之后保险库里改了这台主机，不影响这一次连接。
  final HostProfile host;
  final Endpoint endpoint;

  /// 同样是深拷贝；主机没配私钥或私钥已被删除时为 null（沿用原来的认证回退）。
  final SshKeyProfile? key;

  RouteHop _withoutSecrets() {
    final data = _deepCopy(host.data)
      ..remove('password')
      ..remove('telnetPassword');
    final proxy = data['proxyConfig'];
    if (proxy is Map) {
      data['proxyConfig'] = Map<String, dynamic>.from(proxy)
        ..remove('password');
    }
    return RouteHop._(HostProfile(data), endpoint, null);
  }

  /// 这一跳是哪台机器、以谁的身份登录；不含密码和私钥内容。
  String get _shape => [
        endpoint.authority,
        host.username,
        host.authMethod.name,
        host.identityFileId ?? '',
        host.data[sshLoginModeKey]?.toString() ?? '',
      ].join('|');
}

/// 一次连接尝试的完整路线，在任何拨号之前算好，之后不再变（RTE03）。
///
/// 保险库里仍是桌面端 Netcatty 的旧字段（`hostChain`、`proxyProfileId`、`proxyConfig`），
/// 这样才能和桌面端互相同步；每次连接由 [resolveRoutePlan] 把它们换算成这一份路线，
/// 不写回、不迁移，所以也没有需要回滚的数据变更。
class RoutePlan {
  RoutePlan._(
    this.protocol,
    this.entry,
    List<RouteHop> jumps,
    this.target, {
    this.secretsForgotten = false,
  }) : jumps = List.unmodifiable(jumps);

  final HostProtocol protocol;
  final RouteEntry entry;

  /// 按连接顺序排列的跳板机，不含目标。
  final List<RouteHop> jumps;
  final RouteHop target;

  /// 密码、私钥、代理口令已经去掉（见 [withoutSecrets]）。这样的路线不能直接拿去连，
  /// 要先按保险库补回凭据，补之前核对路线没变。
  final bool secretsForgotten;

  /// 跳板机加目标，按连接顺序。
  List<RouteHop> get hops => List.unmodifiable([...jumps, target]);

  /// 同一条路线，去掉密码、私钥和代理口令（R22，SEC07）。
  ///
  /// 标签冻结的路线带着一份凭据副本，供断线自动恢复用。App 在后台待久了就把副本清掉，
  /// 只留下「走哪条路、以谁的身份」：恢复时按保险库现在的配置重算一次，形状对得上才用，
  /// 对不上（期间改了地址、换了跳板或代理、换了用户或私钥）就停下等用户——自动恢复不换路线（NET10）。
  RoutePlan withoutSecrets() => RoutePlan._(
        protocol,
        switch (entry) {
          final ProxyEntry proxy => ProxyEntry(
              type: proxy.type,
              endpoint: proxy.endpoint,
              username: proxy.username,
            ),
          final other => other,
        },
        [for (final hop in jumps) hop._withoutSecrets()],
        target._withoutSecrets(),
        secretsForgotten: true,
      );

  /// 不含凭据的路线形状：协议、入口（直连 / 哪个代理、代理用户名）、每一跳的地址、
  /// 用户名、认证方式、私钥 ID、登录模式。形状一样才算同一条路线、同一套身份。
  String get shape => [
        protocol.name,
        switch (entry) {
          final ProxyEntry proxy =>
            '${proxy.type.name}|${proxy.endpoint.authority}|${proxy.username ?? ''}',
          _ => 'direct',
        },
        for (final hop in hops) hop._shape,
      ].join('\n');
}

/// 把目标主机上的路由字段换算成 [RoutePlan]。只读内存里的配置，不做任何网络操作。
///
/// 规则：
/// - 路线只由**目标主机**决定。跳板机只贡献地址和登录身份；跳板机自己配的代理或跳板
///   不会被隐式套用（docs/04）。只有编辑器确认过的平面路线例外；确认失效仍拒绝。
/// - 同一处有两套配置（既引用代理配置又自带代理）时拒绝，不设隐藏优先级，让用户在编辑器里选。
/// - 缺失、格式不对、循环、超过 [maxJumpHosts] 跳、同一台机器出现两次、地址或端口非法，都拒绝。
/// - 目标上同时有代理和跳板，就是「代理入口 + 跳板」（docs/04 的高级模式）：代理只用于手机连第一跳，
///   后面每一跳经上一跳 SSH 转发，不再经过代理。代理放在目标上，是因为它不可能作用在
///   「最后一跳到目标」那一段——那段是从跳板机发出的，手机的代理够不着。
///
/// 出错一律抛 [RouteConfigException]，调用方此时还没有拨出任何连接。
RoutePlan resolveRoutePlan(
  HostProfile target, {
  required List<HostProfile> hosts,
  required List<ProxyProfile> proxyProfiles,
  List<SshKeyProfile> keys = const [],
}) {
  if (target.protocol == HostProtocol.plugin) {
    // 插件自己联网：本 App 的直连、代理、跳板对它都不起作用，算出一条路线来反而像是在说它会这样走。
    throw const RouteConfigException('插件主机不走本 App 的连接路径：插件自己联网，不经过代理和跳板。');
  }
  final targetName = '目标“${target.label}”';
  final targetHop = _hop(target, targetName, keys);
  final jumpIds = _jumpIds(target, targetName);

  if (target.protocol == HostProtocol.telnet) {
    if (_hasProxySetting(target)) {
      throw const RouteConfigException('Telnet 连接不支持代理；已配置代理时不会改为直连。');
    }
    if (jumpIds.isNotEmpty) {
      throw const RouteConfigException('Telnet 连接不支持跳板机；已配置跳板机时不会改为直连。');
    }
  }

  final entry = _entry(target, targetName, proxyProfiles);
  if (jumpIds.length > maxJumpHosts) {
    throw RouteConfigException(
      '$targetName的跳板机数量超过上限（最多 $maxJumpHosts 个）：${jumpIds.length}',
    );
  }

  final byId = {for (final host in hosts) host.id: host};
  final confirmed = _confirmedJumpRoutes(target, jumpIds, byId, proxyProfiles);
  final seen = <String>{target.id};
  final jumps = <RouteHop>[];
  for (final id in jumpIds) {
    final jump = byId[id];
    if (jump == null) throw RouteConfigException('找不到跳板机：$id');
    if (!seen.add(jump.id)) throw const RouteConfigException('跳板机链路存在循环');
    if (jump.protocol != HostProtocol.ssh) {
      throw RouteConfigException('跳板机必须使用 SSH：${jump.label}');
    }
    final jumpName = '跳板机“${jump.label}”';
    if (_hasProxySetting(jump) && !(confirmed && jumps.isEmpty)) {
      throw RouteConfigException(
        '$jumpName自己配置了代理，经它连接时不会隐式套用。'
        '需要「先经代理再走跳板」时，请把代理设在$targetName上，它会作为入口只用于连第一跳。',
      );
    }
    if (_jumpIds(jump, jumpName).isNotEmpty && !confirmed) {
      throw RouteConfigException(
        '$jumpName自己又配置了跳板机，不支持嵌套。请在$targetName上按顺序列出全部跳板机。',
      );
    }
    jumps.add(_hop(jump, jumpName, keys));
  }

  final hops = [...jumps, targetHop];
  for (var i = 0; i < hops.length; i++) {
    for (var j = i + 1; j < hops.length; j++) {
      if (hops[i].endpoint.sameAs(hops[j].endpoint)) {
        throw RouteConfigException(
          '路线里同一台机器出现了两次：${hops[i].endpoint.authority}',
        );
      }
    }
  }
  return RoutePlan._(target.protocol, entry, jumps, targetHop);
}

/// 主机上有没有任何代理设置（不管有效与否）。编辑器选「不用代理」时会删掉这两个字段，
/// 所以只要字段在，就是用户选过代理。
bool _hasProxySetting(HostProfile host) =>
    host.proxyProfileId?.isNotEmpty == true || host.data['proxyConfig'] != null;

/// 读 `hostChain.hostIds`。格式不对时拒绝，而不是像 [HostProfile.hostChainIds] 那样当成没有跳板——
/// 那样会直连目标，绕过用户配的跳板。
List<String> _jumpIds(HostProfile host, String name) {
  final chain = host.data['hostChain'];
  if (chain == null) return const [];
  if (chain is! Map) throw RouteConfigException('$name的跳板机配置格式无效');
  final ids = chain['hostIds'];
  if (ids == null) return const [];
  if (ids is! List) throw RouteConfigException('$name的跳板机配置格式无效');
  return [
    for (final id in ids)
      if (id is String && id.isNotEmpty)
        id
      else
        throw RouteConfigException('$name的跳板机列表里有无效条目：$id'),
  ];
}

RouteEntry _entry(
  HostProfile host,
  String name,
  List<ProxyProfile> profiles,
) {
  final profileId = host.proxyProfileId;
  final hasProfile = profileId != null && profileId.isNotEmpty;
  final inline = host.data['proxyConfig'];
  if (hasProfile && inline != null) {
    throw RouteConfigException(
      '$name既引用了代理配置，又自带一份代理设置，不知道该用哪个。请在编辑器里只保留一个。',
    );
  }
  final ProxyConfig config;
  final String proxyName;
  if (hasProfile) {
    final profile =
        profiles.where((value) => value.id == profileId).firstOrNull;
    if (profile == null) throw RouteConfigException('找不到代理配置：$profileId');
    // 以前 profile 在但 config 缺失时返回 null，被当成「没配代理」直连了目标。
    config = profile.config ??
        (throw RouteConfigException('代理配置“${profile.label}”内容缺失'));
    proxyName = '代理配置“${profile.label}”';
  } else if (inline != null) {
    if (inline is! Map) throw const RouteConfigException('主机的代理配置格式无效');
    config = ProxyConfig.fromJson(Map<String, dynamic>.from(inline));
    proxyName = '$name自带的代理';
  } else {
    return const DirectEntry();
  }
  final invalid = config.invalidReason;
  if (invalid != null) throw RouteConfigException(invalid);
  return ProxyEntry(
    type: config.type!,
    endpoint: Endpoint.parse(config.host, config.port, what: proxyName),
    username: config.username,
    password: config.password,
  );
}

RouteHop _hop(HostProfile host, String name, List<SshKeyProfile> keys) {
  final endpoint =
      Endpoint.parse(host.hostname, host.data['port'] ?? 22, what: name);
  final keyId = host.identityFileId;
  final key = keyId == null
      ? null
      : keys.where((value) => value.id == keyId).firstOrNull;
  return RouteHop._(
    HostProfile(_deepCopy(host.data)),
    endpoint,
    key == null ? null : SshKeyProfile(_deepCopy(key.data)),
  );
}

/// HostProfile 构造只做浅拷贝，嵌套的 proxyConfig / hostChain 仍和保险库共用；
/// 连接中编辑主机会就地改到它们，所以快照要逐层复制。
Map<String, dynamic> _deepCopy(Map<String, dynamic> value) =>
    _copy(value) as Map<String, dynamic>;

Object? _copy(Object? value) => switch (value) {
      Map() => <String, dynamic>{
          for (final entry in value.entries)
            entry.key.toString(): _copy(entry.value),
        },
      List() => [for (final item in value) _copy(item)],
      _ => value,
    };
