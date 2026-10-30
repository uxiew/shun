/// 进日志之前把认得出来的敏感东西换成 `<IP>`、`<host>`、`<redacted>` 这类记号（R26 F24）。
/// 记号用英文：它们是日志内容，不跟界面语言走，中英文界面看到的一样。
///
/// 日志只存在本机、不进导出和同步，但用户会把它复制出去发给别人看，所以写进去的时候就换，不等导出。
/// 异常信息里常见的是地址和登录名（`SocketException: ... address = 100.64.0.9`、`root@web`），
/// 偶尔是拼进 URL 的口令、令牌。密码和私钥本身不该出现在异常里，这里只是兜底，认不全。
///
/// [stack] 为 true 时是堆栈：里面的 `package:shun/...dart`、`io.flutter.embedding...` 是代码位置，
/// 长得像域名但不是，不按域名换；地址、令牌照样换。
String scrubLogText(String text, {bool stack = false}) {
  var out = text;
  for (final (pattern, replacement) in _secrets) {
    out = out.replaceAll(pattern, replacement);
  }
  out = out.replaceAllMapped(_userAtHost, (m) => '<user>@${m[2]}');
  out = out.replaceAll(_email, '<email>');
  out = out.replaceAll(_ipv4, '<IP>');
  out = out.replaceAllMapped(
      _ipv6, (m) => _looksLikeIpv6(m[0]!) ? '<IP>' : m[0]!);
  if (!stack) {
    out = out.replaceAllMapped(
        _domain, (m) => _codeSuffix.hasMatch(m[0]!) ? m[0]! : '<host>');
  }
  return out;
}

final _secrets = <(RegExp, String)>[
  // Tailscale（auth key、API 令牌、OAuth client secret）、GitHub、一般的 Bearer。
  (RegExp(r'tskey-[A-Za-z0-9-]+'), 'tskey-<redacted>'),
  (
    RegExp(r'\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})'),
    '<token>'
  ),
  (
    RegExp(r'(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}', caseSensitive: false),
    r'$1 <redacted>'
  ),
  // URL 里的 user:password@ 和 ?token= / &password= 这类参数。
  (RegExp(r'//[^/\s:@]+:[^/\s@]+@'), '//<user>:<redacted>@'),
  (
    RegExp(
        r'((?:pass(?:word|wd)?|pwd|secret|token|key|auth)\s*[=:]\s*)[^\s&,;"]+',
        caseSensitive: false),
    r'$1<redacted>'
  ),
  // 私钥整块。
  (
    RegExp(
        r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----'),
    '<private key redacted>'
  ),
];

final _userAtHost =
    RegExp(r'\b([A-Za-z0-9._-]+)@([A-Za-z0-9.-]+|<IP>|\[[0-9a-fA-F:]+\])');
final _email = RegExp(r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b');
final _ipv4 = RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b');
final _ipv6 = RegExp(r'\b(?:[0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}\b');
final _domain = RegExp(
    r'\b(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}\b');

/// 堆栈和报错里常见的文件名：不是域名。
final _codeSuffix =
    RegExp(r'\.(dart|kt|java|so|cc|cpp|c|h|js|json|yaml|xml|txt|log|png|apk)$');

/// 时间 `12:34:56`、`::` 这类不是地址：至少要有一段十六进制字母或者五段以上。
bool _looksLikeIpv6(String value) {
  final parts = value.split(':');
  if (parts.where((p) => p.isNotEmpty).length < 2) return false;
  return parts.length >= 5 || RegExp(r'[a-fA-F]').hasMatch(value);
}
