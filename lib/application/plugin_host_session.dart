import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plugin_api/plugin_api.dart';

import '../domain/models/host.dart';
import '../domain/plugins/plugin_host.dart';
import '../infrastructure/ssh/ssh_service.dart';
import '../infrastructure/terminal/terminal_session_adapter.dart';
import 'plugin_discovery.dart';
import 'plugin_registry.dart';
import 'plugin_sessions.dart';
import 'plugin_terminal.dart';

/// 插件主机现在能不能连：能连时 [entry] 是那个可用的插件，否则 [problem] 是给用户看的原因。
typedef PluginHostAvailability = ({PluginEntry? entry, String? problem});

/// 这个 pluginId 的插件现在能不能用来开主机标签。连接前、编辑器、主机列表用的是同一个判断。
///
/// 只认「可用」的、声明了终端会话、**没有**申请临时会话凭据的插件：申请临时凭据的（Mosh）要先经 SSH 拿一次性材料，
/// 这条路给不了，Mosh 走自己的「Mosh」协议。
PluginHostAvailability pluginHostAvailability(
  List<PluginEntry> entries,
  String? pluginId,
) {
  if (pluginId == null) {
    return (entry: null, problem: '这台主机还没选插件：在编辑器里选一个。');
  }
  final same = entries
      .where((e) =>
          !e.isBuiltin && e.pluginId?.toLowerCase() == pluginId.toLowerCase())
      .toList();
  final ready = same.where((e) => e.status == PluginStatus.ready).firstOrNull;
  final seen = ready ?? same.firstOrNull;
  if (seen == null) {
    return (
      entry: null,
      problem: '没有装插件“$pluginId”。装好后到「设置 → 插件（实验）」核对证书并批准，再连。',
    );
  }
  final name = seen.descriptor?.displayName ?? pluginId;
  final reason = seen.reason ?? '';
  final problem = switch (seen.status) {
    PluginStatus.ready => _whyNotTerminal(seen.descriptor!, name),
    PluginStatus.needsApproval => '插件“$name”还没批准：到「设置 → 插件（实验）」核对证书后批准，再连。',
    PluginStatus.disabled => '插件“$name”被停用了：到「设置 → 插件（实验）」启用它，再连。',
    PluginStatus.missing => '插件“$name”已被卸载：装回同一证书的包会直接恢复，这台主机的设置还在。',
    PluginStatus.rejected => '插件“$name”被拒绝了：$reason',
    PluginStatus.incompatible => '插件“$name”和这个 App 不兼容：$reason',
  };
  return (entry: problem == null ? ready : null, problem: problem);
}

String? _whyNotTerminal(PluginDescriptor d, String name) {
  if (!d.capabilities.contains(Capability.terminalSession)) {
    return '插件“$name”没有声明终端会话能力（terminal-session），不能用来连接。';
  }
  if (d.permissions.contains(Permission.ownSessionEphemeralSecret)) {
    return '插件“$name”申请了本会话的临时凭据：这种插件（比如 Mosh）的会话要本 App 先经 SSH 拿一次性材料，'
        '不能用「插件」协议连。Mosh 主机请把协议选成 Mosh。';
  }
  return null;
}

/// 插件现在不能用来开这台主机的标签（没装、没批准、停用、带了代理设置…）。抛出时还没打开插件会话。
class PluginHostUnavailable implements Exception {
  const PluginHostUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 主机协议选了「插件」：用第三方终端插件开标签（所有者 2026-10-07 决定，X12）。
///
/// 每一步失败都停在那一步：
/// - 主机上留着代理、跳板设置：插件根本不走它们，直接拒绝，不悄悄去掉（[pluginHostRouteProblem]）。
/// - 插件没装、没批准、停用、被拒、不兼容、要临时凭据：还没碰插件，说明原因，不去拉起插件。
/// - 插件已经连着（别的标签、连接测试在用）就沿用那条连接，不重新握手：重新握手会断掉它正在跑的会话。
///
/// 不给插件任何主机数据：openSession 只带尺寸和字节流。插件连哪里由它自己的设置页决定，
/// 主机上的地址、用户名、密码、私钥一概不经过它。
class PluginHostConnector {
  PluginHostConnector(this._ref);

  final Ref _ref;

  /// 插件会话先按这个尺寸开；终端视图一量出实际尺寸就改过去（和 SSH 的 PTY、Mosh 一样）。
  static const _initialCols = 80;
  static const _initialRows = 24;

