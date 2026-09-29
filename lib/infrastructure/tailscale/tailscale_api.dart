import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'tailscale_device.dart';

// 只读 Tailscale 设备目录的 HTTP 适配（R11）。
//
// 端点、参数、字段全部照官方 OpenAPI（api.tailscale.com 自带，openapi 3.1.0 / info.version v2，
// 官方声明 unstable、没有日期字段，所以用 sha256 固定：b416d98e…742d，2026-09-29 下载）
// 与官方文档 kb/1215、kb/1623；出处和摘录见 plan/v3/docs/05-tailscale.md 的「R11 固定的官方口径」。
// 没写在那里的参数一个都不发。

/// 生产环境唯一允许的服务器。不从导入文件、设置或描述符里读，所以没人能把认证请求改寄到别处。
final tailscaleApiOrigin = Uri.parse('https://api.tailscale.com');

/// 只请求这一个 scope：官方说明它只放行「列设备」和「读单个设备」两个端点。
const tailscaleDeviceReadScope = 'devices:core:read';

/// 2024-11-14 之前创建的凭据用的旧名，同样只读设备。只用来判断返回的 token 范围，从不主动请求。
const _legacyDeviceReadScope = 'devices:read';

/// 响应体上限。官方不分页、一次返回全部设备；默认字段每台约 0.7 KB，16 MiB 足够两万台，再大就当异常。
const _maxResponseBytes = 16 * 1024 * 1024;

/// token 提前多久算过期：官方有效期固定 1 小时，留 10%（至少 60 秒）余量，免得请求途中过期。
Duration _refreshMargin(Duration lifetime) {
  final tenth = lifetime ~/ 10;
  return tenth < const Duration(seconds: 60)
      ? const Duration(seconds: 60)
      : tenth;
}

/// 用户交来的目录凭据。两种都只在内存里；OAuth client 要不要落盘由调用方显式决定。
sealed class TailscaleCredential {
  const TailscaleCredential();
}

/// 用户粘贴的短期 access token。
///
/// 官方的 API access token（`tskey-api-`）拥有创建者的全部 API 权限，不是只读；
/// App 也没有官方途径查询一个 token 的范围。所以这类 token 一律「范围未验证」，
/// 只用于这一次读取，不保存（docs/05：首版不提供长期保存这类 token 的入口）。
class PastedAccessToken extends TailscaleCredential {
  const PastedAccessToken(this.token);
  final String token;

  @override
  String toString() => 'PastedAccessToken(<redacted>)';
}

/// 用户自己在 Tailscale 后台创建的 OAuth client（trust credential）。
class OAuthClientCredential extends TailscaleCredential {
  const OAuthClientCredential({
    required this.clientId,
    required this.clientSecret,
  });
  final String clientId;
  final String clientSecret;

  @override
  String toString() => 'OAuthClientCredential($clientId, <redacted>)';
}

/// 这次读取所用 token 的权限，以服务器返回的 scope 为准，不看前缀猜。
enum TokenScopeStatus {
  /// 服务器明确回报只有设备读取。
  deviceReadOnly,

  /// 服务器明确回报全是只读，但不止设备（比如 all:read）。
  readOnlyBroader,

  /// 粘贴的 token，或服务器没回报 scope：不知道，不能说是只读。
  unverified,
}

sealed class TailscaleApiException implements Exception {
  const TailscaleApiException(this.message);

  /// 给用户看的说明。永远不含 token、client secret 或 Authorization 头。
  final String message;

  @override
  String toString() => message;
}

/// token 无效、过期或已撤销，且受控刷新一次后仍然不行：要用户重新授权。本地缓存和主机不动。
class TailscaleReauthorizationRequired extends TailscaleApiException {
  const TailscaleReauthorizationRequired(super.message);
}

/// 服务器拒绝（403），通常是凭据没有 devices:core:read。不重试。
class TailscaleForbidden extends TailscaleApiException {
  const TailscaleForbidden(super.message);
}

class TailscaleTailnetNotFound extends TailscaleApiException {
  const TailscaleTailnetNotFound(super.message);
}

/// 429。只报告，不自动重试；[retryAfter] 来自 Retry-After 头，官方没承诺一定有，没有就是 null。
class TailscaleRateLimited extends TailscaleApiException {
  const TailscaleRateLimited(super.message, this.retryAfter);
  final Duration? retryAfter;
}

/// 服务器要求跳到别处。一律不跟：跟了就可能把 Authorization 或 client secret 带到另一个 origin。
class TailscaleRedirectRefused extends TailscaleApiException {
  const TailscaleRedirectRefused(super.message);
}

