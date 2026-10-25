/// 每台主机的本地连接记录（R25，参考 meshTerm 的事件记录）：每次连接走到了哪一步、每步用了多久、
/// 失败在哪一跳、断线后自动恢复试了几次。
///
/// 值都从已有的连接事件里取（[ConnectionAttempt] 上报的阶段、会话断开、自动恢复停下），不另开探测连接、
/// 不在后台轮询、不上传。
///
/// **只记元数据**（UX10、SEC12）：不记地址、用户名、主机名、报错原话、输入输出、登录 banner、私钥、口令、
/// check 链接。主机和跳板只记保险库里的 ID，显示时按保险库现在的名字查，导出时换成「主机 1」「跳板 1」。
/// 报错只记分类（[ConnectionFailureKind]）：原话里可能有地址和服务器送来的文字。
///
/// 用时一律按尝试自己的单调时钟算（[ConnectionAttempt.elapsed]）；墙上时钟只用来显示「几点」和算 7 天保留期。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/connection_route.dart';
import '../domain/host_identity.dart';
import '../domain/models/host.dart';
import '../infrastructure/ssh/ssh_service.dart';
import 'connection_diagnosis.dart';
import 'vault_controller.dart';

/// 每台主机最多留几条、一共最多留几条、留多久（R25 验收的上限）。超了就从最旧的删。
const connectionEventsPerHost = 200;
const connectionEventsTotal = 1000;
const connectionEventRetention = Duration(days: 7);

enum ConnectionEventKind {
  /// 从主机列表、菜单新开的连接。
  open,

  /// 用户在断开的标签上点了「重新连接」。
  reconnect,

  /// 断线后 App 自己试的恢复（R22）。
  restore,

  /// 标签里在 SSH 和 Mosh 之间原地切换（R42）。
  switchTransport,

  /// 「测试连接」。
  probe,

  /// 连着的会话断了。
  drop,

  /// 自动恢复停了、不再试。
  recoveryStopped,

  /// AI 命令行工具面板为检测、核对、启动临时拨的连接：用完就关，不变成标签。
  /// 新加的（10-25）：旧版 App 读到不认识的类型就跳过这一条（[ConnectionEvent.fromJson]），不影响其余的。
  aiCli,
}

enum ConnectionOutcome { connected, failed, cancelled }

enum ConnectionDropReason {
  /// 连接被关了：对方关的、网络断了 socket 报错，App 分不出是哪种。
  closed,

  /// 远端 shell 自己退出了（有退出码或信号）。
  exited,

  /// App 去探了一下（后台保活、换网络后），在期限内没回应。
  noResponse,

  /// 插件（Mosh）会话结束了。
  ended,
}

enum RecoveryStopReason {
  /// 断线后 2 分钟的自动恢复窗口到了。
  window,

  /// 断线时手机锁着，后台不重新登录（SEC07）。
  locked,

  /// 撞上了只能由人处理的错（指纹、凭据、路线改了……）。
  needsUser,
}

/// 第一跳怎么连：只记类型，不记代理地址和账号。
enum ConnectionEntryKind { direct, socks5, http }

class ConnectionEventStage {
  const ConnectionEventStage(
    this.step,
    this.hop,
    this.start, {
    this.userWait = Duration.zero,
  });

  final ConnectionStep step;

  /// 从 0 数的跳序号，和 [ConnectionStage.hop] 一样。
  final int hop;

  /// 从尝试开始算，这个阶段什么时候开始的。
  final Duration start;

  /// 其中等人的时间（确认指纹、输验证码）。
  final Duration userWait;
}

class ConnectionEvent {
  const ConnectionEvent({
    required this.hostId,
    required this.at,
    required this.kind,
    this.protocol,
    this.entry,
    this.hopIds = const [],
    this.stages = const [],
    this.outcome,
    this.total,
    this.failure,
    this.failureHop,
    this.attempt,
    this.connectedFor,
    this.dropReason,
    this.stopReason,
  });

  /// 保险库里的主机 ID（临时标签记来源主机）。
  final String hostId;

  /// 墙上时钟：这件事开始的时刻。只用来显示和算保留期，不拿来算用时。
  final DateTime at;
  final ConnectionEventKind kind;
  final HostProtocol? protocol;

  /// 连接类的事件才有；插件主机自己联网，没有。
  final ConnectionEntryKind? entry;

  /// 路线上的跳板加目标，按连接顺序，只记保险库 ID。路线还没算出来就是空的。
  final List<String> hopIds;
  final List<ConnectionEventStage> stages;
  final ConnectionOutcome? outcome;

  /// 这次尝试从开始到出结果的用时（单调时钟）。
  final Duration? total;
  final ConnectionFailureKind? failure;

