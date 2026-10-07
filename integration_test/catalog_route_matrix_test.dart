// R15 设备验证：同一台目录设备经本地 SOCKS / 远程 SOCKS / 跳板 / 代理入口 + 跳板连接，
// 分别用普通 SSH 和 Tailscale SSH 登录；再看目录、API、路线、认证各层的错误分不分得开，API 坏了主机和连接受不受影响，
// 各层的 secret 有没有串到别的层。
//
// 这不是 CI 测试。环境是 tool/tailscale-ssh-fixture/headscale 的 `./up.sh routes`（Headscale + 4 个真 tailscaled），
// 用同目录的 route-matrix.sh 跑：它把 ../.run/headscale.json 转成 R15_CONFIG、做 adb reverse、替你批准 check。
// 目录 API 是本进程里的假服务器，设备列表是 Headscale 里那几台节点——证明的是 App 怎么用目录，不是 Tailscale 的真实响应。
//
// 只拨 127.0.0.1：拨号器闸住了别的地址。开发机可能就在真实 tailnet 上，100.x 一律交给代理或跳板去连。
// 输出以 "R15 " 开头的行进测试输出和 logcat，作为证据。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:netcatty_mobile/application/connection_diagnosis.dart';
import 'package:netcatty_mobile/application/tailscale_catalog_access.dart';
import 'package:netcatty_mobile/application/tailscale_catalog_import.dart';
import 'package:netcatty_mobile/application/tailscale_catalog_provider.dart';
import 'package:netcatty_mobile/application/tailscale_catalog_refresh.dart';
import 'package:netcatty_mobile/application/vault_controller.dart';
import 'package:netcatty_mobile/domain/connection_route.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/models/vault.dart';
import 'package:netcatty_mobile/domain/plugins/builtin_plugins.dart';
import 'package:netcatty_mobile/domain/tailscale_ssh.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_login_watch.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/infrastructure/tailscale/catalog_cache.dart';
import 'package:netcatty_mobile/infrastructure/tailscale/catalog_cache_repository.dart';
import 'package:netcatty_mobile/infrastructure/tailscale/catalog_secret_store.dart';
import 'package:netcatty_mobile/infrastructure/tailscale/tailscale_api.dart';
import 'package:netcatty_mobile/infrastructure/transport/proxy_transport.dart';
import 'package:path_provider/path_provider.dart';
import 'package:netcatty_mobile/infrastructure/terminal/ghostty_terminal_adapter.dart';

const _rawConfig = String.fromEnvironment('R15_CONFIG');

