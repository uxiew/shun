import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 本 fork 对继承自上游、但不在 V3 范围内的功能的总开关，默认全关。
///
/// V3 计划要求 AI、云同步、更新检查在用户未授权前不可激活、不发任何网络请求
/// （plan/v3/AGENTS.md，用例 BAS02）。代码保留不删：以后所有者授权开启时改默认值即可，
/// 不必从上游找回被删的代码，也减少与上游合并时的冲突。
///
/// 做成 provider 而不是常量，是为了让测试能 override 成开启，验证开关两侧的行为。
class ForkFeatures {
  const ForkFeatures({
    this.ai = false,
    this.cloudSync = false,
    this.updateCheck = false,
  });

  /// shu Agent：终端工具栏的 AI 按钮、设置页的 AI 服务商入口。
  final bool ai;

  /// 设置页的云同步区与自动同步。关着时即使本地 settings 残留
  /// `autoSyncEnabled=true`（比如从上游数据导入）也不会启动同步。
  final bool cloudSync;

  /// 设置页的"检查更新"。上游实现会在冷启动时请求
  /// api.github.com/repos/kmh1145/Netcatty-mobile/releases/latest：
  /// 一是未经同意的外连，二是指向上游发布页，那边的 APK 是另一个 applicationId，
  /// 对本 fork 来说是错误的更新源。
  final bool updateCheck;
}

final forkFeaturesProvider =
    Provider<ForkFeatures>((ref) => const ForkFeatures());
