/// 连接生命周期的规矩（R22）：断线后什么时候自动恢复、恢复多久、什么错不自动重试、
/// 凭据副本留多久、App 被系统结束后留下什么。会话控制器照这里做，这里不碰网络和界面。
///
/// 所有者 2026-10-08 定的策略（SEC07）：
/// - 断线后自动恢复最多 [recoveryWindow]（2 分钟），只对「同一路线上的网络错误」重试（docs/07）；
///   指纹、凭据、路线配置、Tailscale check、tmux 目标不在了，一次都不重试，等用户。
/// - App 在后台、手机锁着时不重新登录：等用户解锁、回到 App 再恢复。
/// - App 在后台待满 [credentialLease]（10 分钟），标签冻结的凭据副本清出内存；
///   回到前台恢复时按同一路线从保险库重取，路线或身份变了就停下问。
/// - 不加应用锁：保险库启动时整个读进内存，这一点没变（使用手册写明）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/connection_route.dart';
import '../domain/models/host.dart';
import '../domain/restore_hold.dart';
import '../domain/tmux/tmux_target.dart';
import '../infrastructure/ssh/ssh_service.dart';
import '../infrastructure/transport/proxy_transport.dart';

export '../domain/restore_hold.dart';

/// 断线后最多自动恢复多久（docs/07 建议 120 秒）。过了就停，回到前台再给一轮，或者用户点「重新连接」。
const recoveryWindow = Duration(seconds: 120);

/// App 在后台待多久后清掉标签冻结的凭据副本（SEC07）。
const credentialLease = Duration(minutes: 10);

/// 换了网络后探一下连接还活不活：这么久没回 SSH 的 keepalive 就当它死了。
/// 宁长勿短：探得太急会把只是慢一点的蜂窝连接当死连接断掉（LIFE03「不无条件杀仍存活流」）。
const networkProbeTimeout = Duration(seconds: 15);

/// 自动恢复两次尝试之间等多久，按第几次算；超出列表就一直用最后一个。
const recoveryBackoff = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 5),
  Duration(seconds: 10),
  Duration(seconds: 15),
  Duration(seconds: 30),
];

/// 这个错过一会儿再试可能就好了吗：只有同一路线上的网络错误算（docs/07）。
///
/// 不认识的错一律算「不是」：宁可停下让用户看一眼，也不拿同一套凭据反复去撞。
bool isTransientConnectionError(Object error) {
  final cause = error is RouteHopException ? error.cause : error;
  return switch (cause) {
    SocketException() ||
    TimeoutException() ||
    ConnectStageException() ||
    SSHSocketError() ||
    SSHHandshakeError() =>
      true,
    ProxyHandshakeException(:final transient) => transient,
    // 指纹不对时 dartssh2 也报成 SSHAuthAbortError，原因里带着 SSHHostkeyError：那是要人看的。
    SSHAuthAbortError(reason: SSHHostkeyError()) => false,
    // 登录前被对端关掉：sshd 正在重启、并发握手满了（MaxStartups）时都会这样（LIFE04「远端 SSH 重启」）。
    SSHAuthAbortError() => true,
    // 跳板机转发不过去：下一跳正在重启时也是这样。
    SSHChannelOpenError() => true,
    _ => false,
  };
}

/// 自动恢复撞上不该重试的错时，停在哪、怎么说。
RestoreHold holdForError(Object error) =>
    RestoreHold.untilUser('自动恢复停了，没有再试：$error');

/// 断线期间路线或身份变了，自动恢复不换路线（NET10）。
class RouteChangedException implements Exception {
  const RouteChangedException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 标签的凭据副本清掉之后，按保险库补回来：同一台源主机、重算出来的路线形状和原来一样才用。
///
/// [sourceHostId] 是标签对应的保险库主机（tmux、托管终端这类临时标签记的是它们的来源主机）。
RoutePlan rehydrateRoutePlan(
  RoutePlan forgotten, {
  required String sourceHostId,
  required List<HostProfile> hosts,
  required List<ProxyProfile> proxyProfiles,
  required List<SshKeyProfile> keys,
}) {
  final source = hosts.where((value) => value.id == sourceHostId).firstOrNull;
  if (source == null) {
    throw const RouteChangedException('这台主机已经从保险库里删掉了，没有自动恢复。要连就重新从主机列表打开。');
  }
  final RoutePlan fresh;
  try {
    fresh = resolveRoutePlan(
      source,
      hosts: hosts,
      proxyProfiles: proxyProfiles,
      keys: keys,
    );
  } on RouteConfigException catch (error) {
    throw RouteChangedException('断线期间这台主机的连接路径改过，现在的配置有问题：$error');
  }
  if (fresh.shape != forgotten.shape) {
    throw const RouteChangedException(
      '断线期间这台主机的地址、代理、跳板机或登录身份改过。自动恢复只走原来那条路线，所以停了；点「重新连接」按现在的配置连。',
    );
  }
  return fresh;
}

/// 标签对应的保险库主机 ID。临时标签（tmux、托管终端）的 host 是拷出来的，ID 是新生成的，
/// 建它的时候把来源主机记在 [sourceHostIdKey] 里。
const sourceHostIdKey = '_sourceHostId';

String sourceHostIdOf(HostProfile host) =>
    host.data[sourceHostIdKey]?.toString() ?? host.id;

/// App 被系统结束（或强行停止）后，下次打开时要放回来的标签：只有「哪台主机、附着哪个 tmux 目标」，
/// 没有凭据、没有画面、没有输入（LIFE05「仅恢复配置/目标」）。放回来的标签是断开的，用户点了才连。
class RestorableTab {
  const RestorableTab({
    required this.id,
    required this.hostId,
    required this.label,
    this.tmux,
  });

  final String id;

  /// 保险库主机 ID（临时标签记来源主机）。
  final String hostId;
  final String label;
  final TmuxTarget? tmux;

  Map<String, Object?> toJson() => {
        'id': id,
        'hostId': hostId,
        'label': label,
        if (tmux != null) 'tmux': tmux!.toJson(),
      };

  static RestorableTab? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final hostId = value['hostId'];
    final label = value['label'];
    if (id is! String || hostId is! String || label is! String) return null;
    final tmuxJson = value['tmux'];
    final tmux = tmuxJson is Map
        ? TmuxTarget.fromJson(Map<String, Object?>.from(tmuxJson))
        : null;
    // 记着 tmux 却读不回来：宁可不放回这个标签，也不让它变成一个普通 shell 标签。
    if (tmuxJson != null && tmux == null) return null;
    return RestorableTab(id: id, hostId: hostId, label: label, tmux: tmux);
  }
}

/// [RestorableTab] 存在 SharedPreferences 里（App 私有目录，`allowBackup=false`，不进备份和导出）。
class RestorableTabsStore {
  RestorableTabsStore(this._preferences);

  static const _key = 'xwshun.r22.restorableTabs';

  final SharedPreferences _preferences;
  String? _written;

  List<RestorableTab> load() {
    final raw = _preferences.getString(_key);
    _written = raw;
    if (raw == null) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list
          .map(RestorableTab.fromJson)
          .whereType<RestorableTab>()
          .toList();
    } on FormatException {
      return const [];
    }
  }

  Future<void> save(List<RestorableTab> tabs) async {
    final raw = jsonEncode([for (final tab in tabs) tab.toJson()]);
    if (raw == _written) return;
    _written = raw;
    if (tabs.isEmpty) {
      await _preferences.remove(_key);
    } else {
      await _preferences.setString(_key, raw);
    }
  }
}