/// 换来的 token 权限超出只读（比如带 devices:core 写权限）。不使用、不保存。
class TailscaleScopeTooBroad extends TailscaleApiException {
  const TailscaleScopeTooBroad(super.message, this.grantedScopes);
  final Set<String> grantedScopes;
}

class TailscaleServerError extends TailscaleApiException {
  const TailscaleServerError(super.message, this.statusCode);
  final int statusCode;
}

/// 响应不是约定的格式、过大或 token 响应缺字段。
class TailscaleMalformedResponse extends TailscaleApiException {
  const TailscaleMalformedResponse(super.message);
}

class TailscaleNetworkError extends TailscaleApiException {
  const TailscaleNetworkError(super.message);
}

class TailscaleInvalidInput extends TailscaleApiException {
  const TailscaleInvalidInput(super.message);
}

class _AccessToken {
  _AccessToken(this.value, this.refreshAt, this.scopeStatus);
  final String value;
  final DateTime? refreshAt;
  final TokenScopeStatus scopeStatus;
}

/// 列设备的结果：一次完整响应的解析，外加这次用的 token 范围。
class TailscaleDeviceListing {
  const TailscaleDeviceListing({
    required this.snapshot,
    required this.scopeStatus,
  });
  final TailscaleDeviceSnapshot snapshot;
  final TokenScopeStatus scopeStatus;
}

