import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/transport/proxy_transport.dart';
import 'package:shun/presentation/widgets/host_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures/net/scripted_proxy.dart';
import 'fixtures/net/socks5_fixture.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';

// R06：SOCKS5 CONNECT 生产加固。
// 传输层直接对"剧本代理"做握手（NET05/06/08、SOX02/03）；
// 连接层测三个阶段各自的期限与取消（NET07、SOX03）；再加 SOX04 的界面提示与明文证据。

final target = Endpoint.parse('target.example', 22, what: '目标“t”');
const okReply = [5, 0, 0, 1, 127, 0, 0, 1, 0, 22];
const secret = 'proxy-secret-123';

ProxyEntry socks(ScriptedProxy proxy, {String? user, String? pass}) =>
    ProxyEntry(
      type: ProxyType.socks5,
      endpoint: Endpoint.parse(proxy.host, proxy.port, what: '代理'),
      username: user,
      password: pass,
    );

Future<ProxyHandshakeException> handshakeFails(
  ScriptedProxy proxy,
  ProxyEntry entry, {
  Duration deadline = const Duration(seconds: 2),
}) async {
  final socket = await Socket.connect(proxy.host, proxy.port);
  try {
    await proxyHandshake(socket, entry, target, deadline: deadline);
  } on ProxyHandshakeException catch (error) {
    expect(error.message, isNot(contains(secret)), reason: '代理口令不能进报错');
    return error;
  }
  fail('握手应当失败');
}

Future<List<int>> residualAfterHandshake(
  ScriptedProxy proxy,
  ProxyEntry entry,
) async {
  final socket = await Socket.connect(proxy.host, proxy.port);
  final ssh = await proxyHandshake(socket, entry, target,
      deadline: const Duration(seconds: 2));
  final bytes = <int>[];
  await for (final chunk in ssh.stream.timeout(const Duration(seconds: 2))) {
    bytes.addAll(chunk);
  }
  return bytes;
}