  /// 失败在第几跳（从 0 数）；不是某一跳的错（配置、引擎、插件）为 null。
  final int? failureHop;

  /// 自动恢复的第几次；恢复停下时是一共试了几次。
  final int? attempt;

  /// 断开前连了多久（单调时钟）；不知道时为 null。
  final Duration? connectedFor;
  final ConnectionDropReason? dropReason;
  final RecoveryStopReason? stopReason;

  int get hopCount => hopIds.length;

  /// 拨号前的准备（建终端、读保险库、解私钥）用了多久：第一个阶段开始之前的那一段。
  /// 一个阶段都没到就结束的，就是整次的用时。
  Duration? get preparation => stages.isEmpty ? total : stages.first.start;

  /// 第 [index] 个阶段用了多久：到下一个阶段开始，最后一个到出结果。没有结果时间为 null（显示「未知」）。
  Duration? stageDuration(int index) {
    final end = index + 1 < stages.length ? stages[index + 1].start : total;
    if (end == null) return null;
    final value = end - stages[index].start;
    return value.isNegative ? null : value;
  }

  bool get isAttempt => switch (kind) {
        ConnectionEventKind.drop ||
        ConnectionEventKind.recoveryStopped =>
          false,
        _ => true,
      };

  Map<String, Object?> toJson() => {
        'h': hostId,
        'at': at.toUtc().millisecondsSinceEpoch,
        'k': kind.name,
        if (protocol != null) 'p': protocol!.name,
        if (entry != null) 'e': entry!.name,
        if (hopIds.isNotEmpty) 'hops': hopIds,
        if (stages.isNotEmpty)
          's': [
            for (final stage in stages)
              {
                'n': stage.step.name,
                'i': stage.hop,
                't': stage.start.inMicroseconds,
                if (stage.userWait > Duration.zero)
                  'w': stage.userWait.inMicroseconds,
              },
          ],
        if (outcome != null) 'o': outcome!.name,
        if (total != null) 'd': total!.inMicroseconds,
        if (failure != null) 'f': failure!.name,
        if (failureHop != null) 'fh': failureHop,
        if (attempt != null) 'n': attempt,
        if (connectedFor != null) 'c': connectedFor!.inMicroseconds,
        if (dropReason != null) 'r': dropReason!.name,
        if (stopReason != null) 'sr': stopReason!.name,
      };

  /// 读不懂的整条不要（返回 null）；只是失败分类这类可选的字段不认识（以后的版本写的），按未知留着。
  static ConnectionEvent? fromJson(Object? value) {
    if (value is! Map) return null;
    final hostId = value['h'];
    final at = value['at'];
    final kind = _byName(ConnectionEventKind.values, value['k']);
    if (hostId is! String || hostId.isEmpty || at is! int || kind == null) {
      return null;
    }
    final stages = <ConnectionEventStage>[];
    final rawStages = value['s'];
    if (rawStages is List) {
      for (final raw in rawStages) {
        if (raw is! Map) return null;
        final step = _byName(ConnectionStep.values, raw['n']);
        final hop = raw['i'];
        final start = raw['t'];
        final wait = raw['w'] ?? 0;
        if (step == null || hop is! int || start is! int || wait is! int) {
          return null;
        }
        stages.add(ConnectionEventStage(
          step,
          hop,
          Duration(microseconds: start),
          userWait: Duration(microseconds: wait),
        ));
      }
    }
    final hops = value['hops'];
    return ConnectionEvent(
      hostId: hostId,
      at: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
      kind: kind,
      protocol: _byName(HostProtocol.values, value['p']),
      entry: _byName(ConnectionEntryKind.values, value['e']),
      hopIds: hops is List ? [for (final id in hops) '$id'] : const [],
      stages: stages,
      outcome: _byName(ConnectionOutcome.values, value['o']),
      total: _micros(value['d']),
      failure: value['f'] == null
          ? null
          : _byName(ConnectionFailureKind.values, value['f']) ??
              ConnectionFailureKind.other,
      failureHop: value['fh'] is int ? value['fh'] as int : null,
      attempt: value['n'] is int ? value['n'] as int : null,
      connectedFor: _micros(value['c']),
      dropReason: _byName(ConnectionDropReason.values, value['r']),
      stopReason: _byName(RecoveryStopReason.values, value['sr']),
    );
  }

  static T? _byName<T extends Enum>(List<T> values, Object? name) =>
      values.where((value) => value.name == name).firstOrNull;

  static Duration? _micros(Object? value) =>
      value is int && value >= 0 ? Duration(microseconds: value) : null;
}

