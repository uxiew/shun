import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plugin_api/plugin_api.dart';

import '../domain/device_references.dart';
import '../domain/plugins/builtin_plugins.dart';

/// registry 里每个 provider 此刻能不能用（docs/15 §7 的前半段状态机）。
enum PluginStatus {
  /// 可以调用它声明的能力。
  ready,

  /// 结构合法，但用户还没批准（或批准后又申请了新能力）。可以展示，不能开始任何会话。
  needsApproval,

  /// 冒用内置/官方 ID、抢占已信任 provider、换签、debug 证书进 release 等。保持禁用。
  rejected,

  /// 描述符本身就不合规（API major 不符、多余字段、超长…），连「是谁」都不能信。
  incompatible,

  /// 用户停用。批准记录还在，重新启用不用再批。
  disabled,

  /// 安装包没了（卸载）。条目留着：用到它的设备引用和配置等用户重装或手动处理，不级联删除（DEV02）。
  missing,
}

class PluginEntry {
  const PluginEntry({
    required this.status,
    this.descriptor,
    this.packageName,
    this.reason,
    this.binding,
    this.serviceClass,
    this.signerDigests = const {},
    this.androidDebugSigned = false,
    this.hasApproval = false,
    this.settingsActivity,
    this.installedVersionName,
    this.installedVersionCode,
  });

  final PluginStatus status;

  /// 解析失败（[PluginStatus.incompatible]）时为 null。
  final PluginDescriptor? descriptor;

  /// 系统报告的实际安装包；内置 provider 为 null。
  final String? packageName;
  final String? reason;

  /// 只有 [PluginStatus.ready] 才有。
  final ApprovedBinding? binding;

  /// 系统报告的实际服务类（绑定只用它）；内置 provider 为 null。
  final String? serviceClass;

  /// 系统读出的当前签名证书 SHA-256。
  final Set<String> signerDigests;

  /// 用 Android SDK 自动生成的调试证书签的（每台开发机都有一张，谁都能拿来签）。
  final bool androidDebugSigned;

  /// 这个 pluginId 有批准记录（不论此刻是否可用）。换签被拒时用户要靠它找到「撤销批准」重新核对。
  final bool hasApproval;

  /// 插件自己的设置页（系统查出的组件类名）。只有 [PluginStatus.ready] 时界面才给入口（SDK04）。
  final String? settingsActivity;

  /// 系统报告的安装包版本（versionName / versionCode），用来让用户看出「更新过」。
  /// 描述符里的 version 是插件自称的，两者可能不同。
  final String? installedVersionName;
  final int? installedVersionCode;

  String? get pluginId => descriptor?.pluginId;
  bool get isBuiltin => packageName == null;
}

class PluginUnavailable implements Exception {
  const PluginUnavailable(this.pluginId, this.status, [this.reason]);
  final String pluginId;
  final PluginStatus? status;
  final String? reason;

  @override
  String toString() => status == null
      ? '没有 provider：$pluginId'
      : '$pluginId 当前不可用（${status!.name}）${reason == null ? '' : '：$reason'}';
}

/// 插件拥有的一次会话。宿主只通过这个把手让它关闭，不关心它内部怎么实现。
///
/// 内置 SSH 的终端会话不在这里：它们仍由 SessionController 管（已验证的旧路径，R08 的代次规则在那里），
/// 停用任何插件都碰不到它们。
abstract interface class PluginSessionHandle {
  SessionKind get ref;

  /// 必须幂等：停用、卸载、用户关闭可能先后各调一次（docs/15 §7）。
  Future<void> close();
}

class _Installed {
  _Installed(
    this.packageName,
    this.descriptorJson,
    this.signerDigests, {
    this.serviceClass,
    this.debugSignerDigests = const {},
    this.problem,
    this.settingsActivity,
    this.versionName,
    this.versionCode,
  });
  final String packageName;
  final String descriptorJson;
  final Set<String> signerDigests;
  final String? serviceClass;
  final Set<String> debugSignerDigests;
  final String? problem;
  final String? settingsActivity;
  final String? versionName;
  final int? versionCode;
}

