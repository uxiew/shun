import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plugin_api/plugin_api.dart';

import '../domain/plugins/builtin_plugins.dart';
import '../infrastructure/plugins/uuremote_adapter.dart';
import 'external_remote.dart';
import 'plugin_registry.dart';
import 'vault_controller.dart';

/// 一条 UU 远程绑定：用户在 UU 里选了一台 Windows/macOS 设备，UU 返回加密设备标识，用户确认后挂到一台保险库主机上。
///
/// 只存在本机的独立安全存储里，不进保险库：加密标识和生成它时登录的 UU 账号绑定，换手机、换账号都用不了，
/// 同步过去没有意义；它又是敏感值，不能跟着保险库导出（docs/17）。
class UuBinding {
  const UuBinding({
    required this.id,
    required this.hostId,
    required this.anonymousDeviceId,
    required this.createdAt,
    this.invalidReason,
    this.invalidAt,
  });

  final String id;
  final String hostId;

  /// UU 返回的加密设备标识。不透明：不解密、不显示、不写日志、不复制到剪贴板。
  final String anonymousDeviceId;
  final DateTime createdAt;

  /// UU 报告这条绑定失效的原因（目前只有 device_not_found：设备解绑、被删或换了 UU 账号）。
  final String? invalidReason;
  final DateTime? invalidAt;

  bool get valid => invalidReason == null;

  UuBinding invalidated(String reason, DateTime at) => UuBinding(
        id: id,
        hostId: hostId,
        anonymousDeviceId: anonymousDeviceId,
        createdAt: createdAt,
        invalidReason: reason,
        invalidAt: at,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'hostId': hostId,
        'anonymousDeviceId': anonymousDeviceId,
        'createdAt': createdAt.toUtc().toIso8601String(),
        if (invalidReason != null) 'invalidReason': invalidReason,
        if (invalidAt != null)
          'invalidAt': invalidAt!.toUtc().toIso8601String(),
      };

  static UuBinding? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final hostId = json['hostId'];
    final device = json['anonymousDeviceId'];
    final created = json['createdAt'] is String
        ? DateTime.tryParse(json['createdAt'] as String)
        : null;
    if (id is! String ||
        hostId is! String ||
        device is! String ||
        created == null) {
      return null;
    }
    return UuBinding(
      id: id,
      hostId: hostId,
      anonymousDeviceId: device,
      createdAt: created,
      invalidReason: json['invalidReason'] is String
          ? json['invalidReason'] as String
          : null,
      invalidAt: json['invalidAt'] is String
          ? DateTime.tryParse(json['invalidAt'] as String)
          : null,
    );
  }

  /// 调试输出里不带加密标识。
  @override
  String toString() =>
      'UuBinding($id -> host $hostId${valid ? '' : ', invalid'})';
}

/// 等 UU 回调的请求。同一时刻只有一个（官方：UU 同一时刻只处理一个第三方请求）。
///
/// state、nonce 是一次性的随机值：只有它们对上，回调才算这个请求的；用过、过期、被用户结束等待就作废。
/// 存进安全存储：UU 在前台远控时本 App 可能被系统杀掉，回调来时要能在新进程里对上。
class UuPendingRequest {
  const UuPendingRequest({
    required this.kind,
    required this.state,
    required this.hostId,
    required this.createdAt,
    required this.expiresAt,
    this.nonce,
    this.bindingId,
  });

  final UuCallbackKind kind;
  final String state;

  /// 只有绑定请求有（控制请求官方没有 nonce 字段）。
  final String? nonce;
  final String hostId;

