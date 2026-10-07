import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/connection_diagnosis.dart';
import 'package:netcatty_mobile/domain/connection_route.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/tailscale_ssh.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_login_watch.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';

import 'fixtures/tailscale/tailssh_fixture.dart';
import 'package:netcatty_mobile/infrastructure/terminal/ghostty_terminal_adapter.dart';

// R14：Tailscale SSH 外部认证。服务器是 tool/tailscale-ssh-fixture——照 tailssh v1.104.0 认证行为仿制、
// 用同版本 x/crypto 的本机程序，不是真的 Tailscale。用户名选场景：accept / reject / check / evil-*。
// 主机地址一律写 100.x，由注入的拨号器接到本机端口：验证 App 不因为地址是 100.x 就换登录方式（TSC07）。
Future<void> main() async {
  // 先起服务器再声明用例：起不来时整组 skip（证据记 NOT_RUN），不能当通过。
  final fixture = await TailsshFixture.start();
  final skip = fixture == null ? TailsshFixture.skipReason : false;
  // 只在没 skip 的用例里用；起不来时这些用例根本不跑，也就不会碰到它。
  late final TailsshFixture fx = fixture!;
  tearDownAll(() async => fixture?.stop());

  const tailnetAddress = '100.101.102.103';
  final dialed = <String>[];

  SshService service({Duration checkWait = const Duration(minutes: 10)}) =>
      SshService(
        tailscaleCheckWait: checkWait,
        dialer: (host, port, {timeout}) {
          dialed.add('$host:$port');
          // 只把这一个 tailnet 地址接到 fixture：别的地址照常直拨会失败，测试就能发现。
          if (host == tailnetAddress && port == 22) {
            return Socket.connect(InternetAddress.loopbackIPv4, fx.sshPort,
                timeout: timeout);
          }
          return Socket.connect(host, port, timeout: timeout);
        },
      );

  HostProfile host(String user,
          {bool tailscale = false, Map<String, dynamic> extra = const {}}) =>
      HostProfile({
        'id': 'ts-$user-${tailscale ? 'tailscale' : 'standard'}',
        'label': 'node-$user',
        'hostname': tailnetAddress,
        'port': 22,
        'username': user,
        'protocol': 'ssh',
        'authMethod': 'auto',
        if (tailscale) sshLoginModeKey: 'tailscale',
        ...extra,
      });

  // 这次尝试里先后发生了什么：指纹核对、交出 check 提示。用来证明指纹先于链接（docs/05）。
  final order = <String>[];
  setUp(order.clear);
  Future<bool> verify(HostProfile h, String type, String fingerprint) async {
    order.add('verify');
    return fingerprint == fx.fingerprint;
  }

  Future<
      ({
        Object? error,
        ProbeOutcome? outcome,
        List<TailscaleCheckPrompt?> prompts,
        List<ConnectionStep> steps
      })> probe(
    HostProfile target, {
    SshService? using,
    List<SshKeyProfile> keys = const [],
    HostKeyVerifier? verifyHostKey,
    FutureOr<void> Function(
            ConnectionAttempt attempt, TailscaleCheckPrompt prompt)?
        onPrompt,
  }) async {
    final prompts = <TailscaleCheckPrompt?>[];
    final steps = <ConnectionStep>[];
    late final ConnectionAttempt attempt;
    attempt = ConnectionAttempt(
      onStage: (stage) => steps.add(stage.step),
      onCheckPrompt: (prompt) {
        prompts.add(prompt);
        if (prompt != null) {
          order.add('prompt');
          onPrompt?.call(attempt, prompt);
        }
      },
    );
    try {
      final outcome = await (using ?? service()).probe(
        host: target,
        hosts: [target],
        keys: keys,
        verifyHostKey: verifyHostKey ?? verify,
        attempt: attempt,
      );
      return (error: null, outcome: outcome, prompts: prompts, steps: steps);
    } catch (error) {
      return (error: error, outcome: null, prompts: prompts, steps: steps);
    }
  }

  List<String?> methods(List<Map<String, dynamic>> events) => [
        for (final e in events)
          if (e['kind'] == 'auth') e['method'] as String?,
      ];

  Object? cause(Object? error) =>
      error is RouteHopException ? error.cause : error;

  group('TSC07 普通 SSH 和 Tailscale SSH 是两回事', () {
    test('普通模式连 100.x：先发保存的密码，不会因为地址是 100.x 就改发 none', () async {
      final result = await probe(host('accept', extra: {'password': 'p4ss'}));
      expect(result.error, isNull);
      expect(result.outcome!.tty, '/dev/pts/9');
      final events = await fx.eventsFor('accept');
      final auths = events.where((e) => e['kind'] == 'auth').toList();
      expect(auths.first['method'], 'password', reason: '普通模式第一个就是用户配的密码');
      expect(auths.first['passwordLen'], 4);
      expect(methods(events), isNot(contains('none')));
      expect(dialed, contains('$tailnetAddress:22'));
    }, skip: skip, timeout: const Timeout(Duration(seconds: 30)));

    test('普通模式没配凭据：dartssh2 自动补发的 none 被放行了，App 也不认，登录后立刻断开、什么都不执行', () async {
      final result =
          await probe(host('accept', extra: {'id': 'no-credentials'}));
      expect(cause(result.error), isA<StandardLoginFellBackToNone>());
      expect('${result.error}', contains('none 认证'));
      final events = await fx.events();
      final conn = events.lastWhere((e) => e['kind'] == 'connect')['conn'];
      final mine = events.where((e) => e['conn'] == conn).toList();
      expect(methods(mine), ['none'],
          reason: '键盘交互 tailssh 不支持，dartssh2 接着就试了 none');
      expect(mine.map((e) => e['kind']), isNot(contains('exec')),
          reason: '登录虽然成了，连 tty 都没执行就断开');
      expect(mine.map((e) => e['kind']), isNot(contains('shell')));
    }, skip: skip, timeout: const Timeout(Duration(seconds: 30)));

    test('普通模式碰上 check：不显示链接、不等 30 分钟，立刻断开并说明要改成 Tailscale SSH', () async {
      final result = await probe(host('check', extra: {'password': 'p4ss'}));
      expect(cause(result.error), isA<StandardLoginGotCheckLink>());
      expect(result.prompts, isEmpty, reason: '普通模式从不把 check 链接交给界面');
      expect('${result.error}', contains('Tailscale SSH'));
      expect('${result.error}', isNot(contains('login.tailscale.com')));
    }, skip: skip, timeout: const Timeout(Duration(seconds: 30)));

    test('Tailscale 模式：存着密码和（坏的）私钥也只发 none，私钥连解析都不解析', () async {
      final target = host('accept', tailscale: true, extra: {
        'id': 'ts-with-secrets',
        'password': 'should-not-leave-the-phone',
        'identityFileId': 'k-broken',
      });
      final result = await probe(target, keys: [
        SshKeyProfile({
          'id': 'k-broken',
          'privateKey': 'not a private key',
          'passphrase': 'x'
        }),
      ]);
      expect(result.error, isNull);
      expect(result.outcome!.tty, '/dev/pts/9');
      final events = await fx.events();
      final conn = events.lastWhere((e) => e['kind'] == 'connect')['conn'];
      final mine = events.where((e) => e['conn'] == conn).toList();
      expect(methods(mine), ['none']);
      expect(
          mine.where((e) => e['passwordLen'] != null || e['publicKey'] != null),
          isEmpty,
          reason: '服务器一次都没收到密码或公钥');
    }, skip: skip, timeout: const Timeout(Duration(seconds: 30)));

    test('来源节点的说明：直连是手机自己的节点，经代理是代理出口的节点，经跳板是上一跳；都不是目录账号', () {
      final direct = resolveRoutePlan(host('accept', tailscale: true),
          hosts: const [], proxyProfiles: const [], keys: const []);
      expect(tailscaleSourceNode(direct, 0), contains('这台手机'));
      final viaProxy = resolveRoutePlan(
          host('accept', tailscale: true, extra: {
            'proxyConfig': {
              'type': 'socks5',
              'host': '127.0.0.1',
              'port': 1055
            },
          }),
          hosts: const [],
          proxyProfiles: const [],
          keys: const []);
      expect(tailscaleSourceNode(viaProxy, 0),
          contains('代理出口所在的节点（代理地址 127.0.0.1:1055）'));
      final jump = HostProfile.create(
          id: 'j', label: 'edge', hostname: '100.64.0.9', username: 'u');
      final target = host('accept', tailscale: true, extra: {
        'hostChain': {
          'hostIds': ['j']
        },
      });
      final viaJump = resolveRoutePlan(target,
          hosts: [jump, target], proxyProfiles: const [], keys: const []);
      expect(tailscaleSourceNode(viaJump, 1), contains('跳板机“edge”'));
      expect(tailscaleCatalogIsNotIdentity, contains('不参与 SSH 登录'));
    });

    test('从 Tailscale 目录导入的主机、100.x 地址，不写登录方式时一律是普通 SSH', () {
      final imported = HostProfile({
        ...host('accept').data,
        'xwshunCatalogSource': {'catalogId': 'c1', 'deviceId': 'd1'},
      });
      expect(sshLoginModeOf(imported), SshLoginMode.standard);
      expect(sshLoginModeOf(host('accept', tailscale: true)),
          SshLoginMode.tailscale);
      expect(
          sshLoginModeOf(HostProfile(
              {...host('accept').data, sshLoginModeKey: 'TAILSCALE'})),
          SshLoginMode.standard,
          reason: '只认明确的值');
    });
  });

  group('TSC08 check：批准、拒绝、超时、取消、坏链接', () {
    test('批准：先核对指纹，再交出链接；界面拿到域名和来源节点；批准后才算登录，提示随即清掉', () async {
      final result = await probe(host('check', tailscale: true),
          onPrompt: (attempt, prompt) async {
        final id = await fx.pendingCheck('check');
        await fx.decide(id, approve: true);
      });
      expect(result.error, isNull);
      expect(result.outcome!.tty, '/dev/pts/9');
      expect(
          result.steps,
          containsAllInOrder([
            ConnectionStep.handshake,
            ConnectionStep.check,
            ConnectionStep.pty
          ]));
      final prompt = result.prompts.first!;
      expect(prompt.link, isNotNull);
      expect(prompt.link!.link.host, 'login.tailscale.com');
      expect(prompt.link!.display, 'login.tailscale.com/a/…');
      expect(prompt.endpoint, '$tailnetAddress:22');
      expect(prompt.sourceNode, contains('这台手机'));
      expect('$prompt', isNot(contains(prompt.link!.link.path)),
          reason: 'toString 不带 token');
      expect(result.prompts.last, isNull, reason: '登录有结果后提示清掉');
      expect(order, ['verify', 'prompt'], reason: '指纹核对在前，链接在后');
    }, skip: skip, timeout: const Timeout(Duration(seconds: 30)));

    test(
        '拒绝：Tailscale 只发一条 banner 就断 TCP，App 报「Tailscale 拒绝了」而不是「对方可能不是 SSH 服务」',
        () async {
      final result =
          await probe(host('check', tailscale: true, extra: {'id': 'deny'}),
              onPrompt: (attempt, prompt) async {
        await fixture!.decide(await fx.pendingCheck('check'), approve: false);
      });
      final error = cause(result.error);
      expect(error, isA<TailscaleLoginDenied>());
      expect((error as TailscaleLoginDenied).serverMessage,
          'tailscale: access denied');
      expect('${result.error}', isNot(contains('不是 SSH 服务')));
      expect(connectionHint(result.error!), contains('ssh 规则'),
          reason: '下一步提示指向 Tailscale 策略，不是「端口填错了」');
      expect(result.prompts.last, isNull);
    }, skip: skip, timeout: const Timeout(Duration(seconds: 30)));

    test('策略直接拒绝（没有 check）：报出服务器给的原因', () async {
      final result = await probe(host('reject', tailscale: true));
      expect(cause(result.error), isA<TailscaleLoginDenied>());
      expect('${result.error}',
          contains('tailnet policy does not permit you to SSH to this node'));
      expect(result.prompts, isEmpty);
    }, skip: skip, timeout: const Timeout(Duration(seconds: 30)));

    test('超时：check 有单独的期限，到点关掉连接，不执行任何命令', () async {
      final watch = Stopwatch()..start();
      final result = await probe(
          host('check', tailscale: true, extra: {'id': 'slow'}),
          using: service(checkWait: const Duration(seconds: 2)));
      watch.stop();
      final error = cause(result.error);
      expect(error, isA<SshLoginTimeout>());
      expect((error as SshLoginTimeout).checkPending, isTrue);
      expect('${result.error}', contains('没有执行任何命令'));
      expect(watch.elapsed, greaterThan(const Duration(seconds: 2)),
          reason: '收到链接后不再用 30 秒的登录期限，换成 check 期限');
      expect(result.prompts.first, isNotNull);
      expect(result.prompts.last, isNull);
    }, skip: skip, timeout: const Timeout(Duration(seconds: 30)));

    test('取消：等 check 时点终止，连接立刻关掉，之后再批准也不会登录成功', () async {
      final result = await probe(
          host('check', tailscale: true, extra: {'id': 'cancel'}),
          onPrompt: (attempt, prompt) => attempt.cancel());
      expect(result.error, isA<ConnectionCancelledException>());
      final id = await fx.pendingCheck('check');
      await fx.decide(id, approve: true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final events = await fx.events();
      final conn = events.lastWhere((e) => e['kind'] == 'hold')['conn'];
      final kinds =
          events.where((e) => e['conn'] == conn).map((e) => e['kind']).toList();
      expect(kinds, isNot(contains('exec')));
      expect(kinds, contains('closed-before-auth'), reason: '服务器批准后发现客户端早已断开');
    }, skip: skip, timeout: const Timeout(Duration(seconds: 30)));

    for (final (user, reason) in [
      ('evil-domain', '域名不是 login.tailscale.com'),
      ('evil-http', '不是 https 链接'),
      ('evil-two', '不止一条链接'),
      ('evil-intent', '不是 https 链接'),
      ('evil-userinfo', '域名不是 login.tailscale.com'),
      ('evil-path', '样子和 Tailscale check 链接不一样'),
      ('evil-bidi', '不可见的控制字符'),
      ('evil-port', '带了账号或别的端口'),
      ('headscale', '不是 https 链接'),
    ]) {
      test('坏链接 $user：照样提示但不给打开，原因写清；用户可以终止', () async {
        final result = await probe(host(user, tailscale: true),
            onPrompt: (attempt, prompt) => attempt.cancel());
        expect(result.error, isA<ConnectionCancelledException>());
        final prompt = result.prompts.first!;
        expect(prompt.link, isNull, reason: '不给可打开的链接');
        final banner = prompt.banner as RejectedLinkBanner;
        expect(banner.reason, contains(reason));
        expect(banner.text, isNot(contains('://')), reason: '显示的原文里链接被换掉');
      }, skip: skip, timeout: const Timeout(Duration(seconds: 30)));
    }

    test('指纹确认框拖得比登录期限还久：期限从确认后才算，照样登录（模拟器上发现的问题）', () async {
      final result = await probe(
        host('accept',
            tailscale: true,
            extra: {'id': 'slow-trust', 'sshAuthReadyTimeoutSeconds': 1}),
        verifyHostKey: (h, type, fp) async {
          await Future<void>.delayed(const Duration(milliseconds: 2500));
          return fp == fx.fingerprint;
        },
      );
      expect(result.error, isNull);
      expect(result.outcome!.tty, '/dev/pts/9');
    }, skip: skip, timeout: const Timeout(Duration(seconds: 30)));

    test('指纹没通过：服务器连一次认证请求都收不到，更不会有链接', () async {
      final before = (await fx.events()).length;
      final result = await probe(
          host('check', tailscale: true, extra: {'id': 'bad-key'}),
          verifyHostKey: (h, type, fp) async => false);
      expect(result.error, isNotNull);
      expect(result.prompts, isEmpty);
      final events = (await fx.events()).skip(before).toList();
      expect(events.where((e) => e['kind'] == 'auth'), isEmpty);
    }, skip: skip, timeout: const Timeout(Duration(seconds: 30)));

    test('自动恢复碰上 check：不交给界面，直接停下等用户', () async {
      final terminal = GhosttyTerminalAdapter();
      final prompts = <TailscaleCheckPrompt?>[];
      Object? error;
      try {
        await service().connect(
          sessionId: 'restore',
          host: host('check', tailscale: true, extra: {'id': 'restore'}),
          verifyHostKey: verify,
          terminal: terminal,
          purpose: ConnectionPurpose.restore,
          attempt: ConnectionAttempt(onCheckPrompt: prompts.add),
        );
      } catch (e) {
        error = e;
      }
      expect(cause(error), isA<TailscaleCheckNeedsUser>());
      expect(prompts, isEmpty);
    }, skip: skip, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('banner 只在指纹确认后算数', () {
    test('确认前到的链接被丢掉；确认后到的才交给界面', () {
      final prompts = <TailscaleCheckPrompt?>[];
      final watch = SshLoginWatch(
        mode: SshLoginMode.tailscale,
        allowCheck: true,
        authWait: const Duration(seconds: 30),
        checkWait: const Duration(minutes: 10),
        describePrompt: (banner, deadline) => TailscaleCheckPrompt(
          hop: 0,
          hopCount: 1,
          hostLabel: 'x',
          endpoint: 'x:22',
          sourceNode: 's',
          banner: banner,
          deadline: deadline,
        ),
        onPrompt: prompts.add,
      );
      const banner =
          '# To authenticate, visit: https://login.tailscale.com/a/abcdef123456\n';
      watch.banner(banner);
      expect(prompts, isEmpty);
      watch.hostKeyAccepted();
      watch.banner(banner);
      expect(prompts.single!.link, isNotNull);
    });
  });
}
