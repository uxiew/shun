import 'descriptor.dart';

/// 一个已安装、待评估的候选 provider。
///
/// [actualSignerDigests] 必须来自系统（PackageManager 读出的安装包证书 SHA-256），
/// 不能来自描述符——描述符里根本没有签名字段，插件无法"自报"信任。
class InstalledCandidate {
  const InstalledCandidate({
    required this.descriptor,
    required this.installedPackage,
    required this.actualSignerDigests,
  });

  final PluginDescriptor descriptor;
  final String? installedPackage;
  final Set<String> actualSignerDigests;
}

/// 用户在授权页批准过的绑定：pluginId + 包名 + 证书 + 能力，四者都要对上。
class ApprovedBinding {
  const ApprovedBinding({
    required this.pluginId,
    required this.packageName,
    required this.signingDigest,
    required this.capabilities,
  });

  final String pluginId;
  final String? packageName;
  final String signingDigest;
  final Set<Capability> capabilities;
}

sealed class Admission {
  const Admission();
}

/// 可以进入 Ready。
class Admitted extends Admission {
  const Admitted(this.binding);
  final ApprovedBinding binding;
}

/// 结构正确，但需要用户（重新）批准；批准前不能开始任何会话。
class NeedsApproval extends Admission {
  const NeedsApproval(this.reason);
  final String reason;
}

/// 拒绝：冲突、冒用保留 ID、换签等。保持禁用，不会被遮蔽或覆盖。
class Rejected extends Admission {
  const Rejected(this.reason);
  final String reason;
}

/// 注册准入规则（docs/15 §3–§4，PLG01）。
///
/// - 内置 provider 的 ID 和 `builtin.` 前缀只属于宿主本身。
/// - 所有者登记的"官方 ID"绑定到固定证书；别的证书声称这个 ID 一律拒绝。
/// - 已占用的 ID 或包名不能被第二个 provider 抢占（不遮蔽已信任的 provider）。
/// - 换签（证书与批准时不同）不自动接受，禁用并要求重新核验。
class AdmissionPolicy {
  AdmissionPolicy({
    required this.builtinIds,
    this.reservedOfficialIds = const {},
    this.allowDebugSigners = false,
    this.debugSignerDigests = const {},
  });

  final Set<String> builtinIds;

  /// pluginId → 允许的证书 SHA-256。
  final Map<String, Set<String>> reservedOfficialIds;

  /// 只有明确的开发构建才为 true；release 不接受 debug 证书。
  final bool allowDebugSigners;
  final Set<String> debugSignerDigests;

  Admission evaluate(
    InstalledCandidate candidate, {
    required Map<String, InstalledCandidate> alreadyRegistered,
    required Iterable<ApprovedBinding> approvals,
  }) {
    final d = candidate.descriptor;
    final id = d.pluginId;
    final lower = id.toLowerCase();

    // 下面 bundled 分支不走批准直接放行，所以"单独安装的包自称内置"必须先挡掉：
    // 否则任何 APK 在描述符里写一句 deployment=bundled 就能跳过用户授权和证书核验。
    if (d.deployment == Deployment.bundled &&
        candidate.installedPackage != null) {
      return Rejected('$id 自称随包内置，但它是单独安装的包；内置 provider 只能由宿主登记');
    }
    if (d.deployment != Deployment.bundled &&
        (builtinIds.contains(lower) || lower.startsWith('builtin.'))) {
      return Rejected('$id 是内置 provider 保留 ID，外部包不能占用');
    }
    final official = reservedOfficialIds[lower];
    if (official != null &&
        candidate.actualSignerDigests.intersection(official).isEmpty) {
      return Rejected('$id 是登记过的官方 ID，但安装包证书不匹配');
    }
    for (final other in alreadyRegistered.values) {
      final o = other.descriptor;
      if (identical(other, candidate)) continue;
      if (o.pluginId.toLowerCase() == lower) {
        return Rejected('$id 已被另一个 provider 占用，不允许遮蔽');
      }
      if (candidate.installedPackage != null &&
          other.installedPackage == candidate.installedPackage) {
        return Rejected('包 ${candidate.installedPackage} 已注册为 ${o.pluginId}');
      }
    }
    if (d.deployment == Deployment.androidService &&
        candidate.installedPackage != d.packageName) {
      return Rejected('描述符声称的包名与实际安装包不一致');
    }
    if (d.deployment == Deployment.bundled) {
      // 内置 provider 跟随宿主签名，不走外部授权流程。
      return Admitted(
        ApprovedBinding(
          pluginId: id,
          packageName: null,
          signingDigest: 'host',
          capabilities: d.capabilities,
        ),
      );
    }
    final debugOnly =
        candidate.actualSignerDigests.isNotEmpty &&
        candidate.actualSignerDigests.every(debugSignerDigests.contains);
    if (debugOnly && !allowDebugSigners) {
      return const Rejected('debug 证书签名的插件只在开发构建中可用');
    }

    final approval = approvals
        .where((a) => a.pluginId.toLowerCase() == lower)
        .firstOrNull;
    if (approval == null) {
      return const NeedsApproval('首次安装：需要用户确认 pluginId、包名、证书和能力后才能启用');
    }
    if (approval.packageName != candidate.installedPackage) {
      return const Rejected('批准时的包名与当前安装包不同');
    }
    if (!candidate.actualSignerDigests.contains(approval.signingDigest)) {
      return const Rejected('安装包证书与批准时不同（换签），已禁用，需要重新核验');
    }
    if (!approval.capabilities.containsAll(d.capabilities)) {
      return const NeedsApproval('插件申请了批准范围之外的新能力，需要重新批准');
    }
    return Admitted(approval);
  }
}

class UnsupportedCapability implements Exception {
  const UnsupportedCapability(this.capability);
  final Capability capability;
  @override
  String toString() => '该 provider 不支持 ${capability.wire}';
}

/// 调用前核对：不支持的能力抛异常，绝不返回空列表或假成功（PLG02 / docs/18）。
void requireCapability(ApprovedBinding binding, Capability capability) {
  if (!binding.capabilities.contains(capability)) {
    throw UnsupportedCapability(capability);
  }
}
