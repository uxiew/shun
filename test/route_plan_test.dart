import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/transport/proxy_transport.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';

import 'fixtures/net/socks5_fixture.dart';
import 'fixtures/net/trap_server.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';

// R05：路线在拨号前一次算好（RoutePlan）。这里测四件事——
// RTE01 矛盾配置不静默选一套；RTE03 路线算好后不受后续编辑影响；
// JMP03 跳板错误在拨号前拒绝、不去探测目标；NET04 地址校验与按类型编码。

HostProfile host(
  String id, {
  String? hostname,
  Object? port = 22,
  String protocol = 'ssh',
  Map<String, Object?> extra = const {},
}) =>
    HostProfile({
      'id': id,
      'label': id,
      'hostname': hostname ?? '$id.example',
      'port': port,
      'username': 'user-$id',
      'protocol': protocol,
      ...extra,
    });

Map<String, Object?> chain(List<Object?> ids) => {
      'hostChain': {'hostIds': ids},
    };

const socksProxy = {'type': 'socks5', 'host': 'proxy.example', 'port': 1080};

/// 断言拒绝，并顺带检查英文界面下这条报错读得懂（没有残留中文）。
/// [echoed] 是报错里原样带出的用户输入（比如用户填的中文域名），它本来就该保持原样，不算漏翻。
RouteConfigException rejects(void Function() body, {String? echoed}) {
  try {
    body();
  } on RouteConfigException catch (error) {
    ShunLocalizations.use('en');
    try {
      var english = ShunLocalizations.text(error.message);
      if (echoed != null) english = english.replaceAll(echoed, '');
      expect(english, isNot(matches(RegExp(r'[一-鿿]'))),
          reason: '英文界面下这条报错还有中文：$english');
    } finally {
      ShunLocalizations.use('zh-CN');
    }
    return error;
  }
  fail('应当拒绝，却算出了路线');
}

RoutePlan plan(
  HostProfile target, {
  List<HostProfile> jumps = const [],
  List<ProxyProfile> profiles = const [],
  List<SshKeyProfile> keys = const [],
}) =>
    resolveRoutePlan(
      target,
      hosts: [...jumps, target],
      proxyProfiles: profiles,
      keys: keys,
    );

