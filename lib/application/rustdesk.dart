import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plugin_api/plugin_api.dart';

import '../domain/plugins/builtin_plugins.dart';
import '../infrastructure/plugins/rustdesk_external.dart';
import 'external_remote.dart';
import 'plugin_registry.dart';
import 'vault_controller.dart';

/// 一台保险库主机对应的 RustDesk ID：用户自己填的，本 App 没有办法从 RustDesk 里查出来。
///
/// 只存在本机的独立加密存储里，不进保险库：保险库要和桌面端同步，那边不认这个字段；
/// 这条关联也不该跟着保险库导出（docs/17）。
class RustDeskLink {
  const RustDeskLink({
    required this.id,
    required this.hostId,
    required this.peer,
    required this.createdAt,
  });

  /// 本 App 给这条关联起的 ID（设备引用用它，不用 RustDesk ID）。
  final String id;
  final String hostId;
  final RustDeskPeerId peer;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
        'id': id,
        'hostId': hostId,
        'peerId': peer.value,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };

  /// 存储里的 ID 读出来要重新过一遍校验：过不了的条目丢掉，不拿去拼链接。
  static RustDeskLink? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final hostId = json['hostId'];
    final peerId = json['peerId'];
    final created = json['createdAt'] is String
        ? DateTime.tryParse(json['createdAt'] as String)
        : null;
    if (id is! String ||
        hostId is! String ||
        peerId is! String ||
        created == null) {
      return null;
    }
    try {
      return RustDeskLink(
        id: id,
        hostId: hostId,
        peer: RustDeskPeerId.parse(peerId),
        createdAt: created,
      );
    } on RustDeskPeerIdRejected {
      return null;
    }
  }
}

class RustDeskStore {
  const RustDeskStore(this._backend);
  final ProviderSecretBackend _backend;

  static const _links = 'rustdesk.links.v1';
  static const _trust = 'rustdesk.trust.v1';

  /// 读不懂的条目丢掉（让用户重新填），不猜。
  Future<List<RustDeskLink>> links() async {
    final raw = await _backend.read(_links);
    if (raw == null) return const [];
    try {
      return [
        for (final item in jsonDecode(raw) as List)
          if (RustDeskLink.fromJson(item) case final link?) link,
      ];
    } on Object {
      return const [];
    }
  }

  Future<void> saveLinks(List<RustDeskLink> links) => _backend.write(
        _links,
        jsonEncode([for (final l in links) l.toJson()]),
      );

  Future<RustDeskTrust?> trust() async {
    final raw = await _backend.read(_trust);
    if (raw == null) return null;
    try {
      return RustDeskTrust.fromJson(jsonDecode(raw));
    } on Object {
      return null;
    }
  }

  Future<void> saveTrust(RustDeskTrust? trust) => trust == null
      ? _backend.delete(_trust)
      : _backend.write(_trust, jsonEncode(trust.toJson()));
}

/// 本 App 对一次 RustDesk 远控能知道的全部：交出去了，或者没交出去。
///
/// RustDesk 不向发起方回报任何结果，所以 phase 只会是 launchedUnverified 或 launchFailed，
/// 永远到不了「对方报告成功/失败」，更没有「已连接」「已断开」（RDX03）。
class RustDeskAttempt {
  const RustDeskAttempt({
    required this.phase,
    required this.at,
    required this.package,
    this.versionName,
    this.code,
  });

  final ExternalLaunchPhase phase;
  final DateTime at;

  /// 这次交给了哪个包、当时是什么版本（RDX05：出问题时知道是对着哪个版本发的）。
  final String package;
  final String? versionName;

  /// 没交出去时的原因。
  final String? code;
}

class RustDeskState {
  const RustDeskState({
    this.app,
    this.links = const [],
    this.attempts = const {},
    this.notice,
    this.loaded = false,
  });

  /// null：还没探测过。
  final RustDeskAppStatus? app;
  final List<RustDeskLink> links;

  /// 按主机 id：最近一次远控请求。只在内存里，App 重开就没了。
  final Map<String, RustDeskAttempt> attempts;
  final String? notice;
  final bool loaded;

  RustDeskLink? linkOf(String hostId) =>
      links.where((l) => l.hostId == hostId).firstOrNull;

  RustDeskState copyWith({
    RustDeskAppStatus? app,
    List<RustDeskLink>? links,
    Map<String, RustDeskAttempt>? attempts,
    String? Function()? notice,
    bool? loaded,
  }) =>
      RustDeskState(
        app: app ?? this.app,
        links: links ?? this.links,
        attempts: attempts ?? this.attempts,
        notice: notice == null ? this.notice : notice(),
        loaded: loaded ?? this.loaded,
      );
}