/// 用现有 Riverpod 装配的轻量 provider 注册表（X01）。
///
/// 规则判定全部委托给 plugin_api 的 [AdmissionPolicy]（X00 冻结的口径），这里只做三件事：
/// 1. 内置 provider 在构造时同步登记，不等任何发现或 IO——核心 SSH 不依赖外部插件存在；
/// 2. 把「系统报告装了哪些包、用户批准过什么、停用了什么」合成每个 provider 的当前状态；
/// 3. provider 不再可用时只关掉它自己的会话。
///
/// 发现安装包（PackageManager、证书读取）在 X02 的 Android 桥里做，它把结果交给 [offerInstalled]。
class PluginRegistry extends StateNotifier<List<PluginEntry>> {
  PluginRegistry({
    required AdmissionPolicy policy,
    List<PluginDescriptor>? builtins,
  })  : _policy = policy,
        _builtins = List.unmodifiable(builtins ?? BuiltinPlugins.descriptors),
        super(const []) {
    for (final d in _builtins) {
      if (d.deployment != Deployment.bundled) {
        throw ArgumentError('${d.pluginId} 不是 bundled，不能当内置 provider 登记');
      }
    }
    _recompute();
  }

  final AdmissionPolicy _policy;
  final List<PluginDescriptor> _builtins;
  final _installed = <String, _Installed>{};
  final _missing = <String, PluginDescriptor?>{};
  final _approvals = <ApprovedBinding>[];
  final _disabled = <String>{};
  final _sessions = <PluginSessionHandle>[];

  List<PluginEntry> get entries => state;

  /// 系统报告某个包装着（首次发现或更新后）。描述符来自包里的静态资源，
  /// 证书摘要必须是系统读出来的，不能是描述符或 Intent 里自报的。
  ///
  /// [serviceClass] 是系统报告的、实际声明插件 action 的服务；描述符自称的必须与它一致。
  /// [debugSignerDigests] 是平台认出的 Android 调试证书，release 构建据此拒收（docs/15 §4）。
  /// [problem] 是平台层就能确定的问题（服务没导出、声明了多个服务等），有它直接判不兼容。
  void offerInstalled({
    required String packageName,
    required String descriptorJson,
    required Set<String> signerDigests,
    String? serviceClass,
    Set<String> debugSignerDigests = const {},
    String? problem,
    String? settingsActivity,
    String? versionName,
    int? versionCode,
  }) {
    _missing.remove(packageName);
    _installed[packageName] = _Installed(
      packageName,
      descriptorJson,
      Set.unmodifiable(signerDigests),
      serviceClass: serviceClass,
      debugSignerDigests: Set.unmodifiable(debugSignerDigests),
      problem: problem,
      settingsActivity: settingsActivity,
      versionName: versionName,
      versionCode: versionCode,
    );
    _recompute();
  }

  /// 当前系统报告装着的包（不含 missing）。发现流程据此判断哪些包这次没出现。
  Set<String> get installedPackages => _installed.keys.toSet();

  /// 包被卸载。它的会话关掉；条目变 missing，设备引用和配置原样留着（DEV02）。
  void markUninstalled(String packageName) {
    final gone = _installed.remove(packageName);
    if (gone == null) return;
    _missing[packageName] = _tryParse(gone.descriptorJson);
    _recompute();
  }

  /// 用户在授权页批准。同一 pluginId 的旧批准被替换（换签、扩能力后重新批准都走这里）。
  void approve(ApprovedBinding binding) {
    _approvals
      ..removeWhere((a) => _same(a.pluginId, binding.pluginId))
      ..add(binding);
    _recompute();
  }

  /// 撤销批准：它的会话关掉，回到「待批准」。停用标记一并清掉：
  /// 否则以后重新批准时它会莫名其妙地处在「已停用」。
  void revoke(String pluginId) {
    _approvals.removeWhere((a) => _same(a.pluginId, pluginId));
    _disabled.remove(pluginId.toLowerCase());
    _recompute();
  }

  /// 当前被用户停用的 pluginId（小写）。
  Set<String> get disabledIds => Set.unmodifiable(_disabled);

  /// 停用插件：阻止新操作并关掉它的会话；不影响 SSH/SFTP 或别的 provider。内置 provider 不能停用。
  void disable(String pluginId) {
    if (_isBuiltinId(pluginId)) {
      throw ArgumentError('内置 provider 不能停用：$pluginId');
    }
    _disabled.add(pluginId.toLowerCase());
    _recompute();
  }

  void enable(String pluginId) {
    _disabled.remove(pluginId.toLowerCase());
    _recompute();
  }

  /// 调用某个能力前取绑定。provider 不在 Ready 抛 [PluginUnavailable]，
  /// 没声明这个能力抛 [UnsupportedCapability]——绝不返回空结果冒充成功（PLG02）。
  ApprovedBinding require(String pluginId, Capability capability) {
    final entry = readyEntry(pluginId);
    if (entry == null) {
      final seen = state
          .where((e) => e.pluginId != null && _same(e.pluginId!, pluginId))
          .firstOrNull;
      throw PluginUnavailable(pluginId, seen?.status, seen?.reason);
    }
    requireCapability(entry.binding!, capability);
    return entry.binding!;
  }

