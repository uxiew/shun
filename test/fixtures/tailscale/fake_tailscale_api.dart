import 'dart:convert';
import 'dart:io';

/// 一次请求在假 API 上留下的记录。Authorization 只记"有没有、对不对"，不记原文。
class RecordedApiRequest {
  RecordedApiRequest(this.origin, this.method, this.path, this.query,
      this.authorizationPresent, this.authorizationMatched, this.form);

  /// 'api'（假 api.tailscale.com）或 'other'（跨 origin 重定向的落点）。
  final String origin;
  final String method;
  final String path;
  final Map<String, String> query;
  final bool authorizationPresent;
  final bool authorizationMatched;

  /// application/x-www-form-urlencoded 请求体；client_secret 只记是否出现。
  final Map<String, String> form;
}

/// 进程内假 Tailscale API：OAuth client_credentials 换 token + 设备列表。
///
/// 字段只放目前能确认的最小集合（id/nodeId/name/hostname/addresses/os/lastSeen/tags），
/// **不是官方 schema**：R11 要对照锁定版本的官方文档复核，不许据此发明字段或分页参数。
///
/// [otherOrigin] 是第二个端口上的服务器：设备接口可配置为 302 跳过去，
/// 用来验证客户端跨 origin 时不转发 Authorization（TSC01）。
class FakeTailscaleApi {
  FakeTailscaleApi._(this._api, this._other);

  static const accessToken = 'tskey-fixture-access-token';
  static const clientId = 'fixture-client-id';
  static const clientSecret = 'fixture-client-secret';

  static Future<FakeTailscaleApi> start() async {
    final api = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeTailscaleApi._(api, other);
    api.listen((r) => fake._handle(r, 'api'));
    other.listen((r) => fake._handle(r, 'other'));
    return fake;
  }

  final HttpServer _api;
  final HttpServer _other;
  final requests = <RecordedApiRequest>[];

  List<Map<String, Object?>> devices = [
    {
      'id': 'device-1',
      'nodeId': 'node-1',
      'name': 'laptop.example-tailnet.ts.net',
      'hostname': 'laptop',
      'addresses': ['100.64.0.1', 'fd7a:115c:a1e0::1'],
      'os': 'linux',
      'lastSeen': '2026-09-29T00:00:00Z',
      'tags': <String>[],
    },
  ];

  /// 下一次设备请求返回 401 的次数（测"受控刷新一次后交给用户"）。
  int unauthorizedResponses = 0;

  /// 非空时设备请求返回 429 并带 Retry-After 秒数。
  int? retryAfterSeconds;

  /// 为真时设备请求 302 到 [otherOrigin]。
  bool redirectDevicesToOtherOrigin = false;

  Uri get baseUri => Uri.parse('http://127.0.0.1:${_api.port}');
  Uri get otherOrigin => Uri.parse('http://127.0.0.1:${_other.port}');

  Future<void> close() async {
    await _api.close(force: true);
    await _other.close(force: true);
  }

  Future<void> _handle(HttpRequest request, String origin) async {
    final auth = request.headers.value(HttpHeaders.authorizationHeader);
    final body = await utf8.decodeStream(request);
    final form = request.headers.contentType?.mimeType ==
            'application/x-www-form-urlencoded'
        ? Uri.splitQueryString(body)
        : <String, String>{};
    if (form.containsKey('client_secret')) {
      form['client_secret'] =
          form['client_secret'] == clientSecret ? '<matched>' : '<mismatched>';
    }
    requests.add(RecordedApiRequest(
      origin,
      request.method,
      request.uri.path,
      request.uri.queryParameters,
      auth != null,
      auth == 'Bearer $accessToken',
      form,
    ));
    final response = request.response;
    response.headers.contentType = ContentType.json;

    if (origin == 'other') {
      response.statusCode = 200;
      response.write(jsonEncode({'devices': devices}));
      return response.close();
    }
    if (request.method == 'POST' && request.uri.path == '/api/v2/oauth/token') {
      response.write(jsonEncode({
        'access_token': accessToken,
        'token_type': 'Bearer',
        'expires_in': 3600,
        'scope': form['scope'] ?? '',
      }));
      return response.close();
    }
    final devicesPath = RegExp(r'^/api/v2/tailnet/([^/]+)/devices$')
        .firstMatch(request.uri.path);
    if (request.method == 'GET' && devicesPath != null) {
      if (redirectDevicesToOtherOrigin) {
        response.statusCode = HttpStatus.found;
        response.headers.set(HttpHeaders.locationHeader,
            otherOrigin.replace(path: request.uri.path).toString());
        return response.close();
      }
      if (retryAfterSeconds != null) {
        response.statusCode = HttpStatus.tooManyRequests;
        response.headers
            .set(HttpHeaders.retryAfterHeader, '$retryAfterSeconds');
        return response.close();
      }
      if (unauthorizedResponses > 0 || auth != 'Bearer $accessToken') {
        if (unauthorizedResponses > 0) unauthorizedResponses--;
        response.statusCode = HttpStatus.unauthorized;
        return response.close();
      }
      response.write(jsonEncode({'devices': devices}));
      return response.close();
    }
    response.statusCode = HttpStatus.notFound;
    return response.close();
  }
}
