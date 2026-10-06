/// 终端里点到的链接（R19，SEC08、TER08）。
///
/// 链接的文字和地址都来自远端输出，不可信：远端能用 OSC 8 把任意文字标成链接，显示「docs」实际指向别处；
/// 能写 `intent:`、`file:`、`javascript:` 这类会在手机上触发本地动作的地址。所以点了链接只弹确认框，
/// 从不直接打开；能交给浏览器的只有 http/https。
class TerminalLinkReview {
  TerminalLinkReview._({
    required this.shownText,
    required this.address,
    required this.uri,
    required this.refusal,
    required this.textDiffers,
    required this.nonAsciiHost,
  });

  /// [shownText] 是屏幕上的文字，[address] 是实际地址（OSC 8 链接两者可以不同；
  /// 从文字里认出来的网址两者相同）。
  factory TerminalLinkReview.of({
    required String shownText,
    required String address,
  }) {
    final trimmed = address.trim();
    final uri = Uri.tryParse(trimmed);
    final refusal = _refusal(trimmed, uri);
    final host = uri?.host ?? '';
    return TerminalLinkReview._(
      shownText: shownText,
      address: trimmed,
      uri: uri,
      refusal: refusal,
      textDiffers: shownText.trim() != trimmed,
      // Dart 把域名里的非英文字符转成 %XX；xn-- 开头的是同一回事的另一种写法（punycode）。
      nonAsciiHost: host.contains('%') ||
          host.runes.any((rune) => rune > 0x7e) ||
          host.split('.').any((label) => label.startsWith('xn--')),
    );
  }

  /// 超过这个长度不交给浏览器：正常网址到不了，太长的多半是塞了别的东西。
  static const maxLength = 2048;

  final String shownText;
  final String address;
  final Uri? uri;

  /// 不能打开的原因；能打开时为 null。
  final String? refusal;

  /// 屏幕上显示的文字和实际地址不一样（只有 OSC 8 链接会这样）。
  final bool textDiffers;

  /// 域名里有非英文字符：可能是长得像知名网站的仿冒域名。
  final bool nonAsciiHost;

  bool get canOpen => refusal == null;

  String get host => uri?.host ?? '';

  static String? _refusal(String address, Uri? uri) {
    if (address.isEmpty) return '链接地址是空的，或者解析不了';
    if (address.length > maxLength) return '链接太长';
    if (address.runes.any(
      (rune) => rune < 0x21 || rune == 0x7f || (rune >= 0x80 && rune <= 0x9f),
    )) {
      return '链接里有空白或控制字符';
    }
    if (uri == null) return '看不懂这个地址';
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return '只打开 http、https 网址；别的类型（intent:、file:、javascript: 等）可能在手机上触发本地动作';
    }
    if (uri.host.isEmpty) return '网址里没有域名';
    // https://google.com@evil.example 实际去的是 evil.example，@ 前面那段只是用来骗人看的。
    if (uri.userInfo.isNotEmpty) return '网址里带用户名或密码（@ 前面那段），可能是伪装';
    return null;
  }
}