  /// 控制请求对应的绑定。
  final String? bindingId;
  final DateTime createdAt;
  final DateTime expiresAt;

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'state': state,
        if (nonce != null) 'nonce': nonce,
        'hostId': hostId,
        if (bindingId != null) 'bindingId': bindingId,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'expiresAt': expiresAt.toUtc().toIso8601String(),
      };

  static UuPendingRequest? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind =
        UuCallbackKind.values.where((k) => k.name == json['kind']).firstOrNull;
    final state = json['state'];
    final hostId = json['hostId'];
    DateTime? time(Object? v) => v is String ? DateTime.tryParse(v) : null;
    final created = time(json['createdAt']);
    final expires = time(json['expiresAt']);
    if (kind == null ||
        state is! String ||
        hostId is! String ||
        created == null ||
        expires == null) {
      return null;
    }
    return UuPendingRequest(
      kind: kind,
      state: state,
      nonce: json['nonce'] is String ? json['nonce'] as String : null,
      hostId: hostId,
      bindingId:
          json['bindingId'] is String ? json['bindingId'] as String : null,
      createdAt: created,
      expiresAt: expires,
    );
  }
}

class UuRemoteStore {
  const UuRemoteStore(this._backend);
  final ProviderSecretBackend _backend;

  static const _bindings = 'uuremote.bindings.v1';
  static const _pending = 'uuremote.pending.v1';
  static const _approved = 'uuremote.approvedSigner.v1';

  /// 读不懂的条目丢掉（让用户重新绑定），不猜。
  Future<List<UuBinding>> bindings() async {
    final raw = await _backend.read(_bindings);
    if (raw == null) return const [];
    try {
      return [
        for (final item in jsonDecode(raw) as List)
          if (UuBinding.fromJson(item) case final binding?) binding,
      ];
    } on Object {
      return const [];
    }
  }

  Future<void> saveBindings(List<UuBinding> bindings) => _backend.write(
        _bindings,
        jsonEncode([for (final b in bindings) b.toJson()]),
      );

  Future<UuPendingRequest?> pending() async {
    final raw = await _backend.read(_pending);
    if (raw == null) return null;
    try {
      return UuPendingRequest.fromJson(jsonDecode(raw));
    } on Object {
      return null;
    }
  }

  Future<void> savePending(UuPendingRequest? request) => request == null
      ? _backend.delete(_pending)
      : _backend.write(_pending, jsonEncode(request.toJson()));

  Future<String?> approvedSigner() => _backend.read(_approved);

  Future<void> saveApprovedSigner(String? sha256) => sha256 == null
      ? _backend.delete(_approved)
      : _backend.write(_approved, sha256);
}

/// UU 远控这件事本 App 能知道的全部状态。故意没有「已连接」：
/// 全屏 UU 从不回报；小窗的成功只是 UU 在那一刻的报告（ExternalLaunchPhase 同样没有 connected）。
class UuAttempt {
  const UuAttempt({
    required this.kind,
    required this.phase,
    required this.at,
    this.window,
    this.code,
    this.unconfirmed = false,
  });

  final UuCallbackKind kind;
  final ExternalLaunchPhase phase;
  final DateTime at;
  final UuWindow? window;

  /// UU 报告的错误码 / reason 原文，或本 App 的拒收原因。
  final String? code;

  /// 用户结束了等待：UU 之后再回报也不算数。
  final bool unconfirmed;
}

/// UU 绑定成功回调、等用户确认的那一刻。只在内存里：确认前 App 被杀，就当没绑，用户重新绑一次。
class UuBindOffer {
  const UuBindOffer({
    required this.hostId,
    required this.anonymousDeviceId,
    required this.receivedAt,
  });
  final String hostId;
  final String anonymousDeviceId;
  final DateTime receivedAt;
}

class UuRemoteState {
  const UuRemoteState({
    this.app,
    this.bindings = const [],
    this.pending,
    this.offer,
    this.attempts = const {},
    this.notice,
    this.loaded = false,
    this.callbackRivals = const [],
  });

  /// null：还没探测过。
  final UuAppStatus? app;

  /// 最近一次探测到的、也声明了本 App 回调地址的其他包（见 [UuProbe.callbackRivals]）。
  final List<String> callbackRivals;
  final List<UuBinding> bindings;
  final UuPendingRequest? pending;
  final UuBindOffer? offer;

