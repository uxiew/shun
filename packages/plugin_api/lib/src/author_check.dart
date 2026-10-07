// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 xwfe

import 'admission.dart';
import 'descriptor.dart';

/// 插件作者在构建前自查描述符（X12）。用的是宿主同一套判定代码，报出来的话和宿主插件页上的一致。
///
/// 只查「单独安装的 Android 插件」会碰到的那几条：描述符本身、部署方式、保留 ID、包名和服务类。
/// 证书、用户批准、Binder 上的认人是装到设备上之后的事，这里查不了，也不假装查过。
class AuthorCheck {
  AuthorCheck._(this.descriptor, this.errors, this.warnings);

  /// 解析成功时的描述符；描述符本身不合规时为 null。
  final PluginDescriptor? descriptor;

  /// 宿主会因此判「不兼容」或「已拒绝」的问题。
  final List<String> errors;

  /// 不会被拒，但多半不是你想要的。
  final List<String> warnings;

  bool get ok => errors.isEmpty;

  /// [packageName]、[serviceClass]：你的 applicationId 和声明插件 action 的服务类全名。
  /// 给了就核对描述符里写的是不是它们（宿主会拿实际安装包核对）；不给只查描述符本身。
  static AuthorCheck run(
    String json, {
    String? packageName,
    String? serviceClass,
  }) {
    final PluginDescriptor d;
    try {
      d = PluginDescriptor.parse(json);
    } on DescriptorException catch (e) {
      return AuthorCheck._(null, [e.message], const []);
    }
    final errors = <String>[];
    final warnings = <String>[];
    if (d.deployment != Deployment.androidService) {
      errors.add(
        '单独安装的插件 deployment 要写 android-service（现在是 ${d.deployment.wire}）',
      );
    }
    // 宿主的准入就是这一段：用一个占位证书、没有任何批准去评估，正常结果是「待批准」。
    final admission = AdmissionPolicy(builtinIds: const {}).evaluate(
      InstalledCandidate(
        descriptor: d,
        installedPackage: packageName ?? d.packageName,
        actualSignerDigests: const {'author-certificate'},
      ),
      alreadyRegistered: const {},
      approvals: const [],
    );
    if (admission is Rejected && !errors.contains(admission.reason)) {
      errors.add(admission.reason);
    }
    if (serviceClass != null && d.serviceClass != serviceClass) {
      errors.add(
        '描述符自称的服务类与实际声明插件 action 的服务不一致'
        '（描述符 ${d.serviceClass}，你给的 $serviceClass）',
      );
    }
    if (d.apiMinor > hostApiMinor) {
      warnings.add(
        'apiMinor ${d.apiMinor} 比宿主 $hostApiMajor.$hostApiMinor 新：'
        '宿主不认识的能力会被忽略、不可调用',
      );
    }
    if (d.ignoredNewerCapabilities.isNotEmpty) {
      warnings.add(
        '宿主 $hostApiMajor.$hostApiMinor 不认识这些能力，会忽略：'
        '${d.ignoredNewerCapabilities.join('、')}',
      );
    }
    if (!d.capabilities.contains(Capability.terminalSession)) {
      warnings.add(
        '没有声明 terminal-session：装上能批准，但宿主不会调用这个插件的任何能力——'
        '详情页没有「会话测试」，主机编辑器的「插件」里也选不到它',
      );
    }
    final unused = d.capabilities
        .where((c) => c != Capability.terminalSession)
        .map((c) => c.wire);
    if (unused.isNotEmpty) {
      warnings.add(
        '宿主现在只会用第三方插件的 terminal-session；${unused.join('、')} 能写、能批准，'
        '但宿主哪儿都不会调用它（见 docs/plugin-authors/capabilities.md）',
      );
    }
    if (d.permissions.contains(Permission.ownSessionEphemeralSecret)) {
      warnings.add(
        'own-session-ephemeral-secret 只给 Mosh 插件：别的插件写了也拿不到任何东西，'
        '会话测试和主机连接也都不给开，还会让用户以为你要凭据',
      );
    }
    if (d.capabilities.contains(Capability.terminalSession) &&
        !d.permissions.contains(Permission.ownSessionInputOutput)) {
      warnings.add(
        '声明了 terminal-session 却没申请 own-session-input-output：'
        '详情页的权限一栏会是空的，用户看不出它要收发会话数据',
      );
    }
    if (d.license == null) {
      warnings.add('没写 license：宿主详情页不显示许可证，用户不知道按什么条件用它');
    }
    return AuthorCheck._(
      d,
      List.unmodifiable(errors),
      List.unmodifiable(warnings),
    );
  }
}