void main() {
  late ScriptedProxy proxy;
  final started = <ScriptedProxy>[];
  Future<ScriptedProxy> startProxy(
      Future<void> Function(ScriptedConn conn) script) async {
    final value = await ScriptedProxy.start(script);
    started.add(value);
    return value;
  }

  tearDown(() async {
    for (final value in started) {
      await value.close();
    }
    started.clear();
  });

  group('NET05 认证按配置协商，不降级', () {
    test('配了口令：只提供用户名密码一种方法；代理选「无认证」就拒绝', () async {
      List<int>? offered;
      proxy = await startProxy((conn) async {
        offered = await conn.readGreeting();
        await conn.send([5, 0]);
        await conn.stall();
      });
      final error =
          await handshakeFails(proxy, socks(proxy, user: 'u', pass: secret));
      expect(offered, [2]);
      expect(error.message, contains('防止降级'));
    });

    test('没配口令：只提供无认证；代理要口令就明确报错', () async {
      List<int>? offered;
      proxy = await startProxy((conn) async {
        offered = await conn.readGreeting();
        await conn.send([5, 2]);
        await conn.stall();
      });
      final error = await handshakeFails(proxy, socks(proxy));
      expect(offered, [0]);
      expect(error.message, contains('要求用户名和密码'));
    });

    test('代理选了没提供的方法（GSSAPI）或拒绝全部方法', () async {
      for (final method in [1, 0xff]) {
        proxy = await startProxy((conn) async {
          await conn.readGreeting();
          await conn.send([5, method]);
          await conn.stall();
        });
        await handshakeFails(proxy, socks(proxy, user: 'u', pass: secret));
      }
    });

    test('口令错误：说清是认证失败，报错里没有口令', () async {
      (String, String)? seen;
      proxy = await startProxy((conn) async {
        await conn.readGreeting();
        await conn.send([5, 2]);
        seen = await conn.readAuth();
        await conn.send([1, 1]);
        await conn.stall();
      });
      final error =
          await handshakeFails(proxy, socks(proxy, user: 'u', pass: secret));
      expect(seen, ('u', secret));
      expect(error.message, contains('用户名或密码不对'));
    });

    test('认证回复的版本字节不对', () async {
      proxy = await startProxy((conn) async {
        await conn.readGreeting();
        await conn.send([5, 2]);
        await conn.readAuth();
        await conn.send([5, 0]);
        await conn.stall();
      });
      await handshakeFails(proxy, socks(proxy, user: 'u', pass: secret));
    });

    test('ProxyEntry 打印出来不含口令', () {
      final entry = ProxyEntry(
        type: ProxyType.socks5,
        endpoint: Endpoint.parse('p.example', 1080, what: '代理'),
        username: 'u',
        password: secret,
      );
      expect('$entry', isNot(contains(secret)));
      expect('$entry', isNot(contains('u@')));
    });
  });

  group('NET06 坏回复都有界失败', () {
    Future<void> badReply(List<int> reply, {bool closeAfter = false}) async {
      proxy = await startProxy((conn) async {
        await conn.readGreeting();
        await conn.send([5, 0]);
        await conn.readConnect();
        await conn.send(reply);
        if (closeAfter) {
          conn.socket.destroy();
        } else {
          await conn.stall();
        }
      });
      final watch = Stopwatch()..start();
      await handshakeFails(proxy, socks(proxy),
          deadline: const Duration(milliseconds: 500));
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      await proxy.connections.single.clientGone
          .timeout(const Duration(seconds: 1));
    }

    test('问候回复版本字节不是 5', () async {
      proxy = await startProxy((conn) async {
        await conn.readGreeting();
        await conn.send([4, 0]);
        await conn.stall();
      });
      final error = await handshakeFails(proxy, socks(proxy));
      expect(error.message, contains('不是 SOCKS5'));
    });

    test('连接回复 VER 错', () => badReply([4, 0, 0, 1, 0, 0, 0, 0, 0, 22]));
    test('连接回复 RSV 非零', () => badReply([5, 0, 7, 1, 0, 0, 0, 0, 0, 22]));
    test('连接回复 ATYP 未知', () => badReply([5, 0, 0, 9, 0, 0, 0, 0, 0, 22]));
    test('连接回复只发一半就断', () => badReply([5, 0, 0], closeAfter: true));
    test('域名长度写 200 实际只给 5 字节就断（长度伪造）',
        () => badReply([5, 0, 0, 3, 200, 1, 2, 3, 4, 5], closeAfter: true));
    test('域名长度写 255 后卡住（长度伪造）', () => badReply([5, 0, 0, 3, 255, 1, 2]));

    test('问候回复只给一个字节就断', () async {
      proxy = await startProxy((conn) async {
        await conn.readGreeting();
        await conn.send([5]);
        conn.socket.destroy();
      });
      final error = await handshakeFails(proxy, socks(proxy));
      expect(error.message, contains('握手完成前'));
    });

    test('全程逐字节发送的正常回复：握手成功，SSH 数据一个不少', () async {
      const banner = 'SSH-2.0-Slow\r\n';
      proxy = await startProxy((conn) async {
        await conn.readGreeting();
        await conn.send([5, 0], chunks: [1, 1]);
        await conn.readConnect();
        final rest = [...okReply, ...ascii.encode(banner)];
        await conn.send(rest, chunks: List.filled(rest.length, 1));
        conn.socket.destroy();
      });
      expect(ascii.decode(await residualAfterHandshake(proxy, socks(proxy))),
          banner);
    });
  });

  group('NET08 失败码逐个说清原因', () {
    for (final code in [1, 2, 3, 4, 5, 6, 7, 8, 42]) {
      test('状态码 $code', () async {
        proxy = await startProxy((conn) async {
          await conn.readGreeting();
          await conn.send([5, 0]);
          await conn.readConnect();
          await conn.send([5, code, 0, 1, 0, 0, 0, 0, 0, 0]);
          await conn.stall();
        });
        final error = await handshakeFails(proxy, socks(proxy));
        expect(error.message, socks5ReplyMessage(code));
        expect(error.message, contains('$code'));
      });
    }

    test('主机不可达不被说成 DNS 失败', () {
      final text = socks5ReplyMessage(4);
      expect(text, contains('主机不可达'));
      expect(text, contains('不一定是域名解析问题'));
    });
  });

  group('SOX02 代理回复和 SSH 版本行粘在一起', () {
    const banner = 'SSH-2.0-Glued\r\nKEXINIT-FOLLOWS';

    test('同一个包里：余下的字节原样交给 SSH，只交一次', () async {
      proxy = await startProxy((conn) async {
        await conn.readGreeting();
        await conn.send([5, 0]);
        await conn.readConnect();
        await conn.send([...okReply, ...ascii.encode(banner)]);
        conn.socket.destroy();
      });
      expect(ascii.decode(await residualAfterHandshake(proxy, socks(proxy))),
          banner);
    });

    test('随机切分 20 次：每次都完整、不重复', () async {
      for (var seed = 0; seed < 20; seed++) {
        final random = Random(seed);
        List<int> randomChunks(int length) {
          final sizes = <int>[];
          var left = length;
          while (left > 0) {
            final size = min(left, 1 + random.nextInt(6));
            sizes.add(size);
            left -= size;
          }
          return sizes;
        }

        proxy = await startProxy((conn) async {
          await conn.readGreeting();
          await conn.send([5, 0], chunks: randomChunks(2));
          await conn.readConnect();
          final rest = [...okReply, ...ascii.encode(banner)];
          await conn.send(rest, chunks: randomChunks(rest.length));
          conn.socket.destroy();
        });
        expect(
          ascii.decode(await residualAfterHandshake(proxy, socks(proxy))),
          banner,
          reason: 'seed $seed',
        );
        await proxy.close();
      }
    });
  });

  group('SOX03 慢速半包：总期限有效，socket 立刻关', () {
    Future<void> stallsAt(Future<void> Function(ScriptedConn conn) script,
        {String? user}) async {
      proxy = await startProxy(script);
      final watch = Stopwatch()..start();
      final error = await handshakeFails(
        proxy,
        socks(proxy, user: user, pass: user == null ? null : secret),
        deadline: const Duration(milliseconds: 300),
      );
      expect(error.message, contains('超时'));
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 1500)));
      await proxy.connections.single.clientGone
          .timeout(const Duration(milliseconds: 500));
    }

    test(
        '问候后一直不回',
        () => stallsAt((conn) async {
              await conn.readGreeting();
              await conn.stall();
            }));
    test(
        '认证回复只给一个字节',
        () => stallsAt((conn) async {
              await conn.readGreeting();
              await conn.send([5, 2]);
              await conn.readAuth();
              await conn.send([1]);
              await conn.stall();
            }, user: 'u'));
    test(
        '连接回复只给两个字节',
        () => stallsAt((conn) async {
              await conn.readGreeting();
              await conn.send([5, 0]);
              await conn.readConnect();
              await conn.send([5, 0]);
              await conn.stall();
            }));
    test(
        '每 100 毫秒一个字节地挤（每字节不重置计时）',
        () => stallsAt((conn) async {
              await conn.readGreeting();
              await conn.send([5, 0]);
              await conn.readConnect();
              await conn.send(okReply,
                  chunks: List.filled(okReply.length, 1),
                  gap: const Duration(milliseconds: 100));
              await conn.stall();
            }));
  });

  group('NET07 / SOX03 各阶段的期限与取消（连接层）', () {
    HostProfile hostAt(String hostname, int port, {Object? proxyConfig}) =>
        HostProfile({
          'id': 't',
          'label': 't',
          'hostname': hostname,
          'port': port,
          'username': 'u',
          'protocol': 'ssh',
          'sshTcpConnectTimeoutSeconds': 1,
          if (proxyConfig != null) 'proxyConfig': proxyConfig,
        });

    Future<ActiveTerminalSession> connect(SshService service, HostProfile host,
            {String id = 's'}) =>
        service.connect(
          terminal: GhosttyTerminalAdapter(),
          sessionId: id,
          host: host,
          hosts: [host],
          keys: const [],
          proxyProfiles: const [],
          verifyHostKey: (_, __, ___) async => true,
        );

    /// 先挂上监听再取消：cancel() 关 socket 时整条错误链可能同步跑完，
    /// 取消之后才 await 的话，Dart 会把这个错误先报成"未处理"。App 里控制器一直在 await，不受影响。
    Future<Object> cancelledWithin(SshService service, String id,
        Future<Object?> connecting, Duration limit) async {
      final outcome = connecting.then<Object?>((_) => null,
          onError: (Object error) => error);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final watch = Stopwatch()..start();
      service.cancelConnection(id);
      final error = await outcome;
      expect(watch.elapsed, lessThan(limit));
      expect(error, isA<ConnectionCancelledException>());
      return error!;
    }

    Future<Object> failsWithin(Future<Object?> future, Duration limit) async {
      final watch = Stopwatch()..start();
      try {
        await future;
      } catch (error) {
        expect(watch.elapsed, lessThan(limit));
        return error;
      }
      fail('应当失败');
    }

    test('TCP 拨号卡住：期限到就报超时；迟到的 socket 被立刻关掉', () async {
      final lateSocket = Completer<Socket>();
      final service =
          SshService(dialer: (_, __, {timeout}) => lateSocket.future);
      final error = await failsWithin(connect(service, hostAt('192.0.2.1', 22)),
          const Duration(seconds: 3));
      expect(error, isA<RouteHopException>());
      expect((error as RouteHopException).cause, isA<ConnectStageException>());
      expect('$error', contains('TCP 连接超时'));

      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final closed = Completer<void>();
      server.listen((socket) => socket.listen(null, onDone: closed.complete));
      lateSocket.complete(await Socket.connect(server.address, server.port));
      await closed.future.timeout(const Duration(seconds: 1));
    });

    test('TCP 拨号卡住时取消：马上结束', () async {
      final service =
          SshService(dialer: (_, __, {timeout}) => Completer<Socket>().future);
      await cancelledWithin(
          service,
          'c',
          connect(service, hostAt('192.0.2.1', 22), id: 'c'),
          const Duration(milliseconds: 500));
    });

    test('代理握手卡住时取消：马上结束，握手中的 socket 也马上关（不等 10 秒期限）', () async {
      proxy = await startProxy((conn) async {
        await conn.readGreeting();
        await conn.stall();
      });
      final host = HostProfile({
        ...hostAt('target.example', 22).data,
        'sshTcpConnectTimeoutSeconds': 10,
        'proxyConfig': {
          'type': 'socks5',
          'host': proxy.host,
          'port': proxy.port
        },
      });
      final service = SshService();
      await cancelledWithin(service, 'p', connect(service, host, id: 'p'),
          const Duration(milliseconds: 500));
      await proxy.connections.single.clientGone
          .timeout(const Duration(milliseconds: 500));
    });

    Future<ServerSocket> sshLikeServer(
        void Function(Socket socket) onAccept) async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen(onAccept);
      return server;
    }

    test('SSH 端口接了连接却一个字节不回：期限到就报原因，连接被关', () async {
      final closed = Completer<void>();
      final server = await sshLikeServer(
          (socket) => socket.listen(null, onDone: closed.complete));
      final error = await failsWithin(
          connect(SshService(), hostAt('127.0.0.1', server.port)),
          const Duration(seconds: 3));
      expect(error, isA<RouteHopException>());
      expect('$error', contains('没有收到 SSH 版本信息'));
      await closed.future.timeout(const Duration(seconds: 1));
    });

    test('代理多发了一份二进制回复：SSH 层马上识别出不是版本行，有界失败', () async {
      final server = await sshLikeServer((socket) {
        socket.add(okReply);
        socket.listen(null);
      });
      await failsWithin(connect(SshService(), hostAt('127.0.0.1', server.port)),
          const Duration(seconds: 3));
    });

    test('一直发可打印字符却不换行：按版本行期限失败，不无限等', () async {
      final server = await sshLikeServer((socket) {
        socket.add(ascii.encode('HTTP/1.1 200 Connection established'));
        socket.listen(null);
      });
      final error = await failsWithin(
          connect(SshService(), hostAt('127.0.0.1', server.port)),
          const Duration(seconds: 3));
      expect(error, isA<RouteHopException>());
      expect('$error', contains('没有收到 SSH 版本信息'));
    });

    test('SOX02 版本行被拆成几个包：攒齐再交给 SSH，不误断（修前 13 ms 就断）', () async {
      final server = await sshLikeServer((socket) async {
        for (final part in ['SSH-2.0-Sp', 'lit_9', '.9\r\n']) {
          socket.add(ascii.encode(part));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        socket.listen(null);
      });
      final service = SshService();
      var finished = false;
      final outcome = connect(
              service,
              HostProfile({
                ...hostAt('127.0.0.1', server.port).data,
                'sshTcpConnectTimeoutSeconds': 3,
              }),
              id: 'split')
          .then<Object?>((_) => null, onError: (Object error) => error)
          .whenComplete(() => finished = true);
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      expect(finished, isFalse, reason: '版本行被接受后应在等密钥交换，而不是已经失败');
      service.cancelConnection('split');
      expect(await outcome, isA<ConnectionCancelledException>());
    });

    test('版本行到了以后不再计时：之后的等待（比如用户看指纹）不受这个期限限制', () async {
      final server = await sshLikeServer((socket) {
        socket.add(ascii.encode('SSH-2.0-OpenSSH_9.9\r\n'));
        socket.listen(null);
      });
      final service = SshService();
      var finished = false;
      final outcome =
          connect(service, hostAt('127.0.0.1', server.port), id: 'b')
              .then<Object?>((_) => null, onError: (Object error) => error)
              .whenComplete(() => finished = true);
      await Future<void>.delayed(const Duration(milliseconds: 1800));
      expect(finished, isFalse, reason: '1 秒的网络期限不应该掐断已经在进行的 SSH 握手');
      service.cancelConnection('b');
      expect(await outcome, isA<ConnectionCancelledException>());
    });

    test('SSH 握手等待中取消：马上结束，连接被关', () async {
      final closed = Completer<void>();
      final server = await sshLikeServer(
          (socket) => socket.listen(null, onDone: closed.complete));
      final service = SshService();
      await cancelledWithin(
          service,
          'h',
          connect(
              service,
              HostProfile({
                ...hostAt('127.0.0.1', server.port).data,
                'sshTcpConnectTimeoutSeconds': 10,
              }),
              id: 'h'),
          const Duration(milliseconds: 500));
      await closed.future.timeout(const Duration(milliseconds: 500));
    });
  });

  group('SOX04 代理口令是明文', () {
    test('代理端直接读到口令原文（线路上没有加密）', () async {
      final fixture =
          await Socks5Fixture.start(username: 'u', password: secret);
      addTearDown(fixture.close);
      final socket = await Socket.connect(fixture.host, fixture.port);
      try {
        await proxyHandshake(
          socket,
          ProxyEntry(
            type: ProxyType.socks5,
            endpoint: Endpoint.parse(fixture.host, fixture.port, what: '代理'),
            username: 'u',
            password: secret,
          ),
          target,
          deadline: const Duration(seconds: 2),
        );
      } on ProxyHandshakeException {
        // 目标名不在 fixture 表里，CONNECT 会被拒；这里只看认证阶段代理读到了什么。
      }
      expect(fixture.attempts.single.password, secret);
    });

    Future<void> pumpEditor(WidgetTester tester, HostProfile host) async {
      tester.view.physicalSize = const Size(800, 20000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final repository = await VaultRepository.open();
      await tester.pumpWidget(ProviderScope(
        overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(home: HostEditor(host: host)),
      ));
      await tester.pump();
    }

    testWidgets('选了代理的主机：编辑器写明口令不受 SSH 加密保护', (tester) async {
      await pumpEditor(
        tester,
        HostProfile.create(
                id: 'h', label: 'h', hostname: 'h.example', username: 'u')
            .copyWith(
          proxyConfig: const ProxyConfig(
            type: ProxyType.socks5,
            host: 'proxy.example',
            port: 1080,
            username: 'u',
            password: secret,
          ),
        ),
      );
      expect(find.textContaining('明文发给代理'), findsOneWidget);
    });

    testWidgets('不用代理的主机：不显示这条提示', (tester) async {
      await pumpEditor(
        tester,
        HostProfile.create(
            id: 'h', label: 'h', hostname: 'h.example', username: 'u'),
      );
      expect(find.textContaining('明文发给代理'), findsNothing);
    });
  });
}