  Future<ActiveTerminalSession> connect({
    required String sessionId,
    required HostProfile host,
    required TerminalSessionAdapter terminal,
    required ConnectionAttempt attempt,
    required HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
  }) async {
    attempt.throwIfCancelled();
    final routeProblem = pluginHostRouteProblem(host);
    if (routeProblem != null) throw PluginHostUnavailable(routeProblem);
    final pluginId = pluginIdOf(host);
    attempt.report(ConnectionStage(
      ConnectionStep.pluginHost,
      label: pluginId ?? '',
    ));
    final discovery =
        await attempt.waitFor(_ref.read(pluginDiscoveryProvider.future));
    if (!discovery.supported) {
      throw const PluginHostUnavailable('插件只在 Android 上有。');
    }
    // App 启动时不自动发现插件（X04）：每次连之前向系统查一遍，顺带按当下的证书和描述符重新核对。
    await attempt.waitFor(discovery.start());
    final available = pluginHostAvailability(
      _ref.read(pluginRegistryProvider),
      pluginId,
    );
    final entry = available.entry;
    if (entry == null) throw PluginHostUnavailable(available.problem!);
    final name = entry.descriptor!.displayName;
    final check = await attempt.waitFor(discovery.check(entry));
    if (!check.ok) {
      throw PluginHostUnavailable('连不上插件“$name”：${check.message}');
    }
    attempt.report(ConnectionStage(ConnectionStep.pluginSession, label: name));
    final session = await attempt.waitFor(
      _ref
          .read(pluginSessionManagerProvider)
          .open(entry, cols: _initialCols, rows: _initialRows),
      onCancelled: (session) => unawaited(session.close()),
    );
    attempt.handOver();
    return PluginTerminalProvider.attach(
      PluginTerminalProvider(
        session,
        protocol: name,
        detail: '插件 ${entry.pluginId} 自己联网',
        endNotice: (session) => pluginHostEndNotice(session, name),
      ),
      sessionId: sessionId,
      host: host,
      terminal: terminal,
      verifyHostKey: verifyHostKey,
      keyboardInteractive: keyboardInteractive,
    );
  }
}

/// 插件会话为什么结束，给用户看的一句话。
String describePluginHostEnd(PluginTerminalSession session) {
  final failure = session.failure;
  // stopConfirmed 只在宿主自己发起关闭时才有值：null 说明是插件先结束的。
  return switch (session.phase) {
    SessionPhase.closed when failure != null => '插件报告失败（$failure）。',
    // 宿主自己关的：停用、撤销批准、插件更新时注册表关掉它（用户关标签时标签已经没了，看不到这句）。
    SessionPhase.closed when session.stopConfirmed == false =>
      '本 App 关掉了这个会话（插件被停用、撤销批准或更新），插件没有在 2 秒内确认已停止。',
    SessionPhase.closed when session.stopConfirmed == true =>
      '本 App 关掉了这个会话（插件被停用、撤销批准或更新），插件确认已停止。',
    SessionPhase.closed => '插件结束了这个会话。',
    SessionPhase.interrupted when failure != null => '插件报告失败（$failure）。',
    SessionPhase.interrupted => '插件关掉了这个会话，没说原因。',
    SessionPhase.providerDied => '插件进程没了（被系统或手动结束）。',
    SessionPhase.permissionRevoked => '插件被停用、撤销批准、更新或断开了连接，会话已关闭。',
    _ => '会话已结束。',
  };
}

/// 会话结束时写进终端的提示：原因、不会自动重连、不会重发输入、怎么再连。
String pluginHostEndNotice(PluginTerminalSession session, String name) {
  final reason = describePluginHostEnd(session);
  final normal = session.phase == SessionPhase.closed &&
      session.failure == null &&
      session.stopConfirmed == null;
  if (normal) return '\r\n\x1b[33m[$name] $reason不会自动重连。\x1b[0m\r\n';
  return '\r\n\x1b[31m[$name] $reason\x1b[0m\r\n'
      '\x1b[33m不会自动重连，也不会重发断开前的输入；断开前最后打的字插件有没有收到，App 无法确认。\r\n'
      '要再连，从保险库重新连接这台主机。\x1b[0m\r\n';
}

final pluginHostConnectorProvider = Provider(PluginHostConnector.new);

/// 让插件发现跑一次（App 启动时不自动发现，X04）：主机列表、编辑器要照实显示插件主机能不能用、有哪些插件能选。
/// 同一个 ProviderScope 里只跑一次；之后插件包的安装、更新、卸载由发现流程自己跟踪。
final pluginHostDiscoveryProvider = FutureProvider<void>((ref) async {
  final discovery = await ref.watch(pluginDiscoveryProvider.future);
  if (discovery.supported) await discovery.start();
});