/// 一次连接尝试的记录。[error] 和 [cancelled] 都没有就是连上了。
///
/// 在结果出来的那一刻调：总用时取 [ConnectionAttempt.elapsed]，开始时刻是「现在减去总用时」。
ConnectionEvent attemptEvent({
  required String hostId,
  required DateTime now,
  required ConnectionEventKind kind,
  required HostProtocol protocol,
  required ConnectionAttempt attempt,
  RoutePlan? plan,
  Object? error,
  bool cancelled = false,
  int? recoveryAttempt,
}) {
  final total = attempt.elapsed;
  final failed = !cancelled && error != null;
  return ConnectionEvent(
    hostId: hostId,
    at: now.subtract(total),
    kind: kind,
    protocol: protocol,
    entry: switch (plan?.entry) {
      null => null,
      ProxyEntry(type: ProxyType.socks5) => ConnectionEntryKind.socks5,
      ProxyEntry(type: ProxyType.http) => ConnectionEntryKind.http,
      _ => ConnectionEntryKind.direct,
    },
    // 切换方式、tmux 开出来的临时副本记来源主机：副本的 ID 在保险库里查不到名字。
    hopIds: plan == null
        ? const []
        : [for (final hop in plan.hops) sourceHostIdOf(hop.host)],
    stages: [
      for (final timing in attempt.timeline)
        ConnectionEventStage(
          timing.stage.step,
          timing.stage.hop,
          timing.start,
          userWait: timing.userWait,
        ),
    ],
    outcome: cancelled
        ? ConnectionOutcome.cancelled
        : failed
            ? ConnectionOutcome.failed
            : ConnectionOutcome.connected,
    total: total,
    failure: failed ? classifyConnectionFailure(error) : null,
    failureHop: failed && error is RouteHopException ? error.hop : null,
    attempt: recoveryAttempt,
  );
}

/// 拨一次用完就关的连接（AI 工具面板的检测、核对、启动），并记一条 [kind]。
///
/// [dial] 在连上、开始在远端做事时调 `connected`：之后再出的错（检测脚本、tmux 核对、建 tmux 会话）
/// 不是连接的问题，照样记「连上了」，免得把「没装这个工具」记成网络失败；没连上就记失败在哪一类。
/// 错照样抛给调用方。
Future<T> loggedDial<T>(
  ConnectionEventLog log, {
  required ConnectionEventKind kind,
  required HostProfile host,
  required RoutePlan plan,
  required ConnectionAttempt attempt,
  required Future<T> Function(void Function() connected) dial,
}) async {
  var reached = false;
  Object? failure;
  try {
    return await dial(() => reached = true);
  } catch (error) {
    if (!reached) failure = error;
    rethrow;
  } finally {
    log.record(attemptEvent(
      hostId: host.id,
      now: DateTime.now(),
      kind: kind,
      protocol: host.protocol,
      attempt: attempt,
      plan: plan,
      error: failure,
      cancelled: failure is ConnectionCancelledException,
    ));
  }
}

/// 按上限修剪：超过 7 天的（以及记在「未来」一天以后的——系统时间被往回拨过，不删就会一直留着）、
/// 每台主机最新 200 条以外的、一共最新 1000 条以外的，都删掉。
///
/// 「新旧」按记录的先后（列表顺序）算，不按 [ConnectionEvent.at]：墙上时钟会跳。
List<ConnectionEvent> pruneConnectionEvents(
  List<ConnectionEvent> events,
  DateTime now,
) {
  final oldest = now.subtract(connectionEventRetention);
  final latest = now.add(const Duration(days: 1));
  final perHost = <String, int>{};
  final kept = <ConnectionEvent>[];
  for (final event in events.reversed) {
    if (event.at.isBefore(oldest) || event.at.isAfter(latest)) continue;
    final count = perHost.update(event.hostId, (n) => n + 1, ifAbsent: () => 1);
    if (count > connectionEventsPerHost) continue;
    kept.add(event);
    if (kept.length == connectionEventsTotal) break;
  }
  return kept.reversed.toList(growable: false);
}

abstract interface class ConnectionEventStore {
  Future<List<ConnectionEvent>> load();
  Future<void> save(List<ConnectionEvent> events);
}

/// 存在 App 私有目录的一个 JSON 文件里（`allowBackup=false`，不进备份；不进保险库导出和云同步）。
/// 不加密：里面只有主机 ID、阶段名、用时和失败分类。
class FileConnectionEventStore implements ConnectionEventStore {
  FileConnectionEventStore(this._directory);

  final Future<Directory> Function() _directory;

  Future<File> _file() async =>
      File('${(await _directory()).path}/connection_events.json');

