import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/device_links.dart';
import 'package:netcatty_mobile/application/plugin_registry.dart';
import 'package:netcatty_mobile/application/tailscale_catalog_refresh.dart';
import 'package:netcatty_mobile/application/uuremote.dart';
import 'package:netcatty_mobile/domain/device_references.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/plugins/builtin_plugins.dart';
import 'package:netcatty_mobile/infrastructure/plugins/uuremote_adapter.dart';
import 'package:plugin_api/plugin_api.dart';

import 'uuremote_fakes.dart';

// X06：UU 绑定与远控的状态机。平台层是假的（记下发出的 URI、手动喂回调），存储在内存里。
// 证明的是本 App 发什么、认什么、显示什么；不证明真实 UU 远程的行为——那要装官方 App、登录真实账号。

const id = 'Zm9v+YmFy/YmF6==';

Map<String, String> queryOf(String uri) {
  final raw = uri.substring(uri.indexOf('?') + 1);
  return {
    for (final part in raw.split('&'))
      part.substring(0, part.indexOf('=')):
          Uri.decodeComponent(part.substring(part.indexOf('=') + 1)),
  };
}

void main() {
  late FakePlatform platform;
  late MemoryBackend backend;
  late List<UuHost> hosts;
  late DateTime clock;
  late UuRemoteController c;

  UuRemoteController build({PluginRegistry? registry}) => UuRemoteController(
        platform: platform,
        store: UuRemoteStore(backend),
        registry: registry ??
            PluginRegistry(
              policy: AdmissionPolicy(builtinIds: BuiltinPlugins.ids),
            ),
        hosts: () async => hosts,
        now: () => clock,
      );

  setUp(() async {
    platform = FakePlatform();
    backend = MemoryBackend();
    hosts = const [
      UuHost(id: 'h1', label: 'win-pc', sshRoute: RequestedRoute.systemDefault),
      UuHost(id: 'h2', label: 'mac', sshRoute: RequestedRoute.socks5Connect),
    ];
    clock = DateTime.utc(2026, 9, 30, 12);
    c = build();
    await c.ready;
    await c.approveSigner('cert-a');
  });

  tearDown(() => c.dispose());

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  /// 按官方「保留原参数、追加结果字段」构造 UU 的回调。
  String callbackFor(String uri, Map<String, String> fields) {
    final callback = queryOf(uri)['callback']!;
    return '$callback&${fields.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&')}';
  }

  Future<void> bound(String hostId) async {
    await c.startBind(hostId);
    final uri = platform.launched.last;
    platform.deliver(callbackFor(uri, {
      'anonymous_device_id': id,
      'nonce': queryOf(uri)['nonce']!,
    }));
    await settle();
    await c.confirmOffer();
  }

  group('UUR01 装没装、版本、证书', () {
    test('没装 / 只有别的 App 声明 uuremote / 版本太旧 / 换签：一律拒绝，什么都不发', () async {
      final cases = <UuProbe>[
        const UuProbe(
            platformSupported: true, otherHandlers: ['example.fakeuu']),
        const UuProbe(
          platformSupported: true,
          officialInstalled: true,
          officialHandlesScheme: true,
          versionName: '4.41.0',
          signers: {'cert-a'},
        ),
        const UuProbe(
          platformSupported: true,
          officialInstalled: true,
          officialHandlesScheme: true,
          versionName: '4.42.0',
          signers: {'cert-b'},
        ),
        const UuProbe(platformSupported: false),
      ];
      for (final probe in cases) {
        platform.probeResult = probe;
        await expectLater(c.startBind('h1'), throwsA(isA<UuRequestRefused>()));
      }
      expect(platform.launched, isEmpty);
      expect(c.state.pending, isNull);
    });

    test('批准只认此刻系统读出的证书；撤销后又要批准', () async {
      platform.probeResult = const UuProbe(
        platformSupported: true,
        officialInstalled: true,
        officialHandlesScheme: true,
        versionName: '4.42.0',
        signers: {'cert-b'},
      );
      await c.refreshApp();
      expect(c.state.app, isA<UuSignerChanged>());
      await expectLater(
          c.approveSigner('cert-x'), throwsA(isA<UuRequestRefused>()));
      await c.approveSigner('cert-b');
      expect(c.state.app, isA<UuReady>());
      await c.revokeApproval();
      expect(c.state.app, isA<UuSignerNeedsApproval>());
    });

    test('registry 里没有 UU 能力：在探测、发请求之前就拒绝', () async {
      final noUu = build(
        registry: PluginRegistry(
          policy: AdmissionPolicy(builtinIds: BuiltinPlugins.ids),
          builtins: [
            for (final d in BuiltinPlugins.descriptors)
              if (d.pluginId != BuiltinPlugins.uuremote) d,
          ],
        ),
      );
      addTearDown(noUu.dispose);
      await noUu.ready;
      await expectLater(
          noUu.startBind('h1'), throwsA(isA<PluginUnavailable>()));
      await expectLater(
        noUu.launch('h1', UuWindow.fullscreen),
        throwsA(isA<PluginUnavailable>()),
      );
      expect(platform.launched, isEmpty);
    });

    test('请求用批准的那张证书发出（平台层发之前再核一次）', () async {
      await c.startBind('h1');
      expect(platform.signersUsed, ['cert-a']);
    });
  });

  group('UUR02 绑定：回调要对上，用户确认后才保存', () {
    test('请求带 nonce 和一次性 state；回调对上后先等确认，确认后按原样存下加密标识', () async {
      await c.startBind('h1');
      final uri = platform.launched.single;
      expect(uri, startsWith('uuremote://external/device/authorize?callback='));
      final q = queryOf(uri);
      expect(
          q['nonce'],
          matches(RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      expect(
          q['callback'], startsWith('xwshun-uuremote://callback/bind?state='));
      expect(backend.values['uuremote.pending.v1'], isNotNull);

      platform.deliver(
          callbackFor(uri, {'anonymous_device_id': id, 'nonce': q['nonce']!}));
      await settle();
      expect(c.state.offer?.hostId, 'h1');
      expect(c.state.bindings, isEmpty, reason: '确认之前不保存');
      expect(c.state.pending, isNull);

      await c.confirmOffer();
      expect(c.state.bindingOf('h1')!.anonymousDeviceId, id);
      expect(
          backend.values['uuremote.bindings.v1'], contains('Zm9v+YmFy/YmF6=='));
      expect(platform.launched, hasLength(1), reason: '回调后不自动远控');
      expect('${c.state.bindingOf('h1')}', isNot(contains(id)));
    });

    test('nonce 不对：作废这次请求，不给确认', () async {
      await c.startBind('h1');
      final uri = platform.launched.single;
      platform.deliver(callbackFor(uri, {
        'anonymous_device_id': id,
        'nonce': '00000000-0000-4000-8000-000000000000',
      }));
      await settle();
      expect(c.state.offer, isNull);
      expect(c.state.pending, isNull);
      expect(c.state.attempts['h1']!.phase,
          ExternalLaunchPhase.providerReportedFailure);
    });

    test('格式不对的回调（重复参数）：忽略，请求还在等', () async {
      await c.startBind('h1');
      final uri = platform.launched.single;
      final nonce = queryOf(uri)['nonce']!;
      platform.deliver('${callbackFor(uri, {
            'anonymous_device_id': id,
            'nonce': nonce
          })}&nonce=$nonce');
      await settle();
      expect(c.state.notice, contains('格式不对'));
      expect(c.state.pending, isNotNull);
      expect(c.state.offer, isNull);
    });

    test('用户不要这次绑定：什么都不存', () async {
      await c.startBind('h1');
      final uri = platform.launched.single;
      platform.deliver(callbackFor(
          uri, {'anonymous_device_id': id, 'nonce': queryOf(uri)['nonce']!}));
      await settle();
      c.discardOffer();
      expect(c.state.offer, isNull);
      expect(backend.values['uuremote.bindings.v1'], isNull);
      expect(c.state.attempts['h1']!.code, uuDiscardedByUser);
    });

    test('绑定失败的错误码原样记下，未知的也记', () async {
      for (final code in [
        'user_cancel',
        'no_device',
        'superseded',
        'brand_new'
      ]) {
        await c.startBind('h1');
        final uri = platform.launched.last;
        platform.deliver(
            callbackFor(uri, {'error': code, 'nonce': queryOf(uri)['nonce']!}));
        await settle();
        expect(c.state.attempts['h1']!.code, code);
        expect(c.state.pending, isNull);
      }
      expect(c.state.bindings, isEmpty);
    });

    test('发送失败：撤回请求，记为没能打开 UU', () async {
      platform.failLaunch = '没有找到 UU 远程';
      await expectLater(c.startBind('h1'), throwsA(isA<UuLaunchFailed>()));
      expect(c.state.pending, isNull);
      expect(backend.values['uuremote.pending.v1'], isNull);
      expect(c.state.attempts['h1']!.phase, ExternalLaunchPhase.launchFailed);
    });
  });

  group('UUR03 全屏：只交给 UU，不等回调', () {
    test('不带 callback、不留等待中的请求；只显示已交给 UU；之后来的回调一律忽略', () async {
      await bound('h1');
      await c.launch('h1', UuWindow.fullscreen);
      final uri = platform.launched.last;
      expect(uri, contains('window_type=0'));
      expect(uri, isNot(contains('callback')));
      expect(queryOf(uri)['anonymous_device_id'], id);
      expect(c.state.pending, isNull);
      final attempt = c.state.attempts['h1']!;
      expect(attempt.phase, ExternalLaunchPhase.launchedUnverified);
      expect(attempt.window, UuWindow.fullscreen);

      platform.deliver(
          'xwshun-uuremote://callback/control?state=AAAAAAAAAAAAAAAAAAAAAA&status=success');
      await settle();
      expect(c.state.attempts['h1']!.phase,
          ExternalLaunchPhase.launchedUnverified);
      expect(c.state.notice, contains('没有对应的请求'));
    });
  });

  group('UUR04 小窗：只显示 UU 报告的结果', () {
    test('成功：记下 UU 报告的时间；不是持续在线', () async {
      await bound('h1');
      await c.launch('h1', UuWindow.pip);
      final uri = platform.launched.last;
      expect(uri, contains('window_type=1'));
      expect(queryOf(uri)['callback'],
          startsWith('xwshun-uuremote://callback/control?state='));
      clock = clock.add(const Duration(seconds: 9));
      platform.deliver(callbackFor(uri, {'status': 'success'}));
      await settle();
      final attempt = c.state.attempts['h1']!;
      expect(attempt.phase, ExternalLaunchPhase.providerReportedSuccess);
      expect(attempt.at, clock);
    });

    test('pip_unsupported：记失败，不自动改全屏', () async {
      await bound('h1');
      await c.launch('h1', UuWindow.pip);
      final count = platform.launched.length;
      platform.deliver(callbackFor(platform.launched.last,
          {'status': 'failure', 'reason': 'pip_unsupported'}));
      await settle();
      expect(c.state.attempts['h1']!.code, 'pip_unsupported');
      expect(platform.launched, hasLength(count));
    });
  });

  group('UUR05 串行、结束等待、迟到、过期', () {
    test('有请求在等：新请求被拒；结束等待后记「未确认」，迟到的回调不算数', () async {
      await bound('h1');
      await c.launch('h1', UuWindow.pip);
      final first = platform.launched.last;
      await expectLater(
          c.launch('h1', UuWindow.pip), throwsA(isA<UuRequestRefused>()));
      await expectLater(c.startBind('h2'), throwsA(isA<UuRequestRefused>()));

      await c.endWaiting();
      expect(c.state.pending, isNull);
      expect(c.state.attempts['h1']!.unconfirmed, isTrue);

      await c.launch('h1', UuWindow.pip);
      final second = platform.launched.last;
      // 第一次的回调迟到：state 对不上新请求，不覆盖它。
      platform
          .deliver(callbackFor(first, {'status': 'failure', 'reason': 'busy'}));
      await settle();
      expect(c.state.pending, isNotNull);
      expect(c.state.attempts['h1']!.phase,
          ExternalLaunchPhase.launchedUnverified);
      platform.deliver(callbackFor(second, {'status': 'success'}));
      await settle();
      expect(c.state.attempts['h1']!.phase,
          ExternalLaunchPhase.providerReportedSuccess);
      expect(
          platform.launched.where((u) => u.contains('control')), hasLength(2),
          reason: '没有自动再发');
    });

    test('超过 10 分钟：回调作废；新请求不再被挡', () async {
      await bound('h1');
      await c.launch('h1', UuWindow.pip);
      final uri = platform.launched.last;
      clock = clock.add(uuPendingLifetime);
      platform.deliver(callbackFor(uri, {'status': 'success'}));
      await settle();
      expect(c.state.notice, contains('过期'));
      expect(c.state.attempts['h1']!.phase,
          ExternalLaunchPhase.launchedUnverified);
      await c.launch('h1', UuWindow.pip);
      expect(c.state.pending, isNotNull);
    });
  });

  group('UUR06 伪造、重放、串用', () {
    test('没有请求时伪造的回调：忽略', () async {
      platform.deliver(
          'xwshun-uuremote://callback/bind?state=AAAAAAAAAAAAAAAAAAAAAA&anonymous_device_id=x&nonce=y');
      await settle();
      expect(c.state.offer, isNull);
      expect(c.state.notice, contains('没有对应的请求'));
    });

    test('同一条回调来两次：第二次是重放，忽略', () async {
      await c.startBind('h1');
      final uri = platform.launched.single;
      final cb = callbackFor(
          uri, {'error': 'user_cancel', 'nonce': queryOf(uri)['nonce']!});
      platform.deliver(cb);
      await settle();
      c.clearNotice();
      platform.deliver(cb);
      await settle();
      expect(c.state.notice, contains('没有对应的请求'));
    });

    test('拿绑定请求的 state 伪造小窗成功：类型对不上，作废，不算成功', () async {
      await c.startBind('h1');
      final state = queryOf(queryOf(platform.launched.single)['callback']!
          .replaceFirst('?', '?x=1&'))['state']!;
      platform.deliver(
          'xwshun-uuremote://callback/control?state=$state&status=success');
      await settle();
      expect(c.state.attempts['h1']!.phase,
          ExternalLaunchPhase.providerReportedFailure);
      expect(c.state.pending, isNull);
      expect(c.state.offer, isNull);
    });

    // scheme 劫持：自定义 scheme 谁都能声明，回调本身证明不了是谁发的。能做的是发现「有别的 App 也声明了」就不走回调。
    const withRival = UuProbe(
      platformSupported: true,
      officialInstalled: true,
      officialHandlesScheme: true,
      versionName: '4.42.0',
      signers: {'cert-a'},
      callbackRivals: ['example.hijacker'],
    );

    test('别的 App 也声明了回调地址：绑定和小窗不发，说出是哪个包；全屏照常', () async {
      await bound('h1');
      final before = platform.launched.length;
      platform.probeResult = withRival;
      await expectLater(
        c.startBind('h1'),
        throwsA(isA<UuRequestRefused>()
            .having((e) => e.message, 'message', contains('example.hijacker'))),
      );
      await expectLater(
          c.launch('h1', UuWindow.pip), throwsA(isA<UuRequestRefused>()));
      expect(platform.launched, hasLength(before));
      expect(c.state.pending, isNull);
      expect(c.state.callbackRivals, ['example.hijacker']);

      await c.launch('h1', UuWindow.fullscreen);
      expect(platform.launched, hasLength(before + 1));
    });

    test('请求发出后才装上抢回调的 App：state、nonce 都对的成功回调也不采用，不给确认', () async {
      await c.startBind('h1');
      final uri = platform.launched.single;
      platform.probeResult = withRival;
      // 它截下真回调，把设备标识换成自己的再转过来。
      platform.deliver(callbackFor(uri, {
        'anonymous_device_id': 'attacker-device',
        'nonce': queryOf(uri)['nonce']!,
      }));
      await settle();
      expect(c.state.offer, isNull);
      expect(c.state.pending, isNull);
      expect(c.state.attempts['h1']!.code, uuCallbackContested);
      expect(backend.values['uuremote.bindings.v1'], isNull);
    });

    test('冷启动：请求存盘，新进程里回调照样对得上', () async {
      await c.startBind('h1');
      final uri = platform.launched.single;
      c.dispose();
      c = build();
      await c.ready;
      expect(c.state.pending?.hostId, 'h1');
      platform.deliver(callbackFor(
          uri, {'anonymous_device_id': id, 'nonce': queryOf(uri)['nonce']!}));
      await settle();
      expect(c.state.offer?.anonymousDeviceId, id);
    });
  });

  group('UUR07 绑定失效只标 UU 这一条', () {
    test('device_not_found：只把这条绑定标失效、不能再发；另一台主机的绑定和关联都在；重新绑定替换', () async {
      await bound('h1');
      await bound('h2');
      await c.launch('h1', UuWindow.pip);
      platform.deliver(callbackFor(platform.launched.last,
          {'status': 'failure', 'reason': 'device_not_found'}));
      await settle();
      expect(c.state.bindingOf('h1')!.valid, isFalse);
      expect(c.state.bindingOf('h2')!.valid, isTrue);
      await expectLater(c.launch('h1', UuWindow.fullscreen),
          throwsA(isA<UuRequestRefused>()));

      await bound('h1');
      expect(c.state.bindings.where((b) => b.hostId == 'h1'), hasLength(1));
      expect(c.state.bindingOf('h1')!.valid, isTrue);
    });
  });

  group('UUR08 SSH 经代理/跳板时，UU 用自己的网络', () {
    test('没确认就不发；确认后发，且不带任何代理设置', () async {
      await bound('h2');
      await expectLater(
        c.launch('h2', UuWindow.fullscreen),
        throwsA(isA<UuRouteNeedsConfirmation>()),
      );
      final before = platform.launched.length;
      expect(platform.launched, hasLength(before));
      await c.launch('h2', UuWindow.fullscreen,
          acceptProviderManagedNetwork: true);
      expect(platform.launched, hasLength(before + 1));
      expect(queryOf(platform.launched.last).keys,
          {'anonymous_device_id', 'window_type'});
    });

    test('主机路线归类', () {
      HostProfile host(Map<String, Object?> extra) => HostProfile({
            'id': 'x',
            'label': 'x',
            'hostname': 'x',
            ...extra,
          });
      expect(sshRouteOf(host({})), RequestedRoute.systemDefault);
      expect(sshRouteOf(host({'proxyProfileId': 'p'})),
          RequestedRoute.socks5Connect);
      expect(
          sshRouteOf(host({
            'proxyConfig': {'type': 'http'}
          })),
          RequestedRoute.socks5Connect);
      expect(
        sshRouteOf(host({
          'hostChain': {
            'hostIds': ['j']
          },
        })),
        RequestedRoute.proxyJump,
      );
      expect(
        sshRouteOf(host({
          'hostChain': {'hostIds': <String>[]},
        })),
        RequestedRoute.systemDefault,
      );
      expect(
          sshRouteOf(host({'hostChain': 'broken'})), RequestedRoute.proxyJump);
    });
  });

  group('DEV01/DEV02 关联', () {
    test('一台主机的 SSH、目录设备、UU 绑定聚成一条；删 UU 绑定只断这一条', () async {
      await bound('h1');
      const catalogHosts = [
        CatalogHost(
          id: 'h1',
          label: 'win-pc',
          hostname: '100.64.0.5',
          binding: CatalogBinding(catalogId: 'ts-a', deviceId: 'n1'),
        ),
        CatalogHost(id: 'h2', label: 'win-pc', hostname: '100.64.0.5'),
      ];
      final links = deviceLinksOf(hosts: catalogHosts, uu: c.state.bindings);
      final binding = c.state.bindingOf('h1')!;
      expect(links.records.single.refs, {
        sshHostRef('h1', displayName: 'win-pc'),
        catalogDeviceRef('ts-a', 'n1'),
        uuBindingRef(binding.id),
      });
      // 同名同地址的另一台主机没被合进来（DEV01）。
      expect(links.recordOf(sshHostRef('h2', displayName: 'win-pc')), isNull);
      // 引用里没有加密设备标识。
      expect(
          links.records.single.refs.map((r) => r.refId), isNot(contains(id)));

      await c.deleteBinding(binding.id);
      final after = deviceLinksOf(hosts: catalogHosts, uu: c.state.bindings);
      expect(after.records.single.refs, {
        sshHostRef('h1', displayName: 'win-pc'),
        catalogDeviceRef('ts-a', 'n1'),
      });
    });
  });
}