/// 一个目录来源的读取会话：持有凭据（内存）和当前 access token（内存）。
///
/// - 401：OAuth 模式下作废 token、重新换一次、重试一次；仍 401 或粘贴 token 的 401 → 要求重新授权。
/// - 403 / 404 / 429 / 5xx：不重试，原样报给用户。没有后台轮询、没有保活定时器。
/// - 不跟随任何重定向；只访问 token 端点和列设备端点。
class TailscaleCatalogClient {
  TailscaleCatalogClient._(
    this._http,
    this._origin,
    this._credential, {
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// 生产用：服务器固定为官方 origin。
  factory TailscaleCatalogClient.official(
    http.Client client,
    TailscaleCredential credential,
  ) =>
      TailscaleCatalogClient._(client, tailscaleApiOrigin, credential);

  /// 只给测试和本机 fixture 用：服务器只能是本机回环地址，免得这个入口被当成「可配置服务器」。
  @visibleForTesting
  factory TailscaleCatalogClient.fixture(
    http.Client client,
    Uri loopbackOrigin,
    TailscaleCredential credential, {
    DateTime Function()? now,
  }) {
    final host = loopbackOrigin.host;
    if (host != '127.0.0.1' && host != 'localhost' && host != '::1') {
      throw ArgumentError('fixture 只能指向本机回环地址');
    }
    return TailscaleCatalogClient._(
      client,
      loopbackOrigin,
      credential,
      now: now,
    );
  }

  final http.Client _http;
  final Uri _origin;
  final TailscaleCredential _credential;
  final DateTime Function() _now;
  _AccessToken? _token;

  /// tailnet 的写法：`-`（凭据所属的 tailnet，官方推荐）、tailnet ID（如 T1234CNTRL）或 tailnet 名。
  /// 作为单个路径段编码；含 `/`、空白、控制字符或过长的直接拒绝，不拼进 URL。
  static final _tailnet = RegExp(r'^[A-Za-z0-9._@+-]{1,253}$');

  /// `GET /api/v2/tailnet/{tailnet}/devices`，默认字段集（不传 fields）。
  ///
  /// 故意不请求 `fields=all`：那会多返回 sshEnabled、clientConnectivity（含公网端点）、
  /// postureIdentity（含设备序列号）等管理数据，目录用不到（docs/05：不保存不需要的管理数据）。
  Future<TailscaleDeviceListing> listDevices({String tailnet = '-'}) async {
    if (!_tailnet.hasMatch(tailnet)) {
      throw const TailscaleInvalidInput(
          'tailnet 写法无效：只能是 -、tailnet ID 或 tailnet 名');
    }
    final uri = _origin.replace(
      pathSegments: ['api', 'v2', 'tailnet', tailnet, 'devices'],
    );
    var refreshed = false;
    while (true) {
      final token = await _currentToken();
      final response = await _send(
        http.Request('GET', uri)
          ..headers['Authorization'] = 'Bearer ${token.value}'
          ..headers['Accept'] = 'application/json',
      );
      if (response.statusCode == 401) {
        _token = null;
        if (_credential is OAuthClientCredential && !refreshed) {
          refreshed = true; // 受控刷新：只换一次 token、只重试一次。
          continue;
        }
        throw TailscaleReauthorizationRequired(
          _credential is PastedAccessToken
              ? 'Tailscale 不接受这个 access token（无效、已过期或已被撤销）。请重新生成一个再导入；本地已导入的设备和主机不受影响。'
              : 'Tailscale 不接受这个 OAuth client 换来的 token。请在 Tailscale 后台确认 client 仍有效，必要时重新授权；本地已导入的设备和主机不受影响。',
        );
      }
      _throwForStatus(response, context: '读取设备列表');
      final TailscaleDeviceSnapshot snapshot;
      try {
        snapshot = TailscaleDeviceSnapshot.parse(response.body);
      } on FormatException catch (e) {
        throw TailscaleMalformedResponse(e.message);
      }
      return TailscaleDeviceListing(
        snapshot: snapshot,
        scopeStatus: token.scopeStatus,
      );
    }
  }

  /// 放弃内存里的 token。用户删除这个目录来源、或离开导入流程时调用。
  void forgetToken() => _token = null;

  Future<_AccessToken> _currentToken() async {
    final cached = _token;
    if (cached != null &&
        (cached.refreshAt == null || _now().isBefore(cached.refreshAt!))) {
      return cached;
    }
    final credential = _credential;
    final token = switch (credential) {
      PastedAccessToken(:final token) => _pasted(token),
      OAuthClientCredential() => await _exchange(credential),
    };
    _token = token;
    return token;
  }

  _AccessToken _pasted(String token) {
    final value = token.trim();
    if (value.isEmpty || value.length > 4096 || _hasControl(value)) {
      throw const TailscaleInvalidInput('access token 为空或格式不对');
    }
    // 粘贴的 token 没有有效期信息：不自己猜，401 时就要求重新提供。
    return _AccessToken(value, null, TokenScopeStatus.unverified);
  }

  /// OAuth client credentials：`POST /api/v2/oauth/token`，表单参数。
  /// 官方示例只带 client_id / client_secret；这里另带 RFC 6749 §4.4.2 规定的 grant_type，
  /// 以及 scope=devices:core:read（官方文档列出的可选参数），把换来的 token 收窄到只读设备。
  Future<_AccessToken> _exchange(OAuthClientCredential credential) async {
    final id = credential.clientId.trim();
    final secret = credential.clientSecret.trim();
    if (id.isEmpty ||
        secret.isEmpty ||
        id.length > 256 ||
        secret.length > 4096 ||
        _hasControl(id) ||
        _hasControl(secret)) {
      throw const TailscaleInvalidInput('OAuth client ID 或 secret 为空或格式不对');
    }
    final requestedAt = _now();
    final response = await _send(
      http.Request('POST', _origin.replace(path: '/api/v2/oauth/token'))
        ..headers['Accept'] = 'application/json'
        ..bodyFields = {
          'grant_type': 'client_credentials',
          'client_id': id,
          'client_secret': secret,
          'scope': tailscaleDeviceReadScope,
        },
    );
    // 官方文档没写换 token 失败的格式；假凭据实测是 401 {"message":"API token invalid"}。
    if (response.statusCode == 401) {
      throw const TailscaleReauthorizationRequired(
        'Tailscale 不接受这个 OAuth client（ID 或 secret 不对，或已在后台撤销）。本地已导入的设备和主机不受影响。',
      );
    }
    _throwForStatus(response, context: '换取 access token');

    final Object? json;
    try {
      json = jsonDecode(response.body);
    } on FormatException {
      throw const TailscaleMalformedResponse('token 响应不是 JSON');
    }
    if (json is! Map<String, Object?>) {
      throw const TailscaleMalformedResponse('token 响应不是对象');
    }
    final value = json['access_token'];
    if (value is! String ||
        value.isEmpty ||
        value.length > 4096 ||
        _hasControl(value)) {
      throw const TailscaleMalformedResponse('token 响应缺少 access_token');
    }
    final type = json['token_type'];
    if (type is String && type.toLowerCase() != 'bearer') {
      throw const TailscaleMalformedResponse('token 类型不是 Bearer');
    }
    final scopes = switch (json['scope']) {
      final String s => s.split(' ').where((e) => e.isNotEmpty).toSet(),
      _ => null,
    };
    final status = _assessScopes(scopes);
    // 以实际 expires_in 为准；缺了就按 5 分钟保守处理，不按官方的「通常 1 小时」去赌。
    final expiresIn = json['expires_in'];
    final lifetime = Duration(
      seconds: expiresIn is int && expiresIn > 0 ? expiresIn : 300,
    );
    return _AccessToken(
      value,
      requestedAt.add(lifetime - _refreshMargin(lifetime)),
      status,
    );
  }

  static TokenScopeStatus _assessScopes(Set<String>? scopes) {
    if (scopes == null || scopes.isEmpty) return TokenScopeStatus.unverified;
    final writable = scopes.where((s) => !s.endsWith(':read')).toSet();
    if (writable.isNotEmpty) {
      final granted = writable.join(', ');
      throw TailscaleScopeTooBroad(
        '换来的 token 不是只读（带有 $granted）。已丢弃，没有用它读取任何数据。请在 Tailscale 后台为本 App 单独创建只含 devices:core:read 的 OAuth client。',
        scopes,
      );
    }
    final deviceOnly = scopes.every(
      (s) => s == tailscaleDeviceReadScope || s == _legacyDeviceReadScope,
    );
    return deviceOnly
        ? TokenScopeStatus.deviceReadOnly
        : TokenScopeStatus.readOnlyBroader;
  }

  Future<http.Response> _send(http.Request request) async {
    // 不跟随重定向：跟了就会把 Authorization 头（或 token 请求体里的 client secret）
    // 带到服务器指定的任何地方。307/308 会原样重发 POST 请求体。
    request.followRedirects = false;
    try {
      final streamed = await _http.send(request);
      final bytes = <int>[];
      await for (final chunk in streamed.stream) {
        bytes.addAll(chunk);
        if (bytes.length > _maxResponseBytes) {
          throw const TailscaleMalformedResponse('响应超过 16 MiB，已放弃');
        }
      }
      return http.Response.bytes(
        bytes,
        streamed.statusCode,
        headers: streamed.headers,
        request: request,
      );
    } on TailscaleApiException {
      rethrow;
    } on TimeoutException {
      throw const TailscaleNetworkError(
          '连接 Tailscale API 超时。请检查当前网络（包括开着的 VPN）');
    } on SocketException {
      throw const TailscaleNetworkError('连不上 Tailscale API。请检查当前网络（包括开着的 VPN）');
    } on HandshakeException {
      throw const TailscaleNetworkError(
          '与 Tailscale API 的 TLS 握手失败，证书未通过校验，已断开');
    } on http.ClientException {
      throw const TailscaleNetworkError('连接 Tailscale API 时网络出错');
    }
  }

  void _throwForStatus(http.Response response, {required String context}) {
    final status = response.statusCode;
    if (status >= 200 && status < 300) return;
    if (status >= 300 && status < 400) {
      throw TailscaleRedirectRefused(
        '$context：服务器要求重定向（HTTP $status），为免把凭据带到别处，没有跟随',
      );
    }
    final detail = _serverMessage(response.body);
    switch (status) {
      case 403:
        throw TailscaleForbidden(
          '$context被拒绝（HTTP 403）：凭据没有读取设备的权限（需要 devices:core:read）$detail',
        );
      case 404:
        throw TailscaleTailnetNotFound(
            '$context：找不到这个 tailnet（HTTP 404）$detail');
      case 429:
        throw TailscaleRateLimited(
          '$context：请求太频繁（HTTP 429），请稍后手动重试$detail',
          _retryAfter(response.headers['retry-after']),
        );
    }
    throw TailscaleServerError('$context失败（HTTP $status）$detail', status);
  }

  /// 服务器错误体 `{"message": "..."}` 里的说明。截短、去控制字符，并抹掉任何凭据原文——
  /// 万一服务器把收到的东西回显出来，也不能进报错。
  String _serverMessage(String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map && json['message'] is String) {
        var text = (json['message'] as String)
            .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
            .trim();
        for (final secret in _secrets()) {
          if (secret.isNotEmpty) text = text.replaceAll(secret, '<redacted>');
        }
        if (text.length > 200) text = '${text.substring(0, 200)}…';
        return text.isEmpty ? '' : '：$text';
      }
    } on FormatException {
      // 不是 JSON 就不附带服务器原文。
    }
    return '';
  }

  Iterable<String> _secrets() sync* {
    final credential = _credential;
    switch (credential) {
      case PastedAccessToken(:final token):
        yield token.trim();
      case OAuthClientCredential(:final clientSecret):
        yield clientSecret.trim();
    }
    final token = _token?.value;
    if (token != null) yield token;
  }

  Duration? _retryAfter(String? header) {
    if (header == null) return null;
    final seconds = int.tryParse(header.trim());
    if (seconds != null) {
      return seconds < 0 ? null : Duration(seconds: seconds);
    }
    try {
      final at = HttpDate.parse(header);
      final wait = at.difference(_now());
      return wait.isNegative ? Duration.zero : wait;
    } on FormatException {
      return null;
    } on HttpException {
      return null;
    }
  }

  static bool _hasControl(String value) =>
      value.contains(RegExp(r'[\x00-\x20\x7f]'));
}
