import '../infrastructure/tailscale/tailscale_api.dart';

/// Tailscale 设置页那一个「API key」框里填的是什么（R26）。按 Tailscale 的前缀认：
/// https://tailscale.com/kb/1277/key-prefixes
sealed class TailscaleKeyInput {
  const TailscaleKeyInput();
}

/// `tskey-client-…`：OAuth client。能限制成只读设备，确认了才存在本机、以后自动刷新。
class TailscaleOAuthClientKey extends TailscaleKeyInput {
  const TailscaleOAuthClientKey(this.credential);
  final OAuthClientCredential credential;
}

/// `tskey-api-…` 或没前缀的：访问令牌。它的权限就是建它的人的整个账号，限不住，所以只用这一次、不保存。
class TailscaleAccessTokenKey extends TailscaleKeyInput {
  const TailscaleAccessTokenKey(this.token);
  final String token;
}

/// 一看就读不了设备列表的 key（比如让设备加入 tailnet 的 auth key）：不发请求，直接说清楚。
class TailscaleKeyRejected extends TailscaleKeyInput {
  const TailscaleKeyRejected(this.reason);
  final String reason;
}

TailscaleKeyInput parseTailscaleKey(String raw) {
  // 后台生成的 auth key 可能带 ?ephemeral=… 这类参数，不是 key 的一部分。
  final key = raw.trim().split('?').first;
  if (key.startsWith('tskey-client-')) {
    // Tailscale 自己的工具只拿 secret 换 token，client ID 随便填（tailscale 仓库
    // feature/oauthkey/oauthkey.go）。secret 长这样：tskey-client-<client ID>-<随机串>，
    // 从里面取出 ID 存下来，在后台对得上是哪个 client。
    final rest = key.substring('tskey-client-'.length);
    final dash = rest.indexOf('-');
    return TailscaleOAuthClientKey(OAuthClientCredential(
      clientId: dash > 0 ? rest.substring(0, dash) : '-',
      clientSecret: key,
    ));
  }
  if (key.startsWith('tskey-api-')) return TailscaleAccessTokenKey(key);
  if (key.startsWith('tskey-auth-')) {
    return const TailscaleKeyRejected(
        '这是让设备加入 tailnet 的 auth key，读不了设备列表。要 tskey-client-…（OAuth client，推荐）或 tskey-api-…（访问令牌）。');
  }
  if (key.startsWith('tskey-')) {
    return const TailscaleKeyRejected(
        '这种 key 读不了设备列表。要 tskey-client-…（OAuth client，推荐）或 tskey-api-…（访问令牌）。');
  }
  // 没前缀的当访问令牌试一次（以前「粘贴 token 读一次」也收它们），错了服务器会说。
  return TailscaleAccessTokenKey(key);
}
