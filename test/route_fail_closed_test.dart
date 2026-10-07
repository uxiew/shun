import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';

import 'fixtures/net/socks5_fixture.dart';
import 'fixtures/net/trap_server.dart';
import 'package:netcatty_mobile/infrastructure/terminal/ghostty_terminal_adapter.dart';

// RTE02 / NET03：选了代理但配置坏了、或代理本身失败时，必须明确失败，
// 绝不能退回直连目标。目标由 TrapServer 扮演——它本身可以直连到达，
// 一旦有回退，accepted 就会变成非零。
void main() {
  late TrapServer target;
  late RecordingDialer dialer;
  setUp(() async {
    target = await TrapServer.start();
    dialer = RecordingDialer();
  });
  tearDown(() => target.close());

  HostProfile hostWith(Map<String, Object?> extra) => HostProfile({
        'id': 'target',
        'label': 'target',
        'hostname': target.host,
        'port': target.port,
        'username': 'nobody',
        'protocol': 'ssh',
        // 1 秒：卡住的代理必须在这个量级内失败，而不是无限等待。
        'sshTcpConnectTimeoutSeconds': 1,
        ...extra,
      });

  Future<Object?> connectError(
    HostProfile host, {
    List<HostProfile> hosts = const [],
    List<ProxyProfile> profiles = const [],
  }) async {
    try {
      final session = await SshService(dialer: dialer.call)
          .connect(
            terminal: GhosttyTerminalAdapter(),
            sessionId: 's',
            host: host,
            hosts: [...hosts, host],
            keys: const [],
            proxyProfiles: profiles,
            verifyHostKey: (_, __, ___) async => false,
          )
          .timeout(const Duration(seconds: 8));
      await session.close();
      return null;
    } on TimeoutException catch (error) {
      return error;
    } catch (error) {
      return error;
    }
  }

  group('RTE02 代理配置无效时不拨号、不直连', () {
    late TrapServer proxyEndpoint;
    setUp(() async => proxyEndpoint = await TrapServer.start());
    tearDown(() => proxyEndpoint.close());

    final cases = <String, Map<String, Object?> Function(TrapServer)>{
      '代理 host 为空': (_) => {
            'proxyConfig': {'type': 'socks5', 'host': '', 'port': 1080},
          },
      '代理 port 为 0': (p) => {
            'proxyConfig': {'type': 'socks5', 'host': p.host, 'port': 0},
          },
      '代理 port 超过 65535': (p) => {
            'proxyConfig': {'type': 'socks5', 'host': p.host, 'port': 70000},
          },
      '未知代理类型不能默认当成 HTTP': (p) => {
            'proxyConfig': {'type': 'socks4', 'host': p.host, 'port': p.port},
          },
      '代理 profile 不存在': (_) => {'proxyProfileId': 'missing'},
    };
    for (final entry in cases.entries) {
      test(entry.key, () async {
        final error = await connectError(hostWith(entry.value(proxyEndpoint)));
        expect(error, isNotNull);
        expect(error, isNot(isA<TimeoutException>()));
        expect(target.accepted, 0, reason: '不得直连目标');
        expect(proxyEndpoint.accepted, 0, reason: '配置无效时连代理都不该拨');
        expect(dialer.dials, isEmpty, reason: '配置无效必须在拨号前拒绝');
      });
    }

    test('代理 profile 存在但没有 config', () async {
      final error = await connectError(
        hostWith({'proxyProfileId': 'broken'}),
        profiles: [
          ProxyProfile({'id': 'broken', 'label': 'broken'}),
        ],
      );
      expect(error, isNotNull);
      expect(target.accepted, 0, reason: '不得直连目标');
      expect(dialer.dials, isEmpty);
    });

    test('目标同时配置代理和跳板：代理是入口，只拨代理，不直连第一跳（R07）', () async {
      final jump = await TrapServer.start();
      addTearDown(jump.close);
      final jumpHost = HostProfile({
        'id': 'jump',
        'label': 'jump',
        'hostname': jump.host,
        'port': jump.port,
        'username': 'nobody',
        'protocol': 'ssh',
      });
      final error = await connectError(
        hostWith({
          'hostChain': {
            'hostIds': ['jump'],
          },
          'proxyConfig': {
            'type': 'socks5',
            'host': proxyEndpoint.host,
            'port': proxyEndpoint.port,
          },
        }),
        hosts: [jumpHost],
      );
      // 这里的"代理"是陷阱服务器，握手必然失败；要看的是失败时有没有绕开代理。
      expect(error, isNotNull);
      expect(jump.accepted, 0, reason: '目标的代理被忽略、第一跳被直连');
      expect(target.accepted, 0);
      expect(dialer.dials, ['${proxyEndpoint.host}:${proxyEndpoint.port}'],
          reason: '入口只拨代理这一次');
    });

    test('Telnet 配了代理：不支持就拒绝，不能直连', () async {
      final error = await connectError(hostWith({
        'protocol': 'telnet',
        'proxyConfig': {
          'type': 'socks5',
          'host': proxyEndpoint.host,
          'port': proxyEndpoint.port,
        },
      }));
      expect(error, isNotNull);
      expect(target.accepted, 0, reason: 'Telnet 忽略代理直连了目标');
      expect(dialer.dials, isEmpty);
    });
  });

  group('NET03 代理失败时明确报错、不回退直连', () {
    Future<void> expectFailsClosed(Socks5Fixture proxy) async {
      addTearDown(proxy.close);
      final error = await connectError(hostWith({
        'proxyConfig': {
          'type': 'socks5',
          'host': proxy.host,
          'port': proxy.port,
        },
      }));
      expect(error, isNotNull);
      expect(error, isNot(isA<TimeoutException>()),
          reason: 'App 自己要在截止时间内失败，而不是靠外部超时打断');
      expect(target.accepted, 0, reason: '不得回退直连目标');
      expect(dialer.dials, ['${proxy.host}:${proxy.port}'],
          reason: '只允许拨代理端点一次');
    }

    test('代理拒绝全部认证方式', () async {
      await expectFailsClosed(
          await Socks5Fixture.start(fault: Socks5Fault.rejectAllMethods));
    });
    test('代理握手中途断开', () async {
      await expectFailsClosed(
          await Socks5Fixture.start(fault: Socks5Fault.closeAfterGreeting));
    });
    test('代理 CONNECT 返回错误码', () async {
      await expectFailsClosed(
          await Socks5Fixture.start(fault: Socks5Fault.connectError));
    });
    test('代理卡住不回应（超时）', () async {
      await expectFailsClosed(
          await Socks5Fixture.start(fault: Socks5Fault.stallAfterGreeting));
    });
    test('代理端口没有服务', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      final error = await connectError(hostWith({
        'proxyConfig': {'type': 'socks5', 'host': '127.0.0.1', 'port': port},
      }));
      expect(error, isNotNull);
      expect(target.accepted, 0);
      expect(dialer.dials, ['127.0.0.1:$port']);
    });
  });
}