  PluginEntry? readyEntry(String pluginId) => state
      .where(
        (e) =>
            e.status == PluginStatus.ready &&
            e.pluginId != null &&
            _same(e.pluginId!, pluginId),
      )
      .firstOrNull;

  /// 某条设备引用的 provider 此刻能不能用。只读：不因为 provider 缺失去删引用或关联。
  DeviceRefAvailability availabilityOf(ProviderDeviceRef ref) {
    if (readyEntry(ref.providerId) != null) {
      return DeviceRefAvailability.available;
    }
    final installed = state.any(
      (e) =>
          e.status != PluginStatus.missing &&
          e.pluginId != null &&
          _same(e.pluginId!, ref.providerId),
    );
    return installed
        ? DeviceRefAvailability.providerNotReady
        : DeviceRefAvailability.providerMissing;
  }

  Iterable<PluginEntry> readyWith(Capability capability) => state.where(
        (e) =>
            e.status == PluginStatus.ready &&
            e.binding!.capabilities.contains(capability),
      );

  /// 插件会话开出来后登记在这里，provider 失效时由 registry 负责关。
  /// 登记时 provider 必须是 Ready 且声明了对应能力，否则直接关掉并抛错。
  void attachSession(PluginSessionHandle handle) {
    final ref = handle.ref;
    final capability = switch (ref) {
      TerminalSessionRef() => Capability.terminalSession,
      RemoteDesktopSessionRef() => Capability.remoteDesktopSurface,
      ExternalLaunchAttempt() => Capability.remoteDesktopExternal,
    };
    try {
      if (_isBuiltinId(ref.providerId)) {
        throw ArgumentError('内置 SSH 会话归 SessionController 管，不登记在插件会话表');
      }
      require(ref.providerId, capability);
    } on Object {
      unawaited(handle.close());
      rethrow;
    }
    _sessions.add(handle);
  }

  void detachSession(PluginSessionHandle handle) => _sessions.remove(handle);

  /// 当前登记的插件会话，按类型区分，各自带自己的状态；没有一个「是否已连接」的公共布尔值。
  List<SessionKind> get pluginSessions =>
      List.unmodifiable(_sessions.map((h) => h.ref));

