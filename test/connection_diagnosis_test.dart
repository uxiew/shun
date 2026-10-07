import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/connection_diagnosis.dart';
import 'package:netcatty_mobile/application/session_controller.dart';
import 'package:netcatty_mobile/application/vault_controller.dart';
import 'package:netcatty_mobile/domain/connection_route.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/route_description.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_identity.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/infrastructure/transport/proxy_transport.dart';
import 'package:netcatty_mobile/presentation/screens/terminal_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures/net/socks5_fixture.dart';
import 'package:netcatty_mobile/infrastructure/terminal/ghostty_terminal_adapter.dart';

// R10 / UX04：失败后给出对应真实失败类型的下一步；路线描述只写 App 自己做的事。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  HostProfile host(String id, {Map<String, Object?> extra = const {}}) =>
      HostProfile({
        'id': id,
        'label': id,
        'hostname': '$id.example.com',
        'port': 2222,
        'username': 'deploy',
        'protocol': 'ssh',
        ...extra,
      });

  RouteHopException hopError(Object cause) =>
      RouteHopException(0, '目标“web”（web:22）SSH 握手或登录失败：…', cause);

  group('connectionHint 按真实失败类型给下一步', () {
    test('各类失败对应各自的提示', () {
      expect(connectionHint(const RouteConfigException('x')), contains('连接路径'));
      expect(connectionHint(hopError(const SshIdentityException('私钥口令不对'))),
          contains('私钥'));
      expect(connectionHint(hopError(const ProxyHandshakeException('x'))),
          contains('代理之后怎么走由代理决定'));
      expect(connectionHint(hopError(const ConnectStageException('x'))),
          contains('SSH 端口和代理端口是两个不同的端口'));
      expect(connectionHint(hopError(SSHAuthFailError('x'))),
          contains('authorized_keys'));
      expect(connectionHint(hopError(SSHAuthAbortError('x'))),
          contains('把代理端口或别的服务端口填成了 SSH 端口'));
      expect(
          connectionHint(
              RouteHopException(0, '…', SSHAuthAbortError('x'), relayed: true)),
          contains('代理或跳板机之后的那一段断了'));
      expect(connectionHint(hopError(SSHHostkeyError('x'))),
          contains('不要为了连上而接受不认识的指纹'));
      expect(connectionHint(hopError(SSHChannelOpenError(1, 'refused'))),
          contains('AllowTcpForwarding'));
      expect(connectionHint(hopError(const SocketException('x'))),
          contains('VPN'));
    });

    test('报错自己已经说清的、认不出的：不画蛇添足', () {
      expect(connectionHint(StateError('x')), isNull);
      expect(connectionHint(UnsupportedError('Mosh')), isNull);
    });
  });

  group('连上后在登录前被关：经代理和直连分开说（R15）', () {
    // 接下 TCP 就关：直连时像「端口上不是 SSH」，经代理时也可能是代理之后那一段断了。
    late ServerSocket closer;
    setUp(() async {
      closer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      closer.listen((socket) => socket.destroy());
    });
    tearDown(() => closer.close());

    Future<Object> failure(HostProfile target) async {
      try {
        await SshService().connect(
          terminal: GhosttyTerminalAdapter(),
          sessionId: 'r15-relayed',
          host: target,
          hosts: [target],
          verifyHostKey: (_, __, ___) async => true,
        );
      } catch (error) {
        return error;
      }
      fail('应当失败');
    }

    test('经代理：代理回报连上、随后被关 → 提示也指向代理之后那一段', () async {
      final socks = await Socks5Fixture.start(names: {
        'web.internal': (host: '127.0.0.1', port: closer.port),
      });
      addTearDown(socks.close);
      final error = await failure(HostProfile({
        'id': 'web',
        'label': 'web',
        'hostname': 'web.internal',
        'port': 22,
        'username': 'deploy',
        'protocol': 'ssh',
        'proxyConfig': {
          'type': 'socks5',
          'host': '127.0.0.1',
          'port': socks.port
        },
      }));
      expect(error, isA<RouteHopException>());
      error as RouteHopException;
      expect(error.cause, isA<SSHAuthAbortError>());
      expect(error.relayed, isTrue);
      expect(connectionHint(error), contains('代理或跳板机之后的那一段断了'));
    });

    test('直连：仍按「这个端口上不是 SSH」提示', () async {
      final error = await failure(HostProfile({
        'id': 'web',
        'label': 'web',
        'hostname': '127.0.0.1',
        'port': closer.port,
        'username': 'deploy',
        'protocol': 'ssh',
      }));
      expect(error, isA<RouteHopException>());
      error as RouteHopException;
      expect(error.cause, isA<SSHAuthAbortError>());
      expect(error.relayed, isFalse);
      expect(connectionHint(error), contains('把代理端口或别的服务端口填成了 SSH 端口'));
    });
  });

  group('路线描述', () {
    test('经代理的一段注明代理之后 App 看不到；SSH 端口和代理端口分开写', () {
      final plan = resolveRoutePlan(
        host('web', extra: {
          'hostChain': {
            'hostIds': ['edge'],
          },
          'proxyConfig': {'type': 'socks5', 'host': '127.0.0.1', 'port': 1080},
        }),
        hosts: [
          host('edge', extra: {'port': 22})
        ],
        proxyProfiles: const [],
      );
      final legs = describeRoute(plan);
      expect(legs.map((l) => l.title), [
        '手机',
        'SOCKS5 代理',
        '跳板机“edge”',
        '目标“web”',
      ]);
      expect(legs[1].detail, '127.0.0.1:1080（代理之后怎么走由代理决定，App 看不到）');
      expect(legs[2].detail, 'deploy@edge.example.com:22');
      expect(legs[3].detail, 'SSH deploy@web.example.com:2222');
      expect(routeSummary(plan), '手机 → SOCKS5 代理 → 跳板机“edge” → 目标“web”');
    });
  });

  testWidgets('失败页：显示错误、下一步、这次实际走的路线', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async => null);
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    final target = host('web', extra: {
      'proxyConfig': {'type': 'socks5', 'host': '127.0.0.1', 'port': 1080},
    });
    final plan =
        resolveRoutePlan(target, hosts: const [], proxyProfiles: const []);
    final failed = PendingTerminalConnection(
      id: 'p1',
      host: target,
      phase: PendingConnectionPhase.failed,
      error: RouteHopException(
        0,
        '目标“web”（web.example.com:2222）SSH 握手或登录失败：登录完成前连接被对方关闭',
        SSHAuthAbortError('closed'),
        relayed: true,
      ),
      routePlan: plan,
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
        sessionControllerProvider.overrideWith((ref) => _Seeded(
              ref.read(vaultControllerProvider.notifier),
              ref,
              SessionState(pendingConnections: [failed], activePendingId: 'p1'),
            )),
      ],
      child: const MaterialApp(home: Scaffold(body: TerminalScreen())),
    ));
    await tester.pump();
    expect(find.text('安全连接建立失败'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('connection-failure-hint')), findsOneWidget);
    expect(find.textContaining('代理或跳板机之后的那一段断了'), findsOneWidget);
    expect(find.text('这次实际走的路线'), findsOneWidget);
    expect(find.text('2. SOCKS5 代理'), findsOneWidget);
    expect(find.text('SSH deploy@web.example.com:2222'), findsOneWidget);
  });
}

class _Seeded extends SessionController {
  _Seeded(VaultController vault, Ref ref, SessionState initial)
      : super(SshService(), vault, ref) {
    state = initial;
  }
}