class RustDeskRequestRefused implements Exception {
  const RustDeskRequestRefused(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 主机的 SSH 经代理或跳板，而 RustDesk 走它自己的网络：发起前要用户明确知道并同意（RDX04）。
class RustDeskRouteNeedsConfirmation implements Exception {
  const RustDeskRouteNeedsConfirmation(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

/// RustDesk 外部客户端联动（X07）。规则见 plan/v3/docs/17「X07 固定的 RustDesk 口径」。
///
/// - 每个操作先向 registry 要 `builtin.rustdesk` 的外部拉起能力。
/// - 请求只发给证书核对过的官方包，或用户看过包名和证书后明确信任的那一个包；别的包声明了
///   `rustdesk://` 也拿不到。
/// - 只发一种链接：`rustdesk://connect/<ID>`。ID 保存时校验，发之前再校验；不带密码，不碰 RustDesk 的服务器设置。
/// - 只在用户点了按钮时发。保存 ID、打开页面、回到前台都不发。
/// - 发出去之后只记「已交给 RustDesk」。RustDesk 不回报，本 App 不猜它连没连上。
class RustDeskController extends StateNotifier<RustDeskState> {
  RustDeskController({
    required RustDeskPlatform platform,
    required RustDeskStore store,
    required PluginRegistry registry,
    required Future<List<RemoteControlHost>> Function() hosts,
    DateTime Function()? now,
    Random? random,
  })  : _platform = platform,
        _store = store,
        _registry = registry,
        _hosts = hosts,
        _now = now ?? DateTime.now,
        _random = random ?? Random.secure(),
        super(const RustDeskState()) {
    _ready = _serial(_load);
  }

  final RustDeskPlatform _platform;
  final RustDeskStore _store;
  final PluginRegistry _registry;
  final Future<List<RemoteControlHost>> Function() _hosts;
  final DateTime Function() _now;
  final Random _random;
  late final Future<void> _ready;

  /// 所有改状态的操作排队执行：连点两下「远控」不会交叠着发两次探测和两条请求。
  Future<void> _queue = Future.value();
  Future<T> _serial<T>(Future<T> Function() op) {
    final result = _queue.then((_) => op());
    _queue = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> get ready => _ready;

  void _require() => _registry.require(
      BuiltinPlugins.rustdesk, Capability.remoteDesktopExternal);

  Future<void> _load() async {
    try {
      final links = await _store.links();
      if (!mounted) return;
      state = state.copyWith(links: links, loaded: true);
      await _refresh();
    } on Object catch (e) {
      // 读不出来时照样把 loaded 置上：界面据此显示原因，而不是一直转圈。
      if (mounted) {
        state =
            state.copyWith(loaded: true, notice: () => '读取 RustDesk 关联失败：$e');
      }
    }
  }

  Future<void> refreshApp() => _serial(_refresh);

  Future<RustDeskProbe> _refresh() async {
    final probe = await _platform.probe();
    final trust = await _store.trust();
    if (mounted) {
      state = state.copyWith(app: evaluateRustDeskApp(probe, trust: trust));
    }
    return probe;
  }

  /// 用户看过包名和证书后信任这个客户端。只能信任此刻系统读出的那张证书；同一时刻只信任一个包。
  Future<void> trustClient(String package, String signer) => _serial(() async {
        _require();
        final probe = await _refresh();
        final current =
            probe.handlers.where((c) => c.package == package).firstOrNull;
        if (current == null ||
            current.signers.length != 1 ||
            current.signers.single != signer) {
          throw const RustDeskRequestRefused(
              '确认期间这个 App 有变化（更新、换签或卸载），没有信任。请重新核对。');
        }
        await _store.saveTrust(RustDeskTrust(package: package, signer: signer));
        await _refresh();
      });

  Future<void> revokeTrust() => _serial(() async {
        await _store.saveTrust(null);
        await _refresh();
      });

  /// 给主机填（或改）RustDesk ID。同一台主机只有一条：再填就是替换。只保存，不发任何请求。
  Future<void> saveLink(String hostId, String input) => _serial(() async {
        final peer = RustDeskPeerId.parse(input);
        final host = await _hostOf(hostId);
        final link = RustDeskLink(
          id: _newId(),
          hostId: host.id,
          peer: peer,
          createdAt: _now(),
        );
        final links = [
          for (final l in state.links)
            if (l.hostId != host.id) l,
          link,
        ];
        await _store.saveLinks(links);
        // 换了 ID，上一次请求是发给旧 ID 的，不再挂在这台主机上。
        state = state.copyWith(
          links: links,
          attempts: {...state.attempts}..remove(host.id),
        );
      });

  /// 只删这一条关联。主机、它的 SSH 设置和别的关联都不动；RustDesk 里的东西也不动（DEV02）。
  Future<void> deleteLink(String linkId) => _serial(() async {
        final links = [
          for (final l in state.links)
            if (l.id != linkId) l,
        ];
        await _store.saveLinks(links);
        state = state.copyWith(links: links);
      });

  /// 把这台主机的 RustDesk ID 交给 RustDesk 去连。
  ///
  /// 主机的 SSH 经代理或跳板时，[acceptProviderManagedNetwork] 必须是 true（用户已确认 RustDesk 走它自己的网络），
  /// 否则抛 [RustDeskRouteNeedsConfirmation]，什么都不发。
  Future<void> launch(
    String hostId, {
    bool acceptProviderManagedNetwork = false,
  }) =>
      _serial(() async {
        _require();
        final link = state.linkOf(hostId);
        if (link == null) {
          throw const RustDeskRequestRefused('这台主机还没有填 RustDesk ID');
        }
        final host = await _hostOf(hostId);
        // 默认认为用户要和 SSH 同一条路线；RustDesk 做不到（provider-managed 只接受系统默认网络），
        // 所以除非用户明确接受「RustDesk 走它自己的网络」，否则一律不发。判定用插件契约的同一条规则。
        final route = checkRoute(
          BuiltinPlugins.descriptors
              .singleWhere((d) => d.pluginId == BuiltinPlugins.rustdesk),
          TransportKind.providerManaged,
          acceptProviderManagedNetwork
              ? RequestedRoute.systemDefault
              : host.sshRoute,
        );
        if (route case RouteUnsupported(:final reason)) {
          throw RustDeskRouteNeedsConfirmation(reason);
        }
        final target = await _readyClient();
        final client = target.client;
        RustDeskAttempt attempt(ExternalLaunchPhase phase, [String? code]) =>
            RustDeskAttempt(
              phase: phase,
              at: _now(),
              package: client.package,
              versionName: client.versionName,
              code: code,
            );
        try {
          await _platform.launch(
            link.peer.connectUri,
            package: client.package,
            signer: target.signer,
          );
        } on RustDeskLaunchFailed catch (e) {
          _setAttempt(
              hostId, attempt(ExternalLaunchPhase.launchFailed, e.message));
          rethrow;
        }
        _setAttempt(hostId, attempt(ExternalLaunchPhase.launchedUnverified));
      });

  void clearNotice() {
    if (state.notice != null) state = state.copyWith(notice: () => null);
  }

  // ---------------------------------------------------------------------------

  Future<RustDeskReady> _readyClient() async {
    await _refresh();
    return switch (state.app) {
      final RustDeskReady ready => ready,
      RustDeskPlatformUnsupported() =>
        throw const RustDeskRequestRefused('RustDesk 联动目前只支持 Android'),
      RustDeskNotInstalled() =>
        throw const RustDeskRequestRefused('没有装 RustDesk'),
      RustDeskVersionTooOld() => throw const RustDeskRequestRefused(
          'RustDesk 版本太旧，不接受别的 App 发来的连接请求，最低要求：${RustDeskProtocol.minVersionText}'),
      RustDeskSignerNeedsApproval() =>
        throw const RustDeskRequestRefused('还没核对过手机上这个 RustDesk 的签名证书'),
      RustDeskSignerChanged() =>
        throw const RustDeskRequestRefused('你信任的那个 RustDesk 换了签名证书，要重新核对'),
      RustDeskSignerUnsupported() =>
        throw const RustDeskRequestRefused('这个 RustDesk 由多张证书签名，暂不支持'),
      null => throw const RustDeskRequestRefused('还没检查手机上的 RustDesk'),
    };
  }

  Future<RemoteControlHost> _hostOf(String hostId) async {
    final host = (await _hosts()).where((h) => h.id == hostId).firstOrNull;
    if (host == null) throw const RustDeskRequestRefused('这台主机已不在保险库里');
    return host;
  }

  void _setAttempt(String hostId, RustDeskAttempt attempt) {
    if (!mounted) return;
    state = state.copyWith(attempts: {...state.attempts, hostId: attempt});
  }

  /// 16 字节安全随机数，base64url 去掉填充，22 个字符。
  String _newId() => base64Url
      .encode(List<int>.generate(16, (_) => _random.nextInt(256)))
      .replaceAll('=', '');
}

final rustDeskPlatformProvider =
    Provider<RustDeskPlatform>((ref) => AndroidRustDeskPlatform());

/// 存储名定了就不能改：改了就读不到已有的关联。
final rustDeskStoreProvider = Provider<RustDeskStore>(
  (ref) => RustDeskStore(SecureProviderBackend(
    prefsName: 'xwshun_rustdesk',
    keychainAccount: 'xwshun.rustdesk',
  )),
);

final rustDeskProvider =
    StateNotifierProvider<RustDeskController, RustDeskState>((ref) {
  final vault = ref.watch(vaultControllerProvider.notifier);
  return RustDeskController(
    platform: ref.watch(rustDeskPlatformProvider),
    store: ref.watch(rustDeskStoreProvider),
    registry: ref.read(pluginRegistryProvider.notifier),
    hosts: () async => [
      for (final h in (await vault.ready()).hosts) RemoteControlHost.of(h),
    ],
  );
});
