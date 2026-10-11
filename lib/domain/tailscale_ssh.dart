import 'connection_route.dart';
import 'models/host.dart';

/// 一台主机怎么登录 SSH。
enum SshLoginMode {
  /// 普通 SSH：按主机的认证设置发密码、私钥、键盘交互。默认值。
  standard,

  /// Tailscale SSH（Tailnet 外部身份认证）：只发 none 认证，不发密码、私钥，
  /// 由目标上的 Tailscale 按 tailnet 策略决定放不放行，必要时要你在浏览器里做 check。
  tailscale,
}

/// 存在主机 data 里的键。桌面端 Netcatty 不认识它：同步过去的主机在桌面端照普通 SSH 连。
///
/// 不复用 `authMethod`：那是桌面端也读写的字段，多一个它不认识的值，桌面端可能把整台主机读坏。
const sshLoginModeKey = 'shunSshLogin';

/// 只认明确写着 `tailscale` 的主机。地址是不是 100.x、是不是从 Tailscale 目录导入的，一概不看（TSC07）：
/// 自动换成 none 等于替用户换了一种身份去登录。
SshLoginMode sshLoginModeOf(HostProfile host) =>
    host.data[sshLoginModeKey] == 'tailscale'
        ? SshLoginMode.tailscale
        : SshLoginMode.standard;

/// 唯一放行的 check 链接域名。Tailscale 官方文档里 check 链接都在这里（docs/05「R14 固定的口径」）。
/// 自建控制面（Headscale 等）的链接不在名单里，一律不打开。
const tailscaleCheckHost = 'login.tailscale.com';

/// check 链接的路径只能是 `/a/<字母数字>`。路径换了样子就是 Tailscale 改了格式，先不放行，
/// 核对过再改这里——宁可打不开，也不打开一条没见过的链接。
final _checkPath = RegExp(r'^/a/[A-Za-z0-9]{1,128}$');

/// 认链接：`scheme://…` 都算，不只 http(s)——`intent://`、`market://` 也要被当成链接拦下，不能当普通文字放过。
final _linkLike = RegExp(r'[A-Za-z][A-Za-z0-9+.\-]{0,31}://[^\s<>"]+');

/// 服务器发来的一条 SSH 认证 banner，按 App 能对它做什么分三类。
sealed class AuthBanner {
  const AuthBanner(this.text);

  /// 去掉控制字符、截短、链接换成 `[link]` 后的原文（服务器原文多是英文，占位符跟着用英文）。可以显示、可以写进报错；
  /// 不含链接本身——check 链接带一次性 token，不能进日志、报错和诊断（docs/05）。
  final String text;
}

/// 没有链接的 banner，比如 Tailscale 拒绝时的「tailscale: tailnet policy does not permit you …」。
final class PlainAuthBanner extends AuthBanner {
  const PlainAuthBanner(super.text);
}

/// 符合要求的 Tailscale check 链接：https、域名是 [tailscaleCheckHost]、路径 `/a/…`、只有这一条。
final class CheckLinkBanner extends AuthBanner {
  const CheckLinkBanner(super.text, this.link);

  /// 只在用户点「在浏览器中打开」时交给系统；不打印、不放进 toString。
  final Uri link;

  /// 给人看的样子：域名加被遮住的 token。
  String get display => '${link.host}/a/…';

  @override
  String toString() => 'CheckLinkBanner($display)';
}

/// 有链接、但不符合要求：域名不对、不是 https、不止一条、带账号或端口等。App 不打开它。
final class RejectedLinkBanner extends AuthBanner {
  const RejectedLinkBanner(super.text, this.reason, {this.linkHost});

  /// 为什么不打开，给人看的一句话。
  final String reason;

  /// 链接指向的域名（解析得出来时）。只显示域名，不显示整条链接。
  final String? linkHost;
}

