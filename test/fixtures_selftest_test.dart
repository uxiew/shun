import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'fixtures/net/socks5_fixture.dart';
import 'fixtures/net/trap_server.dart';
import 'fixtures/tailscale/fake_tailscale_api.dart';
import 'fixtures/vt/vt_samples.dart';

// R02：先证明测试夹具本身按设计工作。App 测试失败时，这组通过就能排除夹具问题。
void main() {
  Future<List<int>> rawSocksConnect(
    Socks5Fixture proxy,
    String target, {
    List<int> methods = const [0],
  }) async {
    final socket = await Socket.connect(proxy.host, proxy.port);
    final received = <int>[];
    final done = Completer<void>();
    socket.listen(received.addAll, onDone: done.complete);
    socket.add([5, methods.length, ...methods]);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final name = utf8.encode(target);
    socket.add([5, 1, 0, 3, name.length, ...name, 0, 22]);
    await done.future.timeout(const Duration(seconds: 3), onTimeout: () {});
    socket.destroy();
    return received;
  }

  test('SOCKS fixture 只按名字表解析，并把 banner 原样转发', () async {
    final trap = await TrapServer.start();
    final proxy = await Socks5Fixture.start(names: {
      'target.fixture.invalid': (host: trap.host, port: trap.port),
    });
    addTearDown(proxy.close);
    addTearDown(trap.close);

    final ok = await rawSocksConnect(proxy, 'target.fixture.invalid');
    expect(ok.sublist(0, 2), [5, 0]);
    expect(ok.sublist(2, 4), [5, 0]);
    expect(utf8.decode(ok.sublist(12)), startsWith('SSH-2.0-DirectTrap'));
    expect(trap.accepted, 1);

    final unknown = await rawSocksConnect(proxy, 'unknown.fixture.invalid');
    expect(unknown.sublist(2, 4), [5, 4], reason: '不在名字表里必须回主机不可达');
    expect(trap.accepted, 1);
    expect(proxy.attempts.map((a) => a.requestedHost),
        ['target.fixture.invalid', 'unknown.fixture.invalid']);
  });

  test('SOCKS fixture 分片模式把握手逐字节发出', () async {
    final proxy = await Socks5Fixture.start(
      fault: Socks5Fault.rejectAllMethods,
      fragmentDelay: const Duration(milliseconds: 20),
    );
    addTearDown(proxy.close);
    final socket = await Socket.connect(proxy.host, proxy.port);
    final packets = <Uint8List>[];
    final done = Completer<void>();
    socket.listen(packets.add, onDone: done.complete);
    socket.add([5, 1, 0]);
    await done.future.timeout(const Duration(seconds: 3));
    expect(packets.map((p) => p.length), [1, 1]);
    expect(packets.expand((p) => p), [5, 0xff]);
  });

  test('假 Tailscale API 记录 token 交换、设备请求和跨 origin 落点', () async {
    final api = await FakeTailscaleApi.start();
    addTearDown(api.close);
    final token = await http.post(
      api.baseUri.replace(path: '/api/v2/oauth/token'),
      body: {
        'client_id': FakeTailscaleApi.clientId,
        'client_secret': FakeTailscaleApi.clientSecret,
        'grant_type': 'client_credentials',
        'scope': 'devices:core:read',
      },
    );
    expect(
        jsonDecode(token.body)['access_token'], FakeTailscaleApi.accessToken);

    final devicesUri = api.baseUri.replace(path: '/api/v2/tailnet/-/devices');
    final devices = await http.get(devicesUri,
        headers: {'authorization': 'Bearer ${FakeTailscaleApi.accessToken}'});
    expect(
        (jsonDecode(devices.body)['devices'] as List).single['id'], 'device-1');

    final noAuth = await http.get(devicesUri);
    expect(noAuth.statusCode, 401);

    api.redirectDevicesToOtherOrigin = true;
    final client = HttpClient();
    addTearDown(client.close);
    final request = await client.getUrl(devicesUri);
    request.headers
        .set('authorization', 'Bearer ${FakeTailscaleApi.accessToken}');
    await (await request.close()).drain<void>();

    expect(api.requests.first.form['client_secret'], '<matched>');
    expect(api.requests.first.form['scope'], 'devices:core:read');
    expect(api.requests.last.origin, 'other');
    // 这里只证明夹具能记录跨 origin 时 Authorization 是否到达；
    // 客户端该不该带、带了算不算违规，是 R11–R13 的 TSC01 用例要判的。
    expect(api.requests.last.authorizationPresent, isA<bool>());
  });

  test('VT 切包工具拼回去与原文逐字节一致', () {
    for (final seed in [1, 2, 3, 42]) {
      final chunks = randomChunks(VtSamples.all, seed);
      expect(chunks.length, greaterThan(10));
      expect(chunks.expand((c) => c).toList(), VtSamples.all);
    }
    expect(byteChunks(VtSamples.all).length, VtSamples.all.length);
  });
}