  void _recompute() {
    final entries = <PluginEntry>[
      for (final d in _builtins)
        PluginEntry(
          status: PluginStatus.ready,
          descriptor: d,
          binding: ApprovedBinding(
            pluginId: d.pluginId,
            packageName: null,
            signingDigest: 'host',
            capabilities: d.capabilities,
          ),
        ),
    ];
    // 占用判定只看内置和已 Ready 的：没批准的候选不能挡住别人，也不能被别人挡住之前就先抢位。
    final registered = <String, InstalledCandidate>{
      for (final d in _builtins)
        d.pluginId.toLowerCase(): InstalledCandidate(
          descriptor: d,
          installedPackage: null,
          actualSignerDigests: const {},
        ),
    };

    // 有匹配批准的包先评估：同一 pluginId 一真一假时，真的先进 Ready，假的随后因「已被占用」被拒，
    // 结果和两个包的安装先后无关。
    final ordered = _installed.values.toList()
      ..sort((a, b) {
        final ap = _hasApprovalFor(a) ? 0 : 1;
        final bp = _hasApprovalFor(b) ? 0 : 1;
        return ap != bp ? ap - bp : a.packageName.compareTo(b.packageName);
      });

    // 平台认出的调试证书并进准入口径；是否放行由构造时的 allowDebugSigners 决定（release 为 false）。
    final debugSigners = {
      for (final pkg in _installed.values) ...pkg.debugSignerDigests,
    };
    final policy = debugSigners.isEmpty
        ? _policy
        : AdmissionPolicy(
            builtinIds: _policy.builtinIds,
            reservedOfficialIds: _policy.reservedOfficialIds,
            allowDebugSigners: _policy.allowDebugSigners,
            debugSignerDigests: {
              ..._policy.debugSignerDigests,
              ...debugSigners,
            },
          );

    for (final pkg in ordered) {
      PluginEntry entryFor(
        PluginStatus status, {
        PluginDescriptor? descriptor,
        String? reason,
        ApprovedBinding? binding,
      }) =>
          PluginEntry(
            status: status,
            descriptor: descriptor,
            packageName: pkg.packageName,
            reason: reason,
            binding: binding,
            serviceClass: pkg.serviceClass,
            signerDigests: pkg.signerDigests,
            androidDebugSigned: pkg.signerDigests.isNotEmpty &&
                pkg.signerDigests.every(pkg.debugSignerDigests.contains),
            hasApproval: descriptor != null &&
                _approvals.any((a) => _same(a.pluginId, descriptor.pluginId)),
            settingsActivity: pkg.settingsActivity,
            installedVersionName: pkg.versionName,
            installedVersionCode: pkg.versionCode,
          );

      final PluginDescriptor descriptor;
      try {
        descriptor = PluginDescriptor.parse(pkg.descriptorJson);
      } on DescriptorException catch (e) {
        entries.add(
          entryFor(PluginStatus.incompatible, reason: pkg.problem ?? e.message),
        );
        continue;
      }
      final problem = pkg.problem ??
          (pkg.serviceClass != null &&
                  descriptor.serviceClass != pkg.serviceClass
              ? '描述符自称的服务类与实际声明插件 action 的服务不一致'
              : null);
      if (problem != null) {
        entries.add(
          entryFor(
            PluginStatus.incompatible,
            descriptor: descriptor,
            reason: problem,
          ),
        );
        continue;
      }
      final candidate = InstalledCandidate(
        descriptor: descriptor,
        installedPackage: pkg.packageName,
        actualSignerDigests: pkg.signerDigests,
      );
      final admission = policy.evaluate(
        candidate,
        alreadyRegistered: registered,
        approvals: _approvals,
      );
      final entry = switch (admission) {
        // 停用时不给绑定（不可调用）；批准记录仍在 _approvals 里，重新启用即恢复，不用再批。
        Admitted() when _disabled.contains(descriptor.pluginId.toLowerCase()) =>
          entryFor(
            PluginStatus.disabled,
            descriptor: descriptor,
            reason: '已停用',
          ),
        Admitted(:final binding) => entryFor(
            PluginStatus.ready,
            descriptor: descriptor,
            binding: binding,
          ),
        NeedsApproval(:final reason) => entryFor(
            PluginStatus.needsApproval,
            descriptor: descriptor,
            reason: reason,
          ),
        Rejected(:final reason) => entryFor(
            PluginStatus.rejected,
            descriptor: descriptor,
            reason: reason,
          ),
      };
      if (entry.status == PluginStatus.ready) {
        registered[descriptor.pluginId.toLowerCase()] = candidate;
      }
      entries.add(entry);
    }
    for (final MapEntry(key: package, value: descriptor) in _missing.entries) {
      entries.add(
        PluginEntry(
          status: PluginStatus.missing,
          descriptor: descriptor,
          packageName: package,
          reason: '安装包已不在设备上',
        ),
      );
    }
    state = List.unmodifiable(entries);
    _closeSessionsOfUnavailableProviders();
  }

  void _closeSessionsOfUnavailableProviders() {
    for (final handle in [..._sessions]) {
      final ready = readyEntry(handle.ref.providerId);
      if (ready != null) continue;
      _sessions.remove(handle);
      unawaited(handle.close());
    }
  }

  bool _hasApprovalFor(_Installed pkg) =>
      _approvals.any((a) => a.packageName == pkg.packageName);

  bool _isBuiltinId(String pluginId) {
    final lower = pluginId.toLowerCase();
    return lower.startsWith('builtin.') ||
        _builtins.any((d) => d.pluginId.toLowerCase() == lower);
  }

  static bool _same(String a, String b) => a.toLowerCase() == b.toLowerCase();

  static PluginDescriptor? _tryParse(String json) {
    try {
      return PluginDescriptor.parse(json);
    } on DescriptorException {
      return null;
    }
  }

  @override
  void dispose() {
    for (final handle in _sessions) {
      unawaited(handle.close());
    }
    _sessions.clear();
    super.dispose();
  }
}

/// 宿主的准入口径。外部插件由 Android 桥发现后喂进来（X02）。
///
/// 只有 debug 构建放行 Android 调试证书签的插件（仍要用户批准）；profile、release 一律拒收——
/// 每台开发机都有一张调试证书，谁都能拿来签（docs/15 §4，PLG15）。
final pluginRegistryProvider =
    StateNotifierProvider<PluginRegistry, List<PluginEntry>>(
  (ref) => PluginRegistry(
    policy: AdmissionPolicy(
      builtinIds: BuiltinPlugins.ids,
      allowDebugSigners: kDebugMode,
    ),
  ),
);
