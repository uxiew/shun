import 'dart:convert';
import 'dart:io';

import 'package:plugin_api/plugin_api.dart';
import 'package:test/test.dart';

// X00 契约测试。这些是纯逻辑测试，证明"规则写对了"；
// 不证明任何插件 APK、Binder 事务或真实外部 App 的行为（那些在 X01–X10）。
void main() {
  const contracts = '../../plan/v3/contracts/examples';
  Map<String, Object?> example(String name) =>
      jsonDecode(File('$contracts/$name').readAsStringSync())
          as Map<String, Object?>;
  PluginDescriptor parse(Map<String, Object?> m) =>
      PluginDescriptor.parse(jsonEncode(m));

  group('SDK03 描述符：与 JSON schema 判定一致', () {
    test('合法示例都能解析', () {
      for (final f in Directory(contracts).listSync().whereType<File>()) {
        expect(
          () => PluginDescriptor.parse(f.readAsStringSync()),
          returnsNormally,
          reason: f.path,
        );
      }
    });

    test('invalid/ 下每个负例都被拒绝（Python schema 也拒绝同一批文件）', () {
      final files = Directory(
        '$contracts/invalid',
      ).listSync().whereType<File>().toList();
      expect(files, hasLength(greaterThanOrEqualTo(9)));
      for (final f in files) {
        expect(
          () => PluginDescriptor.parse(f.readAsStringSync()),
          throwsA(isA<DescriptorException>()),
          reason: f.path,
        );
      }
    });

    test('超过 16 KiB 的描述符直接拒绝，不解析', () {
      final m = example('mosh-provider.json')..['license'] = 'x' * 20000;
      expect(() => parse(m), throwsA(isA<DescriptorException>()));
    });

    test('不是对象、不是 JSON 都拒绝', () {
      expect(
        () => PluginDescriptor.parse('[]'),
        throwsA(isA<DescriptorException>()),
      );
      expect(
        () => PluginDescriptor.parse('{'),
        throwsA(isA<DescriptorException>()),
      );
    });
  });

  group('PLG14（契约部分）：描述符拿不到 Vault/SSH 私钥/代理口令/目录 token', () {
    test('权限清单是封闭的，没有任何读取凭据或执行命令的项', () {
      final names = Permission.values.map((p) => p.wire).join(' ');
      for (final forbidden in [
        'vault',
        'key',
        'password',
        'token',
        'exec',
        'shell',
        'file',
        'clipboard',
        'known_hosts',
      ]) {
        expect(names, isNot(contains(forbidden)), reason: forbidden);
      }
    });
  });

  group('PLG02 版本协商', () {
    test('API major 不一致：拒绝，不冒充成功', () {
      final m = example('mosh-provider.json')..['apiMajor'] = 2;
      expect(
        () => parse(m),
        throwsA(
          isA<DescriptorException>().having(
            (e) => e.message,
            'message',
            contains('major'),
          ),
        ),
      );
    });

    test('插件 minor 比宿主新：不认识的能力被忽略且不可调用', () {
      final m = example('mosh-provider.json')
        ..['apiMinor'] = hostApiMinor + 1
        ..['capabilities'] = ['terminal-session', 'future-capability'];
      final d = parse(m);
      expect(d.capabilities, {Capability.terminalSession});
      expect(d.ignoredNewerCapabilities, {'future-capability'});
    });

    test('同 minor 下出现未知能力：整个描述符拒绝', () {
      final m = example('mosh-provider.json')
        ..['capabilities'] = ['terminal-session', 'future-capability'];
      expect(() => parse(m), throwsA(isA<DescriptorException>()));
    });

    test('调用未声明的能力抛 UnsupportedCapability，不返回空结果', () {
      final binding = ApprovedBinding(
        pluginId: 'example.mosh',
        packageName: 'example.terminal.mosh',
        signingDigest: 'aa',
        capabilities: {Capability.terminalSession},
      );
      expect(
        () => requireCapability(binding, Capability.deviceCatalog),
        throwsA(isA<UnsupportedCapability>()),
      );
      expect(
        () => requireCapability(binding, Capability.terminalSession),
        returnsNormally,
      );
    });
  });

  group('PLG01 注册准入', () {
    final policy = AdmissionPolicy(
      builtinIds: {'builtin.ssh', 'builtin.tailscale'},
      reservedOfficialIds: {
        'official.mosh': {'official-cert'},
      },
    );
    InstalledCandidate apk(
      Map<String, Object?> m, {
      String? package,
      Set<String> signers = const {'cert-a'},
    }) => InstalledCandidate(
      descriptor: parse(m),
      installedPackage: package ?? m['packageName'] as String?,
      actualSignerDigests: signers,
    );
    Map<String, Object?> mosh({String id = 'example.mosh', String? package}) =>
        example('mosh-provider.json')
          ..['pluginId'] = id
          ..['packageName'] = package ?? 'example.terminal.mosh';

    test('外部包不能占用内置 ID 或 builtin. 前缀', () {
      for (final id in ['builtin.ssh', 'builtin.anything']) {
        final result = policy.evaluate(
          apk(mosh(id: id)),
          alreadyRegistered: {},
          approvals: [],
        );
        expect(result, isA<Rejected>(), reason: id);
      }
    });

    test('登记过的官方 ID 被别的证书声称：拒绝', () {
      final result = policy.evaluate(
        apk(mosh(id: 'official.mosh')),
        alreadyRegistered: {},
        approvals: [],
      );
      expect(result, isA<Rejected>());
    });

    test('ID 或包名已被占用：新来的被拒绝，不遮蔽已有 provider', () {
      final existing = apk(mosh());
      final sameId = apk(mosh(package: 'other.package'));
      final samePackage = apk(mosh(id: 'example.mosh2'));
      for (final c in [sameId, samePackage]) {
        final result = policy.evaluate(
          c,
          alreadyRegistered: {'example.mosh': existing},
          approvals: [],
        );
        expect(result, isA<Rejected>());
      }
    });

    test('单独安装的包自称 bundled：拒绝，不能跳过批准和证书核验', () {
      final m = mosh(id: 'example.fake_builtin')
        ..['deployment'] = 'bundled'
        ..remove('serviceClass');
      final result = policy.evaluate(
        apk(m, package: 'example.terminal.mosh'),
        alreadyRegistered: {},
        approvals: [],
      );
      expect(result, isA<Rejected>());
    });

    test('描述符自称的包名与实际安装包不一致：拒绝', () {
      final result = policy.evaluate(
        apk(mosh(), package: 'evil.package'),
        alreadyRegistered: {},
        approvals: [],
      );
      expect(result, isA<Rejected>());
    });
  });

  group('独立签名授权与换签', () {
    final policy = AdmissionPolicy(
      builtinIds: {'builtin.ssh'},
      debugSignerDigests: {'debug-cert'},
    );
    final descriptor = parse(example('mosh-provider.json'));
    InstalledCandidate installed(Set<String> signers) => InstalledCandidate(
      descriptor: descriptor,
      installedPackage: 'example.terminal.mosh',
      actualSignerDigests: signers,
    );
    final approval = ApprovedBinding(
      pluginId: 'example.mosh',
      packageName: 'example.terminal.mosh',
      signingDigest: 'author-cert',
      capabilities: {Capability.terminalSession},
    );

    test('首次安装：需要用户批准，批准前不能进入 Ready', () {
      expect(
        policy.evaluate(
          installed({'author-cert'}),
          alreadyRegistered: {},
          approvals: [],
        ),
        isA<NeedsApproval>(),
      );
    });

    test('作者用自己的证书签名、用户批准过：准入，无需共享宿主私钥', () {
      expect(
        policy.evaluate(
          installed({'author-cert'}),
          alreadyRegistered: {},
          approvals: [approval],
        ),
        isA<Admitted>(),
      );
    });

    test('更新后证书变了：禁用并要求重新核验，不自动接受', () {
      expect(
        policy.evaluate(
          installed({'attacker-cert'}),
          alreadyRegistered: {},
          approvals: [approval],
        ),
        isA<Rejected>(),
      );
    });

    test('新版本申请了批准之外的能力：重新批准', () {
      final wider = ApprovedBinding(
        pluginId: 'example.mosh',
        packageName: 'example.terminal.mosh',
        signingDigest: 'author-cert',
        capabilities: {},
      );
      expect(
        policy.evaluate(
          installed({'author-cert'}),
          alreadyRegistered: {},
          approvals: [wider],
        ),
        isA<NeedsApproval>(),
      );
    });

    test('release 宿主不接受 debug 证书；开发构建才放行到批准环节', () {
      expect(
        policy.evaluate(
          installed({'debug-cert'}),
          alreadyRegistered: {},
          approvals: [],
        ),
        isA<Rejected>(),
      );
      final dev = AdmissionPolicy(
        builtinIds: {'builtin.ssh'},
        debugSignerDigests: {'debug-cert'},
        allowDebugSigners: true,
      );
      expect(
        dev.evaluate(
          installed({'debug-cert'}),
          alreadyRegistered: {},
          approvals: [],
        ),
        isA<NeedsApproval>(),
      );
    });
  });

  group('路由能力：插件不能继承不存在的路由', () {
    final mosh = parse(example('mosh-provider.json'));
    final uu = parse(example('uu-adapter.json'));

    test('Mosh（UDP）要求 SOCKS 或跳板：bootstrap 前就拒绝', () {
      for (final r in [
        RequestedRoute.socks5Connect,
        RequestedRoute.proxyJump,
        RequestedRoute.socks5ProxyJump,
      ]) {
        expect(
          checkRoute(mosh, TransportKind.udp, r),
          isA<RouteUnsupported>(),
          reason: '$r',
        );
      }
      expect(
        checkRoute(mosh, TransportKind.udp, RequestedRoute.systemDefault),
        isA<RouteAllowed>(),
      );
    });

    test('外部 App 要求整次远控走 SOCKS：返回 UNSUPPORTED，不用"已拉起"掩盖', () {
      expect(
        checkRoute(
          uu,
          TransportKind.providerManaged,
          RequestedRoute.socks5Connect,
        ),
        isA<RouteUnsupported>(),
      );
      expect(
        checkRoute(
          uu,
          TransportKind.providerManaged,
          RequestedRoute.systemDefault,
        ),
        isA<RouteAllowed>(),
      );
    });

    test('字节流 provider 没声明跳板：拒绝', () {
      final m = example('mosh-provider.json')
        ..['supportedRoutes'] = ['system-default', 'socks5-connect'];
      final d = parse(m);
      expect(
        checkRoute(d, TransportKind.byteStream, RequestedRoute.proxyJump),
        isA<RouteUnsupported>(),
      );
      expect(
        checkRoute(d, TransportKind.byteStream, RequestedRoute.socks5Connect),
        isA<RouteAllowed>(),
      );
    });
  });

  group('三类会话分型与代次', () {
    test('外部拉起没有"已连接"状态', () {
      final names = ExternalLaunchPhase.values.map((p) => p.name);
      expect(names.where((n) => n.toLowerCase().contains('connect')), isEmpty);
      expect(
        ExternalLaunchPhase.launchedUnverified.name,
        contains('Unverified'),
      );
    });

    test('旧代次或乱序事件被丢弃，已停止的会话不会复活', () {
      var s = const SessionState(2, 5, SessionPhase.closed);
      s = s.apply(1, 99, SessionPhase.active); // 旧代次
      s = s.apply(2, 5, SessionPhase.active); // 序号没增
      s = s.apply(2, 4, SessionPhase.active); // 迟到
      expect(s.phase, SessionPhase.closed);
      s = s.apply(2, 6, SessionPhase.interrupted);
      expect(s.phase, SessionPhase.interrupted);
    });

    test('会话类型互不兼容：外部拉起不是终端会话', () {
      const attempt = ExternalLaunchAttempt(
        'h1',
        'example.uuremote',
        SessionState(1, 0, ExternalLaunchPhase.launchedUnverified),
      );
      const SessionKind kind = attempt;
      expect(kind, isNot(isA<TerminalSessionRef>()));
    });
  });

  group('DEV01 设备只由用户显式关联', () {
    const tailscale = ProviderDeviceRef(
      providerId: 'builtin.tailscale',
      refId: 'node-1',
      displayName: 'laptop',
      addresses: ['100.64.0.1'],
    );
    const rustdesk = ProviderDeviceRef(
      providerId: 'example.rustdesk',
      refId: '123456789',
      displayName: 'laptop',
      addresses: ['100.64.0.1'],
    );

    test('同名同 IP 不同 provider：不是同一个引用，也不会自动合并', () {
      expect(tailscale == rustdesk, isFalse);
      final links = DeviceLinks();
      expect(links.records, isEmpty);
      expect(links.recordOf(tailscale), isNull);
    });

    test('用户显式关联后形成记录；解除后各自引用原样保留', () {
      final links = DeviceLinks();
      final record = links.linkByUser([tailscale, rustdesk]);
      expect(links.recordOf(rustdesk)?.id, record.id);
      links.unlink(record.id);
      expect(links.recordOf(tailscale), isNull);
      expect(tailscale.refId, 'node-1');
    });

    test('同一 provider 的两条引用不能关联；已关联的引用不能再被别的记录抢走', () {
      final links = DeviceLinks();
      const other = ProviderDeviceRef(
        providerId: 'builtin.tailscale',
        refId: 'node-2',
        displayName: 'x',
      );
      expect(() => links.linkByUser([tailscale, other]), throwsArgumentError);
      links.linkByUser([tailscale, rustdesk]);
      const uu = ProviderDeviceRef(
        providerId: 'example.uuremote',
        refId: 'u1',
        displayName: 'laptop',
      );
      expect(() => links.linkByUser([rustdesk, uu]), throwsStateError);
    });
  });
}