  @override
  Future<List<ConnectionEvent>> load() async {
    final file = await _file();
    if (!await file.exists()) return const [];
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map || decoded['v'] != 1 || decoded['events'] is! List) {
      return const [];
    }
    return [
      for (final raw in decoded['events'] as List)
        if (ConnectionEvent.fromJson(raw) case final event?) event,
    ];
  }

  /// 先写临时文件再改名：写到一半被杀，旧记录还在，不会留下半个文件。
  @override
  Future<void> save(List<ConnectionEvent> events) async {
    final file = await _file();
    if (events.isEmpty) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      jsonEncode({
        'v': 1,
        'events': [for (final event in events) event.toJson()],
      }),
      flush: true,
    );
    await temp.rename(file.path);
  }
}

/// 测试用：只在内存里，[saved] 是最后一次写进去的 JSON 文本。
class MemoryConnectionEventStore implements ConnectionEventStore {
  MemoryConnectionEventStore([this.initial = const []]);

  final List<ConnectionEvent> initial;
  String? saved;
  int saves = 0;

  @override
  Future<List<ConnectionEvent>> load() async => initial;

  @override
  Future<void> save(List<ConnectionEvent> events) async {
    saves++;
    saved = jsonEncode([for (final event in events) event.toJson()]);
  }
}

class ConnectionEventLog extends StateNotifier<List<ConnectionEvent>> {
  ConnectionEventLog(this._store, {DateTime Function()? now})
      : _now = now ?? DateTime.now,
        super(const []) {
    _loaded = _load();
  }

  final ConnectionEventStore _store;
  final DateTime Function() _now;
  late final Future<void> _loaded;
  Future<void> _writes = Future<void>.value();

  /// 文件读完了（或读不了、放弃了）。
  Future<void> get ready => _loaded;

  Future<void> _load() async {
    List<ConnectionEvent> stored;
    try {
      stored = await _store.load();
    } on Object {
      // 文件坏了或读不了：记录只是辅助诊断，从空的开始，下次写的时候盖掉它。
      stored = const [];
    }
    if (!mounted) return;
    // 读的这一小会儿可能已经记了新的（App 一启动就放回标签、开始连），接在读出来的后面。
    state = pruneConnectionEvents([...stored, ...state], _now());
  }

  void record(ConnectionEvent event) {
    if (!mounted) return;
    state = pruneConnectionEvents([...state, event], _now());
    unawaited(_persist());
  }

  /// 把过了保留期的删掉（打开记录页时调：不在后台定时扫）。
  Future<void> prune() async {
    await _loaded;
    if (!mounted) return;
    final pruned = pruneConnectionEvents(state, _now());
    if (pruned.length == state.length) return;
    state = pruned;
    await _persist();
  }

  Future<void> clearHost(String hostId) => forgetHosts({hostId});

  /// 删掉这些主机的全部记录，写回文件后才返回。
  Future<void> forgetHosts(Set<String> hostIds) async {
    await _loaded;
    if (!mounted) return;
    state = state
        .where((event) => !hostIds.contains(event.hostId))
        .toList(growable: false);
    await _persist();
  }

  Future<void> clearAll() async {
    await _loaded;
    if (!mounted) return;
    state = const [];
    await _persist();
  }

  /// 写盘排队、总是写当时最新的；读完之前不写（不然会拿刚记的几条盖掉文件里的旧记录）。
  /// 写不进去不报错：连接不能因为记录写失败而出问题。
  Future<void> _persist() => _writes = _writes.then((_) async {
        await _loaded;
        if (!mounted) return;
        try {
          await _store.save(state);
        } on Object {
          // 见上
        }
      });
}

final connectionEventStoreProvider = Provider<ConnectionEventStore>(
  (ref) => FileConnectionEventStore(() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/diagnostics');
  }),
);

final connectionEventLogProvider =
    StateNotifierProvider<ConnectionEventLog, List<ConnectionEvent>>((ref) {
  final log = ConnectionEventLog(ref.watch(connectionEventStoreProvider));
  // 主机从保险库里没了（删除、导入替换、同步），它的记录跟着删。只看「两次都已载入」之间少了哪些：
  // 保险库还在读、读失败时主机列表是空的，照那个删就全没了。
  ref.listen<VaultState>(vaultControllerProvider, (previous, next) {
    final before = previous?.data;
    final after = next.data;
    if (before == null || after == null) return;
    if (previous!.loading || next.loading) return;
    if (previous.error != null || next.error != null) return;
    final kept = {for (final host in after.hosts) host.id};
    final gone = {
      for (final host in before.hosts)
        if (!kept.contains(host.id)) host.id,
    };
    if (gone.isNotEmpty) unawaited(log.forgetHosts(gone));
  });
  return log;
});