final _rnd = Random.secure();
String _hex(int bytes) => List.generate(
    bytes, (_) => _rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

/// 目录这一层的 secret 在运行时现生成：编进测试包的东西（fixture 口令）会出现在 APK 里，
/// 拿它们搜私有目录分不清是 App 写的还是代码本身；这几个只可能是 App 运行时写下的。
final oauthSecret = 'tskey-client-r15-${_hex(12)}';
final pastedToken = 'tskey-api-r15-${_hex(12)}';
const catalogA = 'r15-a';
const catalogB = 'r15-b';

void report(String key, Object? value) => _print('R15 $key=$value');
late final DebugPrintCallback _print;
final printed = <String>[];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // 收集测试期间所有 debugPrint：最后搜一遍 secret。原样照打，不影响证据输出。
  _print = debugPrint;
  debugPrint = (message, {wrapWidth}) {
    if (message != null) printed.add(message);
    _print(message, wrapWidth: wrapWidth);
  };

  if (_rawConfig.isEmpty) {
    test('R15 环境', () {},
        skip:
            '没有 R15_CONFIG：用 tool/tailscale-ssh-fixture/headscale/route-matrix.sh 跑');
    return;
  }
  final cfg = _Config(jsonDecode(utf8.decode(base64.decode(_rawConfig)))
      as Map<String, dynamic>);

  late Tap
      localSocks; // 本地 SOCKS：ts-socks（userspace tailscaled，扮演手机上的 TailSocks）
  late Tap relaySocks; // 远程 SOCKS：ts-relay（tag:relay，dante 要口令）
  late Tap bastion; // 跳板机：ts-jump 的 OpenSSH
  late FakeCatalogApi api;
  late ProviderContainer container;
  late VaultController vault;
  late TailscaleCatalogProvider catalog;
  late SshService ssh;
  late String serverId; // 从目录导入的 ts-server
  late String jumpTsId; // 从目录导入的 ts-jump（代理入口 + 跳板时用它的 100.x）
  const bastionId = 'r15-bastion'; // 手动建的跳板机（经 127.0.0.1 直连 ts-jump）
  final dials = <String>[];
  var sessionSeq = 0;

  Future<Socket> guardedDial(String host, int port, {Duration? timeout}) {
    dials.add('$host:$port');
    if (host != '127.0.0.1') {
      return Future.error(
          SocketException('R15 拨号闸：只许连 127.0.0.1，拒绝 $host:$port'));
    }
    return Socket.connect(host, port, timeout: timeout);
  }

  /// 「用户核对过指纹」：按 up.sh 从容器里读出的主机密钥比对。经 127.0.0.1 的跳板机就是 ts-jump。
  final fingerprintsSeen = <String>[];
  Future<bool> verify(
      HostProfile host, String algorithm, String fingerprint) async {
    final expected = switch (host.hostname) {
      final h when h == cfg.serverIp => cfg.serverFingerprints,
      final h when h == cfg.jumpIp || h == '127.0.0.1' => cfg.jumpFingerprints,
      _ => const <String>[],
    };
    fingerprintsSeen.add('${host.label} $algorithm');
    return expected.contains(fingerprint);
  }

  Future<VaultData> current() => vault.ready();
  Future<HostProfile> hostById(String id) async =>
      (await current()).hosts.singleWhere((h) => h.id == id);

  Future<Outcome> connect(String id, {HostKeyVerifier? verifyHostKey}) async {
    final data = await current();
    final host = data.hosts.singleWhere((h) => h.id == id);
    final dialed = dials.length;
    final prompts = <TailscaleCheckPrompt>[];
    final attempt = ConnectionAttempt(onCheckPrompt: (prompt) {
      if (prompt == null) return;
      prompts.add(prompt);
      // 批准由 route-matrix.sh 在 Headscale 里做；这里只报出来，照常等。
      report(
          'check.waiting',
          '${prompt.hostLabel} hop ${prompt.hop + 1}/${prompt.hopCount}, '
              'link=${prompt.link == null ? '不合规，不打开' : '合规'}, 来源=${prompt.sourceNode}');
    });
    try {
      final session = await ssh.connect(
        terminal: GhosttyTerminalAdapter(),
        sessionId: 'r15-${sessionSeq++}',
        host: host,
        hosts: data.hosts,
        keys: data.keys,
        proxyProfiles: data.proxyProfiles,
        verifyHostKey: verifyHostKey ?? verify,
        attempt: attempt,
      );
      try {
        final out = utf8
            .decode(await session.sshClient!
                .run(r'echo "from=${SSH_CLIENT%% *} user=$(whoami)"'))
            .trim();
        return Outcome(
            output: out, dials: dials.sublist(dialed), prompts: prompts);
      } finally {
        await session.close();
      }
    } catch (error) {
      return Outcome(
          error: error, dials: dials.sublist(dialed), prompts: prompts);
    }
  }

  /// 改主机的路线和登录方式，和用户在编辑器里改一样：只动这几个字段，目录绑定原样留着。
  Future<void> configure(String id, Route route, Login login,
      {int? port, String? password, String? relayPassword}) {
    return vault.updateHost(id, (host) {
      final data = {...host.data}
        // 地址也复原：错误分层里有一条把地址改成了代理连不到的名字。
        ..['hostname'] = cfg.serverIp
        ..remove('proxyConfig')
        ..remove('proxyProfileId')
        ..remove('hostChain')
        ..remove(sshLoginModeKey);
      ProxyConfig local() => ProxyConfig(
          type: ProxyType.socks5, host: '127.0.0.1', port: localSocks.port);
      switch (route) {
        case Route.localSocks:
          data['proxyConfig'] = local().toJson();
        case Route.remoteSocks:
          data['proxyConfig'] = ProxyConfig(
            type: ProxyType.socks5,
            host: '127.0.0.1',
            port: relaySocks.port,
            username: cfg.relayUser,
            password: relayPassword ?? cfg.relayPassword,
          ).toJson();
        case Route.jump:
          data['hostChain'] = {
            'hostIds': [bastionId]
          };
        case Route.proxyThenJump:
          data['proxyConfig'] = local().toJson();
          data['hostChain'] = {
            'hostIds': [jumpTsId]
          };
      }
      switch (login) {
        case Login.ordinary:
          data['port'] = port ?? 2222;
          data['username'] = cfg.ordinaryUser;
          data['authMethod'] = 'password';
          data['password'] = password ?? cfg.ordinaryPassword;
        case Login.tailscaleAccept || Login.tailscaleCheck:
          data['port'] = port ?? 22;
          data['username'] =
              login == Login.tailscaleAccept ? 'acceptuser' : 'checkuser';
          data[sshLoginModeKey] = 'tailscale';
        // 普通 SSH 的密码照样存着：Tailscale 模式下不发（R14 在仿制服务器上已证实）。
      }
      return HostProfile(data);
    });
  }

  String fingerprintOf(CatalogBinding? b) =>
      b == null ? 'null' : '${b.catalogId}/${b.deviceId}/${b.appliedAddress}';

  setUpAll(() async {
    localSocks = await Tap.start('本地SOCKS', cfg.localSocksPort);
    relaySocks = await Tap.start('远程SOCKS', cfg.relayPort);
    bastion = await Tap.start('跳板机', cfg.jumpPort);
    api = await FakeCatalogApi.start(oauthSecret, pastedToken);
    api.devices = [
      _device('n-server', 'ts-server', cfg.serverIp, tags: ['tag:server']),
      _device('n-socks', 'ts-socks', cfg.socksNodeIp),
      _device('n-relay', 'ts-relay', cfg.relayNodeIp, tags: ['tag:relay']),
      _device('n-jump', 'ts-jump', cfg.jumpIp),
    ];
    final http.Client client = http.Client();
    container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(await VaultRepository.open()),
      tailscaleCatalogAccessProvider.overrideWithValue(TailscaleCatalogAccess(
        const TailscaleCatalogSecretStore(FlutterSecureCatalogBackend()),
        // ignore: invalid_use_of_visible_for_testing_member
        (credential) =>
            TailscaleCatalogClient.fixture(client, api.origin, credential),
      )),
    ]);
    vault = container.read(vaultControllerProvider.notifier);
    catalog = container.read(tailscaleCatalogProvider);
    ssh = SshService(
        dialer: guardedDial, tailscaleCheckWait: const Duration(minutes: 3));
    // 测试包和正式 App 同一个包名：清掉上一轮可能留下的主机和目录来源，从空保险库开始。
    // 先等 provider 建好时自动开始的加载做完，不然它晚到的结果会把清空盖回去。
    await vault.ready();
    await vault.replace(VaultData.empty());
    for (final id in [catalogA, catalogB]) {
      await catalog.removeSource(id);
    }
    report(
        'env',
        'server=${cfg.serverIp} socksNode=${cfg.socksNodeIp} relayNode=${cfg.relayNodeIp} '
            'jump=${cfg.jumpIp} taps: local=${localSocks.port} relay=${relaySocks.port} bastion=${bastion.port}');
  });

  tearDownAll(() async {
    // 收拾干净：本机保存的目录凭据、缓存、主机都删掉（测试结束 flutter 也会卸载这个包）。
    for (final id in [catalogA, catalogB]) {
      await catalog.removeSource(id);
    }
    await vault.replace(VaultData.empty());
    container.dispose();
    await api.close();
    for (final tap in [localSocks, relaySocks, bastion]) {
      await tap.close();
    }
  });

  testWidgets('TSC01 读目录：只发换 token 和列设备两种请求，只要 devices:core:read', (_) async {
    await catalog.addSource(catalogId: catalogA, label: 'R15 fixture');
    final outcome = await catalog.refreshWithOAuthClient(
      catalogA,
      OAuthClientCredential(clientId: 'r15-client', clientSecret: oauthSecret),
      persist: true,
    );
    expect(outcome.error, isNull, reason: '${outcome.error}');
    expect(outcome.scope, TokenScopeStatus.deviceReadOnly);
    expect(outcome.persistRefusal, isNull, reason: '服务器回报只读，应当保存 client');
    expect(outcome.cache.devices.keys,
        unorderedEquals(['n-server', 'n-socks', 'n-relay', 'n-jump']));
    final calls = api.requests.map((r) => '${r.method} ${r.path}').toList();
    report('TSC01.requests', calls);
    expect(
        calls, ['POST /api/v2/oauth/token', 'GET /api/v2/tailnet/-/devices']);
    final form = Uri.splitQueryString(api.requests.first.body);
    expect(form['grant_type'], 'client_credentials');
    expect(form['scope'], 'devices:core:read');
    expect(api.requests.first.headers.containsKey('authorization'), isFalse);
    expect(api.requests.last.headers['authorization'],
        'Bearer ${api.issued.single}');
    expect(api.requests.last.body, isEmpty);
  });

  testWidgets('导入：同一台设备成为一台主机，不连接、不写指纹', (_) async {
    final before = await current();
    final cache =
        (await container.read(catalogCacheRepositoryProvider).load(catalogA))!;
    var seq = 0;
    String newId() => 'r15-imported-${seq++}';
    final server = buildCatalogImport(
      cache: cache,
      deviceIds: ['n-server'],
      options: CatalogImportOptions(
        username: cfg.ordinaryUser,
        port: 2222,
        authMethod: HostAuthMethod.password,
        proxyConfig: ProxyConfig(
            type: ProxyType.socks5, host: '127.0.0.1', port: localSocks.port),
      ),
      vault: before,
      newId: newId,
    );
    final jump = buildCatalogImport(
      cache: cache,
      deviceIds: ['n-jump'],
      options: const CatalogImportOptions(
          username: 'jumper', authMethod: HostAuthMethod.password),
      vault: before,
      newId: newId,
    );
    final added = await vault
        .addHosts([...server.hosts, ...jump.hosts], skip: alreadyImported);
    expect(added, hasLength(2));
    serverId = added.first.id;
    jumpTsId = added.last.id;
    // 批量导入不填密码，导入后在编辑器里逐台填（R13 的设计）。
    await vault.patchHost(serverId, {'password': cfg.ordinaryPassword});
    await vault.patchHost(jumpTsId, {'password': cfg.jumpPassword});
    await vault.upsertHost(HostProfile({
      'id': bastionId,
      'label': 'bastion',
      'hostname': '127.0.0.1',
      'port': bastion.port,
      'username': cfg.jumpUser,
      'password': cfg.jumpPassword,
      'authMethod': 'password',
      'protocol': 'ssh',
    }));
    final after = await current();
    final host = after.hosts.singleWhere((h) => h.id == serverId);
    report('import.server',
        '${host.label} ${host.hostname}:${host.port} binding=${fingerprintOf(CatalogBinding.of(host))}');
    expect(host.hostname, cfg.serverIp);
    expect(CatalogBinding.of(host)!.deviceId, 'n-server');
    expect(dials, isEmpty, reason: '导入不连接');
    expect(after.extras['knownHosts'], before.extras['knownHosts'],
        reason: '导入不写指纹');
    expect(
        localSocks.connections + relaySocks.connections + bastion.connections,
        0);
  });

  // 每格：路线 × 登录方式 → 期望。普通 SSH（2222）经 userspace tailscaled 转给本机端口，来源都是 127.0.0.1；
  // Tailscale SSH（22）认的是承载连接的节点：本地 SOCKS 是 ts-socks，跳板是 ts-jump，远程 SOCKS 的 tag:relay 不在 ssh 规则里。
  testWidgets('路线矩阵：同一台设备、四条路线、两种登录', (_) async {
    final local = localSocks.port, relay = relaySocks.port, jump = bastion.port;
    final cells = [
      (
        Route.localSocks,
        Login.ordinary,
        'from=127.0.0.1 user=ordinary',
        [local]
      ),
      (
        Route.localSocks,
        Login.tailscaleAccept,
        'from=${cfg.socksNodeIp} user=acceptuser',
        [local]
      ),
      (
        Route.remoteSocks,
        Login.ordinary,
        'from=127.0.0.1 user=ordinary',
        [relay]
      ),
      (Route.remoteSocks, Login.tailscaleAccept, null, [relay]),
      (Route.jump, Login.ordinary, 'from=127.0.0.1 user=ordinary', [jump]),
      (
        Route.jump,
        Login.tailscaleAccept,
        'from=${cfg.jumpIp} user=acceptuser',
        [jump]
      ),
      (
        Route.proxyThenJump,
        Login.ordinary,
        'from=127.0.0.1 user=ordinary',
        [local]
      ),
      (
        Route.proxyThenJump,
        Login.tailscaleAccept,
        'from=${cfg.jumpIp} user=acceptuser',
        [local]
      ),
    ];
    final binding = fingerprintOf(CatalogBinding.of(await hostById(serverId)));
    final failures = <String>[];
    for (final (route, login, want, ports) in cells) {
      await configure(serverId, route, login);
      final host = await hostById(serverId);
      expect(fingerprintOf(CatalogBinding.of(host)), binding,
          reason: '改路线不动目录绑定');
      final result = await connect(serverId);
      final dialed = result.dials.toSet().toList();
      final line =
          '${route.name}/${login.name} → ${result.describe()} 拨号=$dialed';
      report('matrix', line);
      final okDial =
          listEquals(dialed, ports.map((p) => '127.0.0.1:$p').toList());
      if (want == null) {
        // 远程 SOCKS 那台是 tag:relay，ssh 规则只放行用户 fixture 的设备。
        final cause = result.error is RouteHopException
            ? (result.error as RouteHopException).cause
            : result.error;
        if (cause is! TailscaleLoginDenied ||
            !'${cause.serverMessage}'
                .contains('tailnet policy does not permit') ||
            !okDial) {
          failures.add(line);
        } else {
          report('matrix.hint', connectionHint(result.error!));
        }
      } else if (result.output != want || !okDial) {
        failures.add(line);
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
    // 全程只用 SSH 主机自己的凭据：远程 SOCKS 的口令只该出现在去远程 SOCKS 的那条连接上。
    expect(relaySocks.contains(cfg.relayPassword), isTrue,
        reason: '对照：SOCKS5 口令本来就是明文（SOX04），tap 应当看得到');
    expect(localSocks.contains(cfg.relayPassword), isFalse);
    expect(bastion.contains(cfg.relayPassword), isFalse);
    report('matrix.fingerprintsChecked', fingerprintsSeen.toSet().toList());
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('Tailscale check：经本地 SOCKS 和经跳板各一次，来源节点说对、批准后才进去', (_) async {
    for (final (route, wantFrom, wantSource) in [
      (
        Route.localSocks,
        cfg.socksNodeIp,
        '代理出口所在的节点（代理地址 127.0.0.1:${localSocks.port}）'
      ),
      (Route.jump, cfg.jumpIp, '跳板机“bastion”所在的节点'),
    ]) {
      await configure(serverId, route, Login.tailscaleCheck);
      final result = await connect(serverId);
      report('check.${route.name}',
          '${result.describe()} prompts=${result.prompts.length}');
      expect(result.output, 'from=$wantFrom user=checkuser',
          reason: '${result.error}');
      expect(result.prompts, hasLength(1));
      final prompt = result.prompts.single;
      expect(prompt.sourceNode, contains(wantSource));
      expect(prompt.hop, prompt.hopCount - 1, reason: 'check 出在目标这一跳');
      expect(prompt.link, isNull, reason: 'Headscale 的链接不在白名单，App 不打开，只等');
    }
  }, timeout: const Timeout(Duration(minutes: 8)));

  testWidgets('TSC04 刷新目录不动路线、用户名、登录方式和密码', (_) async {
    await configure(serverId, Route.proxyThenJump, Login.tailscaleAccept);
    final before = jsonEncode((await hostById(serverId)).data);
    final outcome = await catalog.refreshSaved(catalogA);
    expect(outcome.error, isNull, reason: '${outcome.error}');
    expect(outcome.hostsReaddressed, 0);
    expect(jsonEncode((await hostById(serverId)).data), before);
    report('TSC04', '刷新后主机一字不差（路线=代理入口+跳板，登录=Tailscale SSH）');
  });

  testWidgets('TSC06 目录状态和能不能连是两回事', (_) async {
    await configure(serverId, Route.localSocks, Login.ordinary);
    final caches = container.read(catalogCacheRepositoryProvider);
    Future<HostCatalogStatus> status() async => catalogStatusOf(
        await hostById(serverId), {catalogA: (await caches.load(catalogA))!})!;

    // ① 完整列表里没有它：目录标「不见了」，主机不删、照样连得上。
    final full = [...api.devices];
    api.devices = full.where((d) => d['id'] != 'n-server').toList();
    final before = jsonEncode((await hostById(serverId)).data);
    expect((await catalog.refreshSaved(catalogA)).error, isNull);
    expect((await status()).presence, CatalogPresence.missing);
    expect(jsonEncode((await hostById(serverId)).data), before);
    var result = await connect(serverId);
    report('TSC06.missing',
        '目录=${(await status()).presence.name} 连接=${result.describe()}');
    expect(result.output, 'from=127.0.0.1 user=ordinary');

    // ② 目录说「未连接控制面」：只是目录状态，连接照常。
    api.devices = [
      for (final d in full)
        d['id'] == 'n-server' ? {...d, 'connectedToControl': false} : d,
    ];
    expect((await catalog.refreshSaved(catalogA)).error, isNull);
    final s = await status();
    expect(s.presence, CatalogPresence.listed);
    expect(s.connectedToControl, isFalse);
    result = await connect(serverId);
    report('TSC06.notConnectedToControl',
        '目录=listed connectedToControl=false 连接=${result.describe()}');
    expect(result.output, 'from=127.0.0.1 user=ordinary');
    api.devices = full;
    expect((await catalog.refreshSaved(catalogA)).error, isNull);
    expect((await status()).connectedToControl, isTrue);
  });

  testWidgets('错误分层：路线配置 / 代理 / 跳板转发 / 指纹 / 登录 / Tailscale 策略 各是各的', (_) async {
    // 不管中间哪条失败，都把主机和跳板机恢复成能连的样子，后面的用例要用。
    addTearDown(() async {
      await vault.patchHost(bastionId, {'password': cfg.jumpPassword});
      await configure(serverId, Route.localSocks, Login.ordinary);
    });
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = closed.port;
    await closed.close();
    final cases = <(String, Future<void> Function(), Layer, int?)>[
      (
        '跳板机不在保险库',
        () async {
          await configure(serverId, Route.jump, Login.ordinary);
          await vault.patchHost(serverId, {
            'hostChain': {
              'hostIds': ['r15-no-such-host']
            }
          });
        },
        Layer.routeConfig,
        null
      ),
      (
        '代理端口没人听',
        () async {
          await configure(serverId, Route.localSocks, Login.ordinary);
          await vault.patchHost(serverId, {
            'proxyConfig': ProxyConfig(
                    type: ProxyType.socks5, host: '127.0.0.1', port: closedPort)
                .toJson(),
          });
        },
        Layer.network,
        0
      ),
      (
        '远程 SOCKS 口令错',
        () => configure(serverId, Route.remoteSocks, Login.ordinary,
            relayPassword: 'wrong-${_hex(4)}'),
        Layer.proxy,
        0
      ),
      (
        '经本地 SOCKS，目标端口没开',
        () => configure(serverId, Route.localSocks, Login.ordinary, port: 2299),
        Layer.proxy,
        0
      ),
      // 目录给的 MagicDNS 名代理那边用不了。具体回什么码看代理怎么解析：开发机开着 fake-ip 类代理时，
      // 容器里的名字都解析成 198.18.x，dante 按规则拒（状态码 2）；正常环境下是解析失败（状态码 4）。只断言是代理这一层。
      // 不走本地 SOCKS：tailscaled 连 tailnet 以外的名字会经开发机网络出去，fake-ip 代理先接下再断开，看着像 SSH 阶段的问题。
      (
        '经远程 SOCKS，目标是代理那边连不到的名字',
        () async {
          await configure(serverId, Route.remoteSocks, Login.ordinary);
          await vault
              .patchHost(serverId, {'hostname': 'ts-server.r15.invalid'});
        },
        Layer.proxy,
        0
      ),
      (
        '跳板机转发不到目标端口',
        () => configure(serverId, Route.jump, Login.ordinary, port: 2299),
        Layer.jumpForward,
        0
      ),
      (
        '跳板机密码错',
        () async {
          await configure(serverId, Route.jump, Login.ordinary);
          await vault.patchHost(bastionId, {'password': 'wrong-${_hex(4)}'});
        },
        Layer.sshAuth,
        0
      ),
      (
        '目标密码错（经代理入口 + 跳板）',
        () async {
          await vault.patchHost(bastionId, {'password': cfg.jumpPassword});
          await configure(serverId, Route.proxyThenJump, Login.ordinary,
              password: 'wrong-${_hex(4)}');
        },
        Layer.sshAuth,
        1
      ),
      (
        'Tailscale 策略不放行（经远程 SOCKS）',
        () => configure(serverId, Route.remoteSocks, Login.tailscaleAccept),
        Layer.tailscalePolicy,
        0
      ),
    ];
    final hints = <Layer, Set<String>>{};
    final failures = <String>[];
    for (final (name, arrange, want, hop) in cases) {
      await arrange();
      final result = await connect(serverId);
      final error = result.error;
      final layer = error == null ? null : layerOf(error);
      final at = error is RouteHopException ? error.hop : null;
      final hint = error == null ? null : connectionHint(error);
      report('layers',
          '$name → ${layer?.name} 第${at == null ? '-' : at + 1}跳：${result.describe()} | 提示：$hint');
      if (layer != want || at != hop || hint == null) {
        failures.add('$name：得到 ${layer?.name} hop=$at');
      }
      if (hint != null) hints.putIfAbsent(want, () => {}).add(hint);
      if (want == Layer.routeConfig && result.dials.isNotEmpty) {
        failures.add('$name：配置错还拨了号 ${result.dials}');
      }
    }
    // 指纹不对：在发任何登录信息前断开。用一个只认错指纹的核对函数。
    await configure(serverId, Route.localSocks, Login.ordinary);
    final rejected =
        await connect(serverId, verifyHostKey: (_, __, ___) async => false);
    final layer = rejected.error == null ? null : layerOf(rejected.error!);
    final hostKeyHint =
        rejected.error == null ? null : connectionHint(rejected.error!);
    report('layers',
        '指纹对不上 → ${layer?.name}：${rejected.describe()} | 提示：$hostKeyHint');
    if (layer != Layer.hostKey || hostKeyHint == null) {
      failures.add('指纹对不上：得到 ${layer?.name}');
    }
    if (hostKeyHint != null) {
      hints.putIfAbsent(Layer.hostKey, () => {}).add(hostKeyHint);
    }

    expect(failures, isEmpty, reason: failures.join('\n'));
    // 不同层给的下一步不能是同一句话（同一层里可以相同）。
    final all = hints.values.expand((h) => h).toList();
    expect(all.toSet().length, greaterThanOrEqualTo(hints.length));
    for (final a in hints.keys) {
      for (final b in hints.keys) {
        if (a != b) {
          expect(hints[a]!.intersection(hints[b]!), isEmpty,
              reason: '$a 和 $b 给了同一句提示');
        }
      }
    }
  }, timeout: const Timeout(Duration(minutes: 8)));

  testWidgets('TSC10 第二个来源报同样的设备：不合并，移除它不动别的主机', (_) async {
    await catalog.addSource(catalogId: catalogB, label: 'R15 alias');
    final outcome = await catalog.refreshWithToken(catalogB, pastedToken);
    expect(outcome.error, isNull, reason: '${outcome.error}');
    expect(outcome.scope, TokenScopeStatus.unverified,
        reason: '粘贴的 token 一律「范围未验证」');
    expect(await catalog.hasSavedCredentials(catalogB), isFalse,
        reason: '粘贴的 token 不保存');
    final links = await catalog.links();
    final linked = links.records
        .expand((r) => r.refs)
        .where((r) => r.providerId == BuiltinPlugins.tailscale)
        .map((r) => r.refId)
        .toList();
    report('TSC10.links', linked);
    expect(linked, unorderedEquals(['$catalogA:n-server', '$catalogA:n-jump']),
        reason: '两个来源报出同样的设备 ID，关联仍只认导入时的来源');
    final before =
        jsonEncode((await current()).hosts.map((h) => h.data).toList());
    await catalog.removeSource(catalogB);
    expect(jsonEncode((await current()).hosts.map((h) => h.data).toList()),
        before);
    expect((await connect(serverId)).output, 'from=127.0.0.1 user=ordinary');
  });

  testWidgets('TSC02 API 各种故障：主机和缓存都不动，连接照常', (_) async {
    final caches = container.read(catalogCacheRepositoryProvider);
    String devicesOf(CatalogCache c) => jsonEncode({
          for (final e in c.devices.entries)
            e.key: [e.value.device.addresses, e.value.missing],
        });
    final cases = <(ApiMode, Type)>[
      (ApiMode.unauthorized, TailscaleReauthorizationRequired),
      (ApiMode.forbidden, TailscaleForbidden),
      (ApiMode.rateLimited, TailscaleRateLimited),
      (ApiMode.serverError, TailscaleServerError),
      (ApiMode.malformed, TailscaleMalformedResponse),
      (ApiMode.redirect, TailscaleRedirectRefused),
    ];
    final hosts =
        jsonEncode((await current()).hosts.map((h) => h.data).toList());
    final devices = devicesOf((await caches.load(catalogA))!);
    for (final (mode, type) in cases) {
      api.mode = mode;
      final sent = api.requests.length;
      final outcome = await catalog.refreshSaved(catalogA);
      final calls =
          api.requests.skip(sent).map((r) => '${r.method} ${r.path}').toList();
      report('TSC02.${mode.name}',
          '${outcome.error.runtimeType}: ${outcome.error} 请求=$calls');
      expect(outcome.error.runtimeType, type);
      expect(calls.where((c) => c.startsWith('GET')).length,
          mode == ApiMode.unauthorized ? 2 : 1,
          reason: '401 只受控刷新一次，别的不重试');
      expect(jsonEncode((await current()).hosts.map((h) => h.data).toList()),
          hosts);
      expect(devicesOf((await caches.load(catalogA))!), devices);
    }
    expect(api.redirectFollowed, 0, reason: '不跟随重定向');
    // API 整个停掉：目录读不到，连接根本不经过它。
    api.mode = ApiMode.ok;
    await api.close();
    final down = await catalog.refreshSaved(catalogA);
    report('TSC02.down', '${down.error.runtimeType}: ${down.error}');
    expect(down.error, isA<TailscaleNetworkError>());
    expect(
        jsonEncode((await current()).hosts.map((h) => h.data).toList()), hosts);
    for (final (route, login, want) in [
      (Route.localSocks, Login.ordinary, 'from=127.0.0.1 user=ordinary'),
      (Route.jump, Login.tailscaleAccept, 'from=${cfg.jumpIp} user=acceptuser'),
    ]) {
      await configure(serverId, route, login);
      final result = await connect(serverId);
      report('TSC02.connectWhileApiDown',
          '${route.name}/${login.name} → ${result.describe()}');
      expect(result.output, want);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('TSC09 secret 不穿越层：目录凭据不进 SSH/代理，SSH/代理口令不进目录 API，也不落盘',
      (_) async {
    final catalogSecrets = {
      'OAuth client secret': oauthSecret,
      '粘贴的 token': pastedToken
    };
    for (final (i, token) in api.issued.indexed) {
      catalogSecrets['换来的 access token #$i'] = token;
    }
    final sshSecrets = {
      '普通 SSH 密码': cfg.ordinaryPassword,
      '跳板机密码': cfg.jumpPassword,
      '远程 SOCKS 口令': cfg.relayPassword,
    };
    final leaks = <String>[];
    // ① 网络：目录凭据一个字节都没进过代理和跳板（它们是明文能看到的部分：SOCKS 协商、SSH 版本行和密钥交换）。
    for (final tap in [localSocks, relaySocks, bastion]) {
      for (final MapEntry(key: what, value: secret) in catalogSecrets.entries) {
        if (tap.contains(secret)) leaks.add('$what 出现在去${tap.name}的流量里');
      }
      report('TSC09.tap',
          '${tap.name}: ${tap.connections} 条连接，${tap.sentLength} 字节');
    }
    // ② 目录 API 收到的全部请求里，没有任何 SSH/代理口令，也没有主机地址以外的主机字段。
    for (final request in api.requests) {
      for (final MapEntry(key: what, value: secret) in sshSecrets.entries) {
        if (request.dump.contains(secret)) {
          leaks.add('$what 出现在目录 API 请求 ${request.method} ${request.path} 里');
        }
      }
    }
    report('TSC09.apiRequests', api.requests.length);
    // ③ 私有目录：明文搜全部文件。目录凭据由运行时生成，命中只可能是 App 写的。
    final scan = await scanAppData(
        {...catalogSecrets, ...sshSecrets, '对照：设备名 ts-server': 'ts-server'});
    report(
        'TSC09.files', '${scan.files} 个文件 ${scan.bytes} 字节，跳过 ${scan.skipped}');
    for (final MapEntry(key: what, value: files) in scan.hits.entries) {
      report('TSC09.hit', '$what → $files');
      if (!what.startsWith('对照')) leaks.add('$what 明文出现在 $files');
    }
    expect(scan.hits.keys, contains('对照：设备名 ts-server'),
        reason: '对照：缓存文件里应能搜到设备名，说明真的搜到了');
    // ④ 日志：测试期间所有 debugPrint。
    for (final line in printed) {
      for (final MapEntry(key: what, value: secret)
          in {...catalogSecrets, ...sshSecrets}.entries) {
        if (line.contains(secret)) leaks.add('$what 出现在日志：$line');
      }
    }
    report('TSC09.logLines', printed.length);
    expect(leaks, isEmpty, reason: leaks.join('\n'));
  });
}

enum Route { localSocks, remoteSocks, jump, proxyThenJump }

enum Login { ordinary, tailscaleAccept, tailscaleCheck }

/// 错误落在哪一层。只按 App 实际抛出的类型分，和界面上的提示（connectionHint）同一套依据。
enum Layer {
  routeConfig,
  network,
  proxy,
  jumpForward,
  hostKey,
  sshAuth,
  tailscalePolicy,
  other
}

Layer layerOf(Object error) {
  if (error is RouteConfigException) return Layer.routeConfig;
  final cause = error is RouteHopException ? error.cause : error;
  return switch (cause) {
    TailscaleLoginDenied() => Layer.tailscalePolicy,
    ProxyHandshakeException() => Layer.proxy,
    ConnectStageException() ||
    SocketException() ||
    TimeoutException() =>
      Layer.network,
    SSHHostkeyError() ||
    SSHAuthAbortError(reason: SSHHostkeyError()) =>
      Layer.hostKey,
    SSHAuthFailError() => Layer.sshAuth,
    SSHChannelOpenError() => Layer.jumpForward,
    _ => Layer.other,
  };
}

class Outcome {
  Outcome(
      {this.output, this.error, required this.dials, required this.prompts});
  final String? output;
  final Object? error;
  final List<String> dials;
  final List<TailscaleCheckPrompt> prompts;

  String describe() =>
      error == null ? '成功 $output' : '失败 ${error.runtimeType}: $error';
}

class _Config {
  _Config(this._json);
  final Map<String, dynamic> _json;
  Map<String, dynamic> _m(String k) => _json[k] as Map<String, dynamic>;
  List<String> _fps(String k) =>
      [for (final f in _m(k)['fingerprints'] as List) f as String];

  String get serverIp => _m('server')['ip'] as String;
  List<String> get serverFingerprints => _fps('server');
  String get socksNodeIp => _json['socksNode'] as String;
  String get relayNodeIp => _json['relayNode'] as String;
  String get jumpIp => _m('jump')['ip'] as String;
  List<String> get jumpFingerprints => _fps('jump');
  int get jumpPort => _m('jump')['port'] as int;
  String get jumpUser => _m('jump')['username'] as String;
  String get jumpPassword => _m('jump')['password'] as String;
  int get localSocksPort => _json['localSocksPort'] as int;
  int get relayPort => _m('relay')['port'] as int;
  String get relayUser => _m('relay')['username'] as String;
  String get relayPassword => _m('relay')['password'] as String;
  String get ordinaryUser => _m('ordinary')['username'] as String;
  String get ordinaryPassword => _m('ordinary')['password'] as String;
}

/// 目录里的一台设备，字段照官方 Device schema 的默认字段集。名字用 .invalid：万一哪里拿去解析，也解析不到真东西。
Map<String, Object?> _device(String id, String host, String ip,
        {List<String> tags = const []}) =>
    {
      'id': id,
      'nodeId': 'node-$id',
      'name': '$host.r15.invalid.',
      'hostname': host,
      'addresses': [ip],
      'os': 'linux',
      'user': tags.isEmpty ? 'fixture@' : 'tagged-devices',
      'tags': tags,
      'connectedToControl': true,
      'authorized': true,
    };

int _indexOf(Uint8List haystack, List<int> needle) {
  if (needle.isEmpty) return 0;
  final first = needle.first;
  outer:
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    if (haystack[i] != first) continue;
    for (var j = 1; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/// 本机端口转发，记下 App 发往上游的全部字节（App → 代理 / 跳板机这一侧）。
class Tap {
  Tap._(this.name, this._server, this._upstreamPort);

  static Future<Tap> start(String name, int upstreamPort) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final tap = Tap._(name, server, upstreamPort);
    server.listen(tap._accept);
    return tap;
  }

  final String name;
  final ServerSocket _server;
  final int _upstreamPort;
  final _sent = BytesBuilder();
  final _open = <Socket>{};
  var connections = 0;

  int get port => _server.port;
  int get sentLength => _sent.length;
  bool contains(String marker) =>
      _indexOf(_sent.toBytes(), utf8.encode(marker)) >= 0;

  Future<void> _accept(Socket client) async {
    connections++;
    _open.add(client);
    final Socket upstream;
    try {
      upstream = await Socket.connect(
          InternetAddress.loopbackIPv4, _upstreamPort,
          timeout: const Duration(seconds: 10));
    } catch (_) {
      client.destroy();
      return;
    }
    _open.add(upstream);
    void safeAdd(Socket to, List<int> data) {
      try {
        to.add(data);
      } catch (_) {
        // 另一头已经关了。
      }
    }

    client.listen((data) {
      _sent.add(data);
      safeAdd(upstream, data);
    },
        onDone: upstream.destroy,
        onError: (_) => upstream.destroy(),
        cancelOnError: true);
    upstream.listen((data) => safeAdd(client, data),
        onDone: client.destroy,
        onError: (_) => client.destroy(),
        cancelOnError: true);
  }

  Future<void> close() async {
    await _server.close();
    for (final socket in _open) {
      socket.destroy();
    }
  }
}

enum ApiMode {
  ok,
  unauthorized,
  forbidden,
  rateLimited,
  serverError,
  malformed,
  redirect
}

class ApiRequest {
  ApiRequest(this.method, this.path, this.headers, this.body);
  final String method;
  final String path;
  final Map<String, String> headers;
  final String body;
  String get dump =>
      '$method $path\n${headers.entries.map((e) => '${e.key}: ${e.value}').join('\n')}\n\n$body';
}

/// 假的 Tailscale API：只认换 token 和列设备两个端点，别的一律 404 并记下来。
/// 另起一个「重定向陷阱」：App 若跟随 302，就会打到它。
class FakeCatalogApi {
  FakeCatalogApi._(
      this._server, this._trap, this._clientSecret, this._pastedToken);

  static Future<FakeCatalogApi> start(
      String clientSecret, String pastedToken) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final trap = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final api = FakeCatalogApi._(server, trap, clientSecret, pastedToken);
    server.listen(api._handle);
    trap.listen((request) {
      api.redirectFollowed++;
      request.response.close();
    });
    return api;
  }

  final HttpServer _server;
  final HttpServer _trap;
  final String _clientSecret;
  final String _pastedToken;
  final requests = <ApiRequest>[];
  final issued = <String>[];
  var mode = ApiMode.ok;
  var redirectFollowed = 0;
  List<Map<String, Object?>> devices = [];

  Uri get origin => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> _handle(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final headers = <String, String>{};
    request.headers
        .forEach((name, values) => headers[name] = values.join(', '));
    requests
        .add(ApiRequest(request.method, request.uri.toString(), headers, body));
    final response = request.response;
    void reply(int status, Object json) {
      response.statusCode = status;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(json));
    }

    if (request.method == 'POST' && request.uri.path == '/api/v2/oauth/token') {
      if (Uri.splitQueryString(body)['client_secret'] != _clientSecret) {
        reply(401, {'message': 'API token invalid'});
      } else {
        final token = 'r15issued${_hex(16)}';
        issued.add(token);
        reply(200, {
          'access_token': token,
          'token_type': 'Bearer',
          'expires_in': 3600,
          'scope': 'devices:core:read',
        });
      }
    } else if (request.method == 'GET' &&
        request.uri.path == '/api/v2/tailnet/-/devices') {
      final auth = request.headers.value('authorization') ?? '';
      final token = auth.startsWith('Bearer ') ? auth.substring(7) : '';
      switch (mode) {
        case ApiMode.ok when issued.contains(token) || token == _pastedToken:
          reply(200, {'devices': devices});
        case ApiMode.ok || ApiMode.unauthorized:
          reply(401, {'message': 'API token invalid'});
        case ApiMode.forbidden:
          reply(403, {'message': 'requires devices:core:read'});
        case ApiMode.rateLimited:
          response.headers.set('Retry-After', '120');
          reply(429, {'message': 'rate limited'});
        case ApiMode.serverError:
          reply(500, {'message': 'internal error'});
        case ApiMode.malformed:
          response.statusCode = 200;
          response.write('{"devices": [');
        case ApiMode.redirect:
          response.statusCode = 302;
          response.headers
              .set('Location', 'http://127.0.0.1:${_trap.port}/steal');
      }
    } else {
      reply(404, {'message': 'not found'});
    }
    await response.close();
  }

  var _closed = false;
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _server.close(force: true);
    await _trap.close(force: true);
  }
}

class Scan {
  final hits = <String, List<String>>{};
  var files = 0;
  var bytes = 0;
  final skipped = <String>[];
}

/// 明文搜本 App 私有目录（/data/data/<包名> 下全部文件）。
Future<Scan> scanAppData(Map<String, String> markers) async {
  final scan = Scan();
  final root = (await getApplicationSupportDirectory()).parent;
  final needles = {
    for (final e in markers.entries) e.key: utf8.encode(e.value)
  };
  final entities = <FileSystemEntity>[];
  try {
    entities.addAll(root.listSync(recursive: true, followLinks: false));
  } on FileSystemException catch (e) {
    scan.skipped.add('列目录失败 ${e.path}');
  }
  for (final entity in entities) {
    if (entity is! File) continue;
    final Uint8List data;
    try {
      if (entity.lengthSync() > 64 << 20) {
        scan.skipped.add(entity.path);
        continue;
      }
      data = entity.readAsBytesSync();
    } on FileSystemException {
      scan.skipped.add(entity.path);
      continue;
    }
    scan.files++;
    scan.bytes += data.length;
    for (final MapEntry(key: what, value: needle) in needles.entries) {
      if (_indexOf(data, needle) >= 0) {
        scan.hits
            .putIfAbsent(what, () => [])
            .add(entity.path.replaceFirst(root.path, ''));
      }
    }
  }
  return scan;
}