  /// 按主机 id：最近一次绑定或远控的结果。
  final Map<String, UuAttempt> attempts;

  /// 最近一条给用户看的提示（比如忽略了一条回调），不含加密标识。
  final String? notice;
  final bool loaded;

  UuBinding? bindingOf(String hostId) =>
      bindings.where((b) => b.hostId == hostId).firstOrNull;

  UuRemoteState copyWith({
    UuAppStatus? app,
    List<UuBinding>? bindings,
    UuPendingRequest? Function()? pending,
    UuBindOffer? Function()? offer,
    Map<String, UuAttempt>? attempts,
    String? Function()? notice,
    bool? loaded,
    List<String>? callbackRivals,
  }) =>
      UuRemoteState(
        callbackRivals: callbackRivals ?? this.callbackRivals,
        app: app ?? this.app,
        bindings: bindings ?? this.bindings,
        pending: pending == null ? this.pending : pending(),
        offer: offer == null ? this.offer : offer(),
        attempts: attempts ?? this.attempts,
        notice: notice == null ? this.notice : notice(),
        loaded: loaded ?? this.loaded,
      );
}

class UuRequestRefused implements Exception {
  const UuRequestRefused(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 主机的 SSH 经代理或跳板，而 UU 远程走它自己的网络：发起前要用户明确知道并同意（UUR08）。
class UuRouteNeedsConfirmation implements Exception {
  const UuRouteNeedsConfirmation(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

/// [UuAttempt.code] 的本地取值：UU 返回了设备，但用户没保存。和 UU 的错误码不重名。
const uuDiscardedByUser = 'xwshun_discarded_by_user';

/// [UuAttempt.code] 的本地取值：绑定成功的回调到达时，手机上有别的 App 也声明了本 App 的回调地址，
/// 返回的设备没有采用（原因见 [UuRemoteController] 的说明）。
const uuCallbackContested = 'xwshun_callback_contested';

/// [UuAttempt.code] 的本地取值：等满 [uuPendingLifetime] UU 也没回报，请求自己作废了（和用户点「结束等待」区分开）。
const uuWaitExpired = 'xwshun_wait_expired';

/// 本地最长等 UU 回调多久。官方：未登录排队最长 180 秒；前置拦截弹窗要用户点了才回调、没有超时。留足余量。
const uuPendingLifetime = Duration(minutes: 10);

/// UU 远程的绑定与远控（X06）。规则见 plan/v3/docs/17「X06 固定的官方口径」。
///
/// - 每个操作先向 registry 要 `builtin.uuremote` 的外部拉起能力。
/// - 请求只发给已核对证书的官方包；同一时刻只有一个等回调的请求，新请求要等旧的结束或用户结束等待。
/// - 回调只认 state（和绑定的 nonce）对得上、没过期、没用过的；对上就作废，第二次来就是重放。
/// - 手机上有别的 App 也声明了本 App 的回调地址时，要靠回调的请求（绑定、小窗）不发，绑定成功的回调不采用：
///   自定义 scheme 证明不了回调是谁发的，那个 App 能截走回调、换掉设备标识再转给本 App。
/// - 绑定成功不直接保存，先给用户确认挂到哪台主机；回调之后从不自动发起远控。
/// - 全屏只显示「已交给 UU 远程」；小窗只显示 UU 报告的结果和时间。
class UuRemoteController extends StateNotifier<UuRemoteState> {
  UuRemoteController({
    required UuRemotePlatform platform,
    required UuRemoteStore store,
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
        super(const UuRemoteState()) {
    _callbacks = _platform.callbacks.listen((raw) {
      // 回调处理出错（比如存储写不进去）只提示，不能变成未捕获异常，也不能卡住后面的回调。
      _serial(() => _handle(raw)).catchError(
        (Object e) => _notice('处理 UU 回调时出错：$e'),
      );
    });
    // 等回调的请求一变（发出、对上、结束等待），就按它的到期时间重新定时。挂在状态上而不是各处手动调，免得漏。
    _stopWatching = addListener((next) {
      if (identical(next.pending, _watched)) return;
      _watched = next.pending;
      _expiry?.cancel();
      final pending = next.pending;
      if (pending == null) return;
      // 多等 1 秒：定时器早到几毫秒的话 _expireIfDue 会认为还没到期，就没人再来清了。
      final left =
          pending.expiresAt.difference(_now()) + const Duration(seconds: 1);
      _expiry = Timer(left.isNegative ? Duration.zero : left, () {
        unawaited(_serial(_expireIfDue).catchError((Object _) {}));
      });
    }, fireImmediately: false);
    _ready = _serial(_load);
  }

  final UuRemotePlatform _platform;
  final UuRemoteStore _store;
  final PluginRegistry _registry;
  final Future<List<RemoteControlHost>> Function() _hosts;
  final DateTime Function() _now;
  final Random _random;
  late final StreamSubscription<String> _callbacks;
  late final Future<void> _ready;
  late final void Function() _stopWatching;
  UuPendingRequest? _watched;
  Timer? _expiry;

  /// 所有改状态的操作排队执行：回调可能和用户点击同时到，交叠会让一个回调对上两次。
  Future<void> _queue = Future.value();
  Future<T> _serial<T>(Future<T> Function() op) {
    final result = _queue.then((_) => op());
    _queue = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> get ready => _ready;

  void _require() => _registry.require(
      BuiltinPlugins.uuremote, Capability.remoteDesktopExternal);

  Future<void> _load() async {
    try {
      var pending = await _store.pending();
      if (pending != null && !_now().isBefore(pending.expiresAt)) {
        await _store.savePending(null);
        pending = null;
      }
      final bindings = await _store.bindings();
      if (!mounted) return;
      state = state.copyWith(
        bindings: bindings,
        pending: () => pending,
        // 「最近一次」只在内存里。App 被杀后重开、请求还在等：补一条，不然页面只有「最多等到」、没说在等什么。
        attempts: pending == null
            ? null
            : {
                pending.hostId: UuAttempt(
                  kind: pending.kind,
                  phase: ExternalLaunchPhase.launchedUnverified,
                  at: pending.createdAt,
                  window: pending.kind == UuCallbackKind.control
                      ? UuWindow.pip
                      : null,
                ),
              },
        loaded: true,
      );
      await _refresh();
    } on Object catch (e) {
      // 读不出来时照样把 loaded 置上：界面据此显示原因，而不是一直转圈；回调来了会因为没有请求而被忽略。
      if (mounted) {
        state = state.copyWith(loaded: true, notice: () => '读取 UU 绑定失败：$e');
      }
    }
  }

  Future<void> refreshApp() => _serial(_refresh);

  /// 等回调的请求到点就自己作废，记成「结果未确认」。
  ///
  /// 不这么做的话页面一直写着「等它回报」、发送按钮一直灰着，要用户自己点「结束等待」才恢复——
  /// 模拟器上用真实 UU 碰到过：没登录的 UU 等满 10 分钟也没有任何回报。
  Future<void> _expireIfDue() async {
    final pending = state.pending;
    if (pending == null || _now().isBefore(pending.expiresAt)) return;
    await _store.savePending(null);
    final previous = state.attempts[pending.hostId];
    _setAttempt(
      pending.hostId,
      UuAttempt(
        kind: pending.kind,
        phase: ExternalLaunchPhase.launchedUnverified,
        at: previous?.at ?? pending.createdAt,
        window: previous?.window,
        code: uuWaitExpired,
        unconfirmed: true,
      ),
      pending: () => null,
    );
  }

  Future<void> _refresh() async {
    // 定时器只在 App 活着时走；App 在后台被冻住、回到前台重查时补上。
    await _expireIfDue();
    final probe = await _platform.probe();
    final approved = await _store.approvedSigner();
    if (!mounted) return;
    state = state.copyWith(
      app: evaluateUuApp(probe, approvedSigner: approved),
      callbackRivals: probe.callbackRivals,
    );
  }

  /// 用户看过证书后批准。只能批准此刻系统读出的那张。
  Future<void> approveSigner(String signer) => _serial(() async {
        _require();
        await _refresh();
        final app = state.app;
        final current = switch (app) {
          UuSignerNeedsApproval(:final signer) => signer,
          UuSignerChanged(:final current) => current,
          _ => null,
        };
        if (current != signer) {
          throw const UuRequestRefused('确认期间 UU 远程有变化（更新、换签或卸载），没有批准。请重新核对。');
        }
        await _store.saveApprovedSigner(signer);
        await _refresh();
      });

  Future<void> revokeApproval() => _serial(() async {
        await _store.saveApprovedSigner(null);
        await _refresh();
      });

  /// 发起绑定：打开 UU 的设备授权页。用户在 UU 里选设备后回调，再由用户确认挂到 [hostId]。
  Future<void> startBind(String hostId) => _serial(() async {
        _require();
        final signer = await _readySigner();
        _requireNoRivals();
        await _requireNoPending();
        final host = await _hostOf(hostId);
        // 上一次回来、还没确认的绑定作废：用户重新发起，就是不要它了。
        state = state.copyWith(offer: () => null);
        final now = _now();
        final request = UuPendingRequest(
          kind: UuCallbackKind.bind,
          state: _newState(),
          nonce: _newUuid(),
          hostId: host.id,
          createdAt: now,
          expiresAt: now.add(uuPendingLifetime),
        );
        await _send(
          request,
          UuRequests.authorize(
            callback: UuRequests.callback(UuCallbackKind.bind, request.state),
            nonce: request.nonce!,
          ),
          signer,
        );
      });

  /// 发起远控。全屏：交给 UU 就结束，不等回调。小窗：带回调地址，等 UU 最终回报一次。
  ///
  /// 主机的 SSH 经代理或跳板时，[acceptProviderManagedNetwork] 必须是 true（用户已确认 UU 走它自己的网络），
  /// 否则抛 [UuRouteNeedsConfirmation]，什么都不发。
  Future<void> launch(
    String hostId,
    UuWindow window, {
    bool acceptProviderManagedNetwork = false,
  }) =>
      _serial(() async {
        _require();
        final binding = state.bindingOf(hostId);
        if (binding == null) {
          throw const UuRequestRefused('这台主机还没有 UU 绑定');
        }
        if (!binding.valid) {
          throw const UuRequestRefused('这条 UU 绑定已失效，要重新绑定');
        }
        final host = await _hostOf(hostId);
        // 默认认为用户要和 SSH 同一条路线；UU 做不到（provider-managed 只接受系统默认网络），
        // 所以除非用户明确接受「UU 走它自己的网络」，否则一律不发。判定用插件契约的同一条规则。
        final route = checkRoute(
          BuiltinPlugins.descriptors
              .singleWhere((d) => d.pluginId == BuiltinPlugins.uuremote),
          TransportKind.providerManaged,
          acceptProviderManagedNetwork
              ? RequestedRoute.systemDefault
              : host.sshRoute,
        );
        if (route case RouteUnsupported(:final reason)) {
          throw UuRouteNeedsConfirmation(reason);
        }
        final signer = await _readySigner();
        if (window == UuWindow.fullscreen) {
          await _launchOrRecord(
            hostId,
            UuCallbackKind.control,
            UuRequests.control(
              anonymousDeviceId: binding.anonymousDeviceId,
              window: UuWindow.fullscreen,
            ),
            signer,
            window: window,
          );
          return;
        }
        _requireNoRivals();
        await _requireNoPending();
        final now = _now();
        final request = UuPendingRequest(
          kind: UuCallbackKind.control,
          state: _newState(),
          hostId: hostId,
          bindingId: binding.id,
          createdAt: now,
          expiresAt: now.add(uuPendingLifetime),
        );
        await _send(
          request,
          UuRequests.control(
            anonymousDeviceId: binding.anonymousDeviceId,
            window: UuWindow.pip,
            callback:
                UuRequests.callback(UuCallbackKind.control, request.state),
          ),
          signer,
          window: window,
        );
      });

  /// 用户不等了。请求作废，UU 之后的回报一律忽略；结果记为「未确认」，不当成失败、不重试。
  Future<void> endWaiting() => _serial(() async {
        final pending = state.pending;
        if (pending == null) return;
        await _store.savePending(null);
        final previous = state.attempts[pending.hostId];
        _setAttempt(
          pending.hostId,
          UuAttempt(
            kind: pending.kind,
            phase: ExternalLaunchPhase.launchedUnverified,
            at: previous?.at ?? pending.createdAt,
            window: previous?.window,
            unconfirmed: true,
          ),
          pending: () => null,
        );
      });

  /// 用户确认把 UU 返回的设备挂到主机上。同一台主机只有一条 UU 绑定：重新绑定替换旧的。
  Future<void> confirmOffer() => _serial(() async {
        final offer = state.offer;
        if (offer == null) return;
        final hosts = await _hosts();
        if (!hosts.any((h) => h.id == offer.hostId)) {
          state = state.copyWith(offer: () => null);
          throw const UuRequestRefused('要关联的主机已经不在了，没有保存。');
        }
        final binding = UuBinding(
          id: _newState(),
          hostId: offer.hostId,
          anonymousDeviceId: offer.anonymousDeviceId,
          createdAt: _now(),
        );
        final bindings = [
          for (final b in state.bindings)
            if (b.hostId != offer.hostId) b,
          binding,
        ];
        await _store.saveBindings(bindings);
        state = state.copyWith(bindings: bindings, offer: () => null);
      });

  /// 用户不要这次绑定：加密标识从内存里丢掉，什么都不存。
  void discardOffer() {
    final offer = state.offer;
    if (offer == null) return;
    state = state.copyWith(
      offer: () => null,
      attempts: {
        ...state.attempts,
        offer.hostId: UuAttempt(
          kind: UuCallbackKind.bind,
          phase: ExternalLaunchPhase.providerReportedSuccess,
          at: _now(),
          code: uuDiscardedByUser,
        ),
      },
    );
  }

  /// 只删这一条绑定。主机、它的 SSH 设置和别的关联都不动（DEV02）。
  Future<void> deleteBinding(String bindingId) => _serial(() async {
        final bindings = [
          for (final b in state.bindings)
            if (b.id != bindingId) b,
        ];
        await _store.saveBindings(bindings);
        state = state.copyWith(bindings: bindings);
      });

  void clearNotice() {
    if (state.notice != null) state = state.copyWith(notice: () => null);
  }

  // ---------------------------------------------------------------------------

  Future<String> _readySigner() async {
    await _refresh();
    return switch (state.app) {
      UuReady(:final signer) => signer,
      UuPlatformUnsupported() =>
        throw const UuRequestRefused('UU 远程联动目前只支持 Android'),
      UuNotInstalled() => throw const UuRequestRefused('没有装 UU 远程'),
      UuVersionTooOld() => throw const UuRequestRefused(
          'UU 远程版本太旧，最低要求：${UuRemoteProtocol.minVersionText}'),
      UuSchemeNotHandled() =>
        throw const UuRequestRefused('装着的 UU 远程不接受跨 App 请求'),
      UuSignerNeedsApproval() =>
        throw const UuRequestRefused('还没核对过手机上这个 UU 远程的签名证书'),
      UuSignerChanged() =>
        throw const UuRequestRefused('手机上的 UU 远程换了签名证书，要重新核对'),
      UuSignerUnsupported() =>
        throw const UuRequestRefused('这个 UU 远程由多张证书签名，暂不支持'),
      null => throw const UuRequestRefused('还没检查手机上的 UU 远程'),
    };
  }

  /// 调用前 [_readySigner] 刚探测过。全屏不带回调，不用查这个。
  void _requireNoRivals() {
    final rivals = state.callbackRivals;
    if (rivals.isEmpty) return;
    throw UuRequestRefused(
        '另有 App 也声明了本 App 的 UU 回调地址，UU 的回报可能被它截走或冒充。先卸载它再试：${rivals.join(', ')}');
  }

  Future<void> _requireNoPending() async {
    final pending = state.pending;
    if (pending == null) return;
    if (!_now().isBefore(pending.expiresAt)) {
      await _store.savePending(null);
      state = state.copyWith(pending: () => null);
      return;
    }
    throw const UuRequestRefused('上一个 UU 请求还在等回报。先结束等待，再发新的。');
  }

  Future<RemoteControlHost> _hostOf(String hostId) async {
    final host = (await _hosts()).where((h) => h.id == hostId).firstOrNull;
    if (host == null) throw const UuRequestRefused('这台主机已不在保险库里');
    return host;
  }

  /// 先存请求再发：UU 可能在发完之前就回调（本 App 被切到后台时也可能被杀）。发送失败就撤回请求。
  Future<void> _send(
    UuPendingRequest request,
    String uri,
    String signer, {
    UuWindow? window,
  }) async {
    await _store.savePending(request);
    state = state.copyWith(pending: () => request);
    try {
      await _platform.launch(uri, signer: signer);
    } on UuLaunchFailed catch (e) {
      await _store.savePending(null);
      _setAttempt(
        request.hostId,
        UuAttempt(
          kind: request.kind,
          phase: ExternalLaunchPhase.launchFailed,
          at: _now(),
          window: window,
          code: e.message,
        ),
        pending: () => null,
      );
      rethrow;
    }
    _setAttempt(
      request.hostId,
      UuAttempt(
        kind: request.kind,
        phase: ExternalLaunchPhase.launchedUnverified,
        at: _now(),
        window: window,
      ),
    );
  }

  Future<void> _launchOrRecord(
    String hostId,
    UuCallbackKind kind,
    String uri,
    String signer, {
    required UuWindow window,
  }) async {
    try {
      await _platform.launch(uri, signer: signer);
    } on UuLaunchFailed catch (e) {
      _setAttempt(
        hostId,
        UuAttempt(
          kind: kind,
          phase: ExternalLaunchPhase.launchFailed,
          at: _now(),
          window: window,
          code: e.message,
        ),
      );
      rethrow;
    }
    _setAttempt(
      hostId,
      UuAttempt(
        kind: kind,
        phase: ExternalLaunchPhase.launchedUnverified,
        at: _now(),
        window: window,
      ),
    );
  }

  Future<void> _handle(String raw) async {
    await _ready;
    final UuCallback callback;
    try {
      callback = parseUuCallback(raw);
    } on UuCallbackRejected catch (e) {
      _notice('收到一条格式不对的 UU 回调，已忽略：${e.message}');
      return;
    }
    final pending = state.pending;
    if (pending == null || pending.state != callback.state) {
      _notice('收到一条 UU 回调，但没有对应的请求（已处理过、已过期、被你结束了等待，或不是本 App 发的），已忽略。');
      return;
    }
    // 对上了就作废：同一条回调再来一次就是重放。
    await _store.savePending(null);
    state = state.copyWith(pending: () => null);
    if (!_now().isBefore(pending.expiresAt)) {
      _notice('收到的 UU 回调已经过期，已忽略。');
      return;
    }
    final kind = callback is UuBindCallback
        ? UuCallbackKind.bind
        : UuCallbackKind.control;
    UuAttempt failed(String code) => UuAttempt(
          kind: pending.kind,
          phase: ExternalLaunchPhase.providerReportedFailure,
          at: _now(),
          window: state.attempts[pending.hostId]?.window,
          code: code,
        );
    if (kind != pending.kind) {
      _setAttempt(pending.hostId, failed('回调和请求的类型对不上，已作废'));
      return;
    }
    switch (callback) {
      case UuBindCallback(:final nonce, :final anonymousDeviceId, :final error):
        if (nonce != pending.nonce) {
          _setAttempt(pending.hostId, failed('回调校验失败（nonce 不对），已作废'));
          return;
        }
        if (error != null) {
          _setAttempt(pending.hostId, failed(error));
          return;
        }
        // 发请求时查过一次，这里再查：请求发出之后才装上的也要防。此刻有别的包声明了回调地址，
        // 这条「成功」就可能是它截下、换了设备标识再转来的（state 和 nonce 它都看得到），不给用户确认。
        await _refresh();
        if (state.callbackRivals.isNotEmpty) {
          _setAttempt(pending.hostId, failed(uuCallbackContested));
          return;
        }
        _setAttempt(
          pending.hostId,
          UuAttempt(
            kind: UuCallbackKind.bind,
            phase: ExternalLaunchPhase.providerReportedSuccess,
            at: _now(),
          ),
        );
        state = state.copyWith(
          offer: () => UuBindOffer(
            hostId: pending.hostId,
            anonymousDeviceId: anonymousDeviceId!,
            receivedAt: _now(),
          ),
        );
      case UuControlCallback(:final success, :final reason):
        if (success) {
          _setAttempt(
            pending.hostId,
            UuAttempt(
              kind: UuCallbackKind.control,
              phase: ExternalLaunchPhase.providerReportedSuccess,
              at: _now(),
              window: UuWindow.pip,
            ),
          );
          return;
        }
        _setAttempt(pending.hostId, failed(reason!));
        if (reason == UuReasons.deviceNotFound) {
          final bindings = [
            for (final b in state.bindings)
              b.id == pending.bindingId ? b.invalidated(reason, _now()) : b,
          ];
          await _store.saveBindings(bindings);
          state = state.copyWith(bindings: bindings);
        }
    }
  }

  void _setAttempt(
    String hostId,
    UuAttempt attempt, {
    UuPendingRequest? Function()? pending,
  }) {
    if (!mounted) return;
    state = state.copyWith(
      attempts: {...state.attempts, hostId: attempt},
      pending: pending,
    );
  }

  void _notice(String message) {
    if (mounted) state = state.copyWith(notice: () => message);
  }

  /// 16 字节安全随机数，base64url 去掉填充，22 个字符。
  String _newState() => base64Url
      .encode(List<int>.generate(16, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  /// 官方建议 nonce 用 UUID。这里是版本 4 格式的随机 UUID。
  String _newUuid() {
    final b = List<int>.generate(16, (_) => _random.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final hex = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}'
        '-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  @override
  void dispose() {
    _expiry?.cancel();
    _stopWatching();
    unawaited(_callbacks.cancel());
    super.dispose();
  }
}

final uuRemotePlatformProvider =
    Provider<UuRemotePlatform>((ref) => AndroidUuRemotePlatform());

/// 存储名沿用 X06 定下的：改了就读不到已有的绑定。
final uuRemoteStoreProvider = Provider<UuRemoteStore>(
  (ref) => UuRemoteStore(SecureProviderBackend(
    prefsName: 'xwshun_uuremote',
    keychainAccount: 'xwshun.uuremote',
  )),
);

final uuRemoteProvider =
    StateNotifierProvider<UuRemoteController, UuRemoteState>((ref) {
  final vault = ref.watch(vaultControllerProvider.notifier);
  return UuRemoteController(
    platform: ref.watch(uuRemotePlatformProvider),
    store: ref.watch(uuRemoteStoreProvider),
    registry: ref.read(pluginRegistryProvider.notifier),
    hosts: () async =>
        [for (final h in (await vault.ready()).hosts) RemoteControlHost.of(h)],
  );
});