void main() {
  group('RTE01 矛盾配置：给出唯一路线或拒绝，不静默选一套', () {
    test('只有目标自己的代理：入口是这个代理，没有跳板', () {
      final result = plan(host('t', extra: {'proxyConfig': socksProxy}));
      final entry = result.entry as ProxyEntry;
      expect(entry.type, ProxyType.socks5);
      expect(entry.endpoint.authority, 'proxy.example:1080');
      expect(result.jumps, isEmpty);
    });

    test('只有跳板：直连第一跳，跳板按配置顺序', () {
      final a = host('a');
      final b = host('b');
      final result = plan(host('t', extra: chain(['a', 'b'])), jumps: [b, a]);
      expect(result.entry, isA<DirectEntry>());
      expect(result.jumps.map((hop) => hop.host.id), ['a', 'b']);
      expect(result.target.host.id, 't');
    });

    test('代理配置引用 + 内联代理同时存在：拒绝，不设隐藏优先级', () {
      final profile =
          ProxyProfile({'id': 'p', 'label': 'p', 'config': socksProxy});
      final error = rejects(() => plan(
            host('t',
                extra: {'proxyProfileId': 'p', 'proxyConfig': socksProxy}),
            profiles: [profile],
          ));
      expect(error.message, contains('只保留一个'));
    });

    test('目标代理 + 跳板：代理是入口，只用于连第一跳（R07）', () {
      final result = plan(
        host('t', extra: {
          'proxyConfig': socksProxy,
          ...chain(['a'])
        }),
        jumps: [host('a')],
      );
      expect((result.entry as ProxyEntry).endpoint.authority,
          'proxy.example:1080');
      expect(result.jumps.map((hop) => hop.host.id), ['a']);
    });

    test('跳板机自带代理：拒绝，不隐式套用、也不忽略后直连跳板机', () {
      final error = rejects(() => plan(
            host('t', extra: chain(['a'])),
            jumps: [
              host('a', extra: {'proxyConfig': socksProxy})
            ],
          ));
      expect(error.message, contains('跳板机“a”'));
      rejects(() => plan(
            host('t', extra: chain(['a'])),
            jumps: [
              host('a', extra: {'proxyProfileId': 'p'})
            ],
          ));
    });

    test('跳板机自己又有跳板：拒绝，不递归展开', () {
      rejects(() => plan(
            host('t', extra: chain(['a'])),
            jumps: [
              host('a', extra: chain(['b'])),
              host('b')
            ],
          ));
    });

    test('导入数据三处矛盾（目标代理、跳板代理、旧 hostChain）：拒绝', () {
      rejects(() => plan(
            host('t', extra: {
              'proxyConfig': socksProxy,
              ...chain(['a'])
            }),
            jumps: [
              host('a', extra: {'proxyConfig': socksProxy})
            ],
          ));
    });

    test('hostChain 格式坏了：拒绝，不能当成没配跳板去直连目标', () {
      for (final bad in <Object?>[
        ['a'],
        'a',
        {'hostIds': 'a'},
        {
          'hostIds': [5]
        },
        {
          'hostIds': ['']
        },
        {
          'hostIds': [null]
        },
      ]) {
        rejects(() =>
            plan(host('t', extra: {'hostChain': bad}), jumps: [host('a')]));
      }
      // 空的 hostChain 没有表达任何跳板意图，按直连处理。
      expect(plan(host('t', extra: {'hostChain': {}})).jumps, isEmpty);
    });

    test('只读不写：未知字段原样留在快照里，保险库里的对象一个字节都不改', () {
      final target = host('t', extra: {
        'x-desktop-plugin': {
          'nested': [1, 2, 3],
        },
        'proxyConfig': socksProxy,
      });
      final before = jsonEncode(target.data);
      final result = plan(target);
      expect(jsonEncode(target.data), before);
      expect(result.target.host.data['x-desktop-plugin'], {
        'nested': [1, 2, 3]
      });
    });
  });

  group('RTE03 路线算好后，之后的编辑只影响下一次连接', () {
    test('改主机、代理、私钥、跳板顺序，已算好的路线都不变', () {
      final profile = ProxyProfile({
        'id': 'p',
        'label': 'p',
        'config': {...socksProxy},
      });
      final key = SshKeyProfile({'id': 'k', 'privateKey': 'original-key'});
      final target =
          host('t', extra: {'proxyProfileId': 'p', 'identityFileId': 'k'});
      final proxied = plan(target, profiles: [profile], keys: [key]);

      final a = host('a');
      final b = host('b');
      final jumped = host('j', extra: chain(['a', 'b']));
      final viaJumps = plan(jumped, jumps: [a, b]);

      target.data['hostname'] = 'evil.example';
      (profile.data['config'] as Map)['host'] = 'evil-proxy.example';
      key.data['privateKey'] = 'changed-key';
      ((jumped.data['hostChain'] as Map)['hostIds'] as List)
        ..clear()
        ..addAll(['b', 'a']);
      a.data['username'] = 'changed-user';

      expect(proxied.target.endpoint.host, 't.example');
      expect((proxied.entry as ProxyEntry).endpoint.host, 'proxy.example');
      expect(proxied.target.key!.privateKey, 'original-key');
      expect(viaJumps.jumps.map((hop) => hop.host.id), ['a', 'b']);
      expect(viaJumps.jumps.first.host.username, 'user-a');
    });

    test('路线本身不能被改', () {
      final result = plan(host('t', extra: chain(['a'])), jumps: [host('a')]);
      expect(() => result.jumps.add(result.target), throwsUnsupportedError);
      expect(() => result.hops.clear(), throwsUnsupportedError);
    });

    test('代理握手进行中改了目标地址：CONNECT 的仍是开始时的地址', () async {
      final proxy = await Socks5Fixture.start(
        fragmentDelay: const Duration(milliseconds: 20),
      );
      addTearDown(proxy.close);
      final target = host('t', hostname: 'before.example', extra: {
        'proxyConfig': {
          'type': 'socks5',
          'host': proxy.host,
          'port': proxy.port
        },
        'sshTcpConnectTimeoutSeconds': 3,
      });
      final connecting = SshService().connect(
        terminal: GhosttyTerminalAdapter(),
        sessionId: 's',
        host: target,
        hosts: [target],
        keys: const [],
        proxyProfiles: const [],
        verifyHostKey: (_, __, ___) async => false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      target.data['hostname'] = 'after.example';
      await expectLater(
          connecting,
          throwsA(isA<RouteHopException>().having(
              (e) => e.cause, 'cause', isA<ProxyHandshakeException>())));
      expect(proxy.attempts.single.requestedHost, 'before.example');
    });
  });

  group('JMP03 跳板错误在拨号前拒绝，不去探测最终目标', () {
    late TrapServer target;
    late RecordingDialer dialer;
    setUp(() async {
      target = await TrapServer.start();
      dialer = RecordingDialer();
    });
    tearDown(() => target.close());

    Future<void> expectRejectedBeforeDial(
      Map<String, Object?> targetExtra,
      List<HostProfile> jumps, {
      String protocol = 'ssh',
    }) async {
      final t = host('t',
          hostname: target.host,
          port: target.port,
          protocol: protocol,
          extra: targetExtra);
      Object? error;
      try {
        final session = await SshService(dialer: dialer.call).connect(
          terminal: GhosttyTerminalAdapter(),
          sessionId: 's',
          host: t,
          hosts: [...jumps, t],
          keys: const [],
          proxyProfiles: const [],
          verifyHostKey: (_, __, ___) async => false,
        );
        await session.close();
      } catch (e) {
        error = e;
      }
      expect(error, isA<RouteConfigException>());
      expect(dialer.dials, isEmpty, reason: '拒绝必须发生在任何拨号之前');
      expect(target.accepted, 0, reason: '不得直连探测最终目标');
    }

    test('跳板机不存在', () => expectRejectedBeforeDial(chain(['missing']), []));
    test(
        '跳板机不是 SSH',
        () => expectRejectedBeforeDial(
            chain(['a']), [host('a', protocol: 'telnet')]));
    test('目标出现在自己的跳板列表里（循环）', () => expectRejectedBeforeDial(chain(['t']), []));
    test('同一个跳板机出现两次（循环）',
        () => expectRejectedBeforeDial(chain(['a', 'a']), [host('a')]));
    test(
        '超过 $maxJumpHosts 跳',
        () => expectRejectedBeforeDial(chain(['a', 'b', 'c', 'd']),
            [host('a'), host('b'), host('c'), host('d')]));
    test(
        '跳板机和目标是同一台机器',
        () => expectRejectedBeforeDial(chain(['a']),
            [host('a', hostname: '127.0.0.1', port: target.port)]));
    test(
        '跳板机地址非法',
        () => expectRejectedBeforeDial(
            chain(['a']), [host('a', hostname: 'bad host')]));
    test(
        'Telnet 配了跳板机',
        () => expectRejectedBeforeDial(chain(['a']), [host('a')],
            protocol: 'telnet'));
  });

  group('NET04 地址校验：合法的原样保留，非法的拨号前拒绝', () {
    Endpoint parse(String value, [Object? port = 22]) =>
        Endpoint.parse(value, port, what: '目标“t”');

    test('合法地址', () {
      expect(parse('192.0.2.1').kind, EndpointKind.ipv4);
      expect(parse('2001:db8::1').kind, EndpointKind.ipv6);
      final bracketed = parse('[2001:db8::1]');
      expect(bracketed.host, '2001:db8::1');
      expect(bracketed.authority, '[2001:db8::1]:22');
      expect(parse('example.com').kind, EndpointKind.domain);
      expect(parse('my_host.internal.').kind, EndpointKind.domain);
      expect(parse('xn--fiqs8s.example').kind, EndpointKind.domain);
      expect(parse('${'a' * 63}.example').kind, EndpointKind.domain);
      final longest = List.filled(4, 'a' * 62).join('.'); // 4×62 + 3 = 251
      expect(parse(longest).host, longest);
      expect(parse('example.com', 65535).port, 65535);
    });

    test('非法地址', () {
      for (final bad in [
        '',
        'a b',
        'a\u0000b',
        'a\tb',
        'host\n',
        '中文.example',
        '${'a' * 64}.example',
        List.filled(5, 'a' * 62).join('.'),
        '-bad.example',
        'bad-.example',
        'a..b',
        '999.1.1.1',
        '1.2.3',
        'fe80::1%eth0',
        '[192.0.2.1]',
        '[2001:db8::1',
        '2001:db8::zz',
        'user@example.com',
        'example.com/path',
      ]) {
        rejects(() => parse(bad), echoed: bad);
      }
    });

    test('非法端口', () {
      for (final bad in <Object?>[0, 65536, -1, 22.5, '22', null, double.nan]) {
        rejects(() => parse('example.com', bad));
      }
    });

    test('主机数据里没写端口时按 22；写成字符串拒绝，不替它猜', () {
      expect(plan(host('t', port: null)).target.endpoint.port, 22);
      rejects(() => plan(host('t', port: '22')));
    });
  });

  group('NET04 地址按类型编码', () {
    late RecordingDialer dialer;
    setUp(() => dialer = RecordingDialer());

    Future<void> connectVia(
        Map<String, Object?> proxyConfig, String hostname) async {
      final t = host('t', hostname: hostname, extra: {
        'proxyConfig': proxyConfig,
        'sshTcpConnectTimeoutSeconds': 3,
      });
      try {
        final session = await SshService(dialer: dialer.call).connect(
          terminal: GhosttyTerminalAdapter(),
          sessionId: 's',
          host: t,
          hosts: [t],
          keys: const [],
          proxyProfiles: const [],
          verifyHostKey: (_, __, ___) async => false,
        );
        await session.close();
      } catch (_) {
        // 代理回"主机不可达"或 403，连接本来就该失败；这里只看代理收到了什么。
      }
    }

    test('SOCKS5：IPv4 用 ATYP 1，IPv6 用 ATYP 4，域名用 ATYP 3 交给代理解析', () async {
      final proxy = await Socks5Fixture.start();
      addTearDown(proxy.close);
      final config = {'type': 'socks5', 'host': proxy.host, 'port': proxy.port};
      await connectVia(config, '192.0.2.10');
      await connectVia(config, '[2001:db8::10]');
      await connectVia(config, 'target.fixture.internal');
      expect(proxy.attempts.map((a) => a.addressType), [1, 4, 3]);
      expect(proxy.attempts.map((a) => a.requestedHost), [
        '192.0.2.10',
        InternetAddress('2001:db8::10').address,
        'target.fixture.internal',
      ]);
      expect(dialer.dials.toSet(), {'${proxy.host}:${proxy.port}'},
          reason: '只拨代理，不在本机解析或直连目标');
    });

    test('直连 IPv6：写成 [::1] 也按去掉方括号的地址拨号，并真的连上', () async {
      final ServerSocket server;
      try {
        server = await ServerSocket.bind(InternetAddress.loopbackIPv6, 0);
      } on SocketException {
        markTestSkipped('本机没有 IPv6 回环地址');
        return;
      }
      addTearDown(server.close);
      var accepted = 0;
      server.listen((socket) {
        accepted++;
        socket.destroy();
      });
      final t = host('t', hostname: '[::1]', port: server.port, extra: {
        'sshTcpConnectTimeoutSeconds': 3,
      });
      try {
        final session = await SshService(dialer: dialer.call).connect(
          terminal: GhosttyTerminalAdapter(),
          sessionId: 's',
          host: t,
          hosts: [t],
          keys: const [],
          proxyProfiles: const [],
          verifyHostKey: (_, __, ___) async => false,
        );
        await session.close();
      } catch (_) {
        // 对端不是 SSH，连上后握手失败是预期的；这里只验证拨号地址和确实连到了。
      }
      expect(dialer.dials, ['::1:${server.port}']);
      expect(accepted, 1);
    });

    test('HTTP CONNECT：IPv6 目标加方括号', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final firstLines = <String>[];
      server.listen((socket) {
        socket.listen((data) {
          firstLines.add(utf8.decode(data).split('\r\n').first);
          socket.add(utf8.encode('HTTP/1.1 403 Forbidden\r\n\r\n'));
          socket.destroy();
        });
      });
      final config = {'type': 'http', 'host': '127.0.0.1', 'port': server.port};
      await connectVia(config, '2001:db8::10');
      await connectVia(config, 'example.com');
      expect(firstLines, [
        'CONNECT [2001:db8::10]:22 HTTP/1.1',
        'CONNECT example.com:22 HTTP/1.1',
      ]);
    });
  });
}
