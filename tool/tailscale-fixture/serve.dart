// 本机的假 Tailscale API，给模拟器/真机上的 R11 验证用（用法见同目录 README.md）。
//
// 只实现 App 会用到的两个端点，响应形状照官方 OpenAPI。每个收到的请求打一行 JSON 到 stdout：
// method、path、query、表单参数名、Authorization 是否等于本服务发出的 token——不打印任何凭据原文。
//
// 18480：假 API。tailnet 写成 redirect-me 时回 302，指向 18481。
// 18481：「别处」。收到任何请求都记一行 STOLEN——正常情况下这一行永远不该出现。
import 'dart:convert';
import 'dart:io';
import 'dart:math';

Future<void> main() async {
  final random = Random.secure();
  String nonce() =>
      List.generate(8, (_) => random.nextInt(16).toRadixString(16)).join();
  final issued = <String>{};

  final api = await HttpServer.bind(InternetAddress.loopbackIPv4, 18480);
  final elsewhere = await HttpServer.bind(InternetAddress.loopbackIPv4, 18481);
  stdout.writeln('{"ready":true,"api":18480,"elsewhere":18481}');

  elsewhere.listen((request) async {
    stdout.writeln(jsonEncode({
      'server': 'elsewhere',
      'STOLEN': true,
      'method': request.method,
      'path': request.uri.path,
      'hasAuthorization': request.headers.value('authorization') != null,
    }));
    request.response.statusCode = 404;
    await request.response.close();
  });

  await for (final request in api) {
    final body = await utf8.decodeStream(request);
    final auth = request.headers.value('authorization');
    final bearer =
        auth != null && auth.startsWith('Bearer ') ? auth.substring(7) : null;
    final form = request.headers.contentType?.mimeType ==
            'application/x-www-form-urlencoded'
        ? Uri.splitQueryString(body)
        : const <String, String>{};
    final path = request.uri.path;
    final log = <String, Object?>{
      'server': 'api',
      'method': request.method,
      'path': path,
      'query': request.uri.query,
      'formKeys': form.keys.toList()..sort(),
      'scope': form['scope'],
      'grantType': form['grant_type'],
      'authorization': auth == null
          ? 'none'
          : issued.contains(bearer)
              ? 'bearer-issued-by-fixture'
              : 'bearer-other',
    };
    final response = request.response;
    if (request.method == 'POST' && path == '/api/v2/oauth/token') {
      // token 在这里现生成，App 的代码里不含它；之后在设备存储里搜它，出现即说明 token 被落盘。
      final token = 'R11-OAUTH-ACCESS-TOKEN-${nonce()}';
      issued.add(token);
      log['issuedTokenSuffix'] = token.substring(token.length - 8);
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({
        'access_token': token,
        'token_type': 'Bearer',
        'expires_in': 3600,
        'scope': 'devices:core:read',
      }));
    } else if (request.method == 'GET' &&
        path == '/api/v2/tailnet/redirect-me/devices') {
      response.statusCode = 302;
      response.headers.set('location', 'http://127.0.0.1:18481/steal');
    } else if (request.method == 'GET' &&
        RegExp(r'^/api/v2/tailnet/[^/]+/devices$').hasMatch(path)) {
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({
        'devices': [
          {
            'id': '1001',
            'nodeId': 'nFixture1CNTRL',
            'name': 'fixture-nas.tail0000.ts.net',
            'hostname': 'fixture-nas',
            'addresses': ['100.64.0.10'],
            'os': 'linux',
            'authorized': true,
            'connectedToControl': true,
            'machineKey': 'mkey:R11MACHINEKEYFIXTURE',
            'tags': ['tag:fixture'],
          },
        ],
      }));
    } else {
      response.statusCode = 404;
      response.write('{"message":"not found"}');
    }
    log['status'] = response.statusCode;
    stdout.writeln(jsonEncode(log));
    await response.close();
  }
}