/// 把服务器发来的 banner 分类。banner 完全由服务器决定，这里只信结构，不信文字。
AuthBanner classifyAuthBanner(String raw) {
  final clean = _sanitize(raw);
  final links = _linkLike.allMatches(clean).map((m) => m.group(0)!).toList();
  final text = _truncate(clean.replaceAll(_linkLike, '[link]').trim());
  if (links.isEmpty) return PlainAuthBanner(text);
  if (clean.length != raw.replaceAll('\r', '').length) {
    // 删掉控制字符后链接可能「变好」（比如夹了 U+202E 的链接删掉它就成了合法样子）。
    // 带链接的 banner 里出现不可见字符本身就可疑，不放行，也不替它修。
    return RejectedLinkBanner(text, '提示里夹带了不可见的控制字符');
  }
  if (links.length > 1) {
    return RejectedLinkBanner(text, '里面不止一条链接，分不清该打开哪条');
  }
  final candidate = _trimTrailingPunctuation(links.single);
  final uri = Uri.tryParse(candidate);
  if (uri == null || uri.host.isEmpty) {
    return RejectedLinkBanner(text, '链接格式不对');
  }
  final host = uri.host.toLowerCase();
  if (uri.scheme.toLowerCase() != 'https') {
    return RejectedLinkBanner(text, '不是 https 链接', linkHost: host);
  }
  if (host != tailscaleCheckHost) {
    return RejectedLinkBanner(
      text,
      '域名不是 $tailscaleCheckHost',
      linkHost: host,
    );
  }
  if (uri.userInfo.isNotEmpty || (uri.hasPort && uri.port != 443)) {
    return RejectedLinkBanner(text, '链接里带了账号或别的端口', linkHost: host);
  }
  if (!_checkPath.hasMatch(uri.path) || uri.hasQuery || uri.hasFragment) {
    return RejectedLinkBanner(
      text,
      '链接的样子和 Tailscale check 链接不一样',
      linkHost: host,
    );
  }
  return CheckLinkBanner(
      text, Uri(scheme: 'https', host: host, path: uri.path));
}

/// 去掉 C0/C1 控制字符（保留换行和制表；回车直接丢）：banner 会显示在界面上，
/// 不能夹带终端控制序列或改写方向的字符。
String _sanitize(String raw) {
  final out = StringBuffer();
  for (final rune in raw.runes) {
    final control = (rune < 0x20 && rune != 0x0a && rune != 0x09) ||
        (rune >= 0x7f && rune <= 0x9f) ||
        // 改写文字方向的字符：能让显示出来的域名和实际的不一样。
        (rune >= 0x202a && rune <= 0x202e) ||
        (rune >= 0x2066 && rune <= 0x2069);
    if (!control) out.writeCharCode(rune);
  }
  return out.toString();
}

const _maxBannerChars = 600;

String _truncate(String text) => text.length <= _maxBannerChars
    ? text
    : '${text.substring(0, _maxBannerChars)}…';

String _trimTrailingPunctuation(String link) {
  var end = link.length;
  while (end > 0 && '.,;:!?)]}\'"'.contains(link[end - 1])) {
    end--;
  }
  return link.substring(0, end);
}

/// 用 Tailscale SSH 登录路线上第 [hopIndex] 跳时，Tailscale 把这次登录算成哪台节点发起的。
///
/// Tailscale 按「连进来的那台 tailnet 节点」的身份套策略（docs/05）：不是设备目录用的 API token
/// 或 OAuth client 的账号，也不一定是手机自己。App 只看得到路线，看不到代理后面是谁，
/// 所以经代理时只能说清是「代理出口那台节点」，不假装知道是哪台。
String tailscaleSourceNode(RoutePlan plan, int hopIndex) {
  if (hopIndex > 0) {
    final previous = plan.hops[hopIndex - 1].host.label;
    return '跳板机“$previous”所在的节点：这一跳是从它转发出去的';
  }
  return switch (plan.entry) {
    DirectEntry() => '这台手机在 Tailscale 里的节点（手机上要开着官方 Tailscale App 的 VPN）',
    ProxyEntry(:final endpoint) => '代理出口所在的节点（代理地址 ${endpoint.authority}）：'
        '手机上的 TailSocks 就是 TailSocks 登录的那个节点，远程 SOCKS 就是那台远程机器；'
        '多人共用一个代理，大家都以同一个节点的身份登录',
  };
}

/// 目录凭据和 SSH 登录无关，这句话每处解释来源节点时都要带上。
const tailscaleCatalogIsNotIdentity =
    '设备目录用的 API token、OAuth client 不参与 SSH 登录，Tailscale 也不按它们认人。';
