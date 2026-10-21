import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../infrastructure/ssh/ssh_lease.dart';
import '../infrastructure/ssh/ssh_service.dart';

enum ForwardKind { local, dynamic }

class ActivePortForward {
  ActivePortForward({
    required this.id,
    required this.kind,
    required this.localPort,
    this.remoteHost,
    this.remotePort,
    this.server,
    this.dynamic,
    this.sessionId,
    this.client,
    this.hostLabel,
    this.endedReason,
  });
  final String id;
  final ForwardKind kind;
  final int localPort;
  final String? remoteHost;
  final int? remotePort;
  final ServerSocket? server;
  final SSHDynamicForward? dynamic;

  /// 开转发时用的是哪个标签、哪条 SSH 连接。转发只走这一条：它断了、被关了，转发就停（R24）。
  /// R42 在终端里把这个标签切到 Mosh 会关掉这条 SSH，切之前按它列出会停掉哪几条（[forwardsOn]）。
  final String? sessionId;
  final SSHClient? client;

  /// 哪台主机的转发（主机在保险库里的名字）。面板列的是所有标签的转发，得写清楚是谁的。
  final String? hostLabel;

  /// 停下的原因；还在跑的为 null。连接断了、标签关了时由控制器写上：本机端口已经关掉，
  /// 条目留在列表里给人看，不会自己在新连接上重开。
  final String? endedReason;
  bool get running => endedReason == null;

  /// 给人看的一行，和端口转发面板里写的一样。
  String describe() => kind == ForwardKind.dynamic
      ? 'SOCKS5 127.0.0.1:$localPort'
      : '127.0.0.1:$localPort → $remoteHost:$remotePort';

  ActivePortForward _ended(String reason) => ActivePortForward(
        id: id,
        kind: kind,
        localPort: localPort,
        remoteHost: remoteHost,
        remotePort: remotePort,
        sessionId: sessionId,
        hostLabel: hostLabel,
        endedReason: reason,
      );

  Future<void> close() async {
    await server?.close();
    await dynamic?.close();
  }
}

final portForwardControllerProvider =
    StateNotifierProvider<PortForwardController, List<ActivePortForward>>(
  (ref) => PortForwardController(),
);

/// 端口转发。每条转发借一个标签上那一代的 SSH 连接（[SshLease]），只走它：
/// 它断了或标签关了，本机端口马上关掉、已经接进来的连接一并断掉，条目标成「已停止」。
/// 标签恢复成新连接后不自动重开：本机端口对手机上别的 App 开着，重开得用户自己点。
class PortForwardController extends StateNotifier<List<ActivePortForward>> {
  PortForwardController() : super(const []);

  /// 本地转发接进来的连接：转发停的时候一并断掉，不留半开的 socket。
  final _accepted = <String, Set<Socket>>{};

  /// 已停止的条目留在列表里，同一个端口可以再开一条：id 靠序号区分。
  var _serial = 0;

  Future<void> startLocal({
    required ActiveTerminalSession session,
    required int localPort,
    required String remoteHost,
    required int remotePort,
  }) async {
    final lease = SshLease.of(session);
    final ServerSocket server;
    try {
      server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        localPort,
      );
    } catch (_) {
      lease.release();
      rethrow;
    }
    final id = 'local-${server.port}-$remoteHost-$remotePort-${++_serial}';
    final sockets = _accepted[id] = <Socket>{};
    server.listen((socket) async {
      if (!lease.alive) {
        socket.destroy();
        return;
      }
      sockets.add(socket);
      unawaited(socket.done.then<void>((_) {}, onError: (_) {}).whenComplete(
            () => sockets.remove(socket),
          ));
      try {
        final channel = await lease
            .read((client) => client.forwardLocal(remoteHost, remotePort));
        unawaited(socket
            .cast<List<int>>()
            .pipe(channel.sink)
            .then<void>((_) {}, onError: (_) => socket.destroy()));
        unawaited(channel.stream
            .cast<List<int>>()
            .pipe(socket)
            .then<void>((_) {}, onError: (_) => socket.destroy()));
      } catch (_) {
        socket.destroy();
      }
    });
    state = [
      ...state,
      ActivePortForward(
        id: id,
        kind: ForwardKind.local,
        localPort: server.port,
        remoteHost: remoteHost,
        remotePort: remotePort,
        server: server,
        sessionId: session.id,
        client: lease.client,
        hostLabel: session.host.label,
      ),
    ];
    _endWhenLost(id, lease);
  }

  Future<void> startDynamic({
    required ActiveTerminalSession session,
    required int localPort,
  }) async {
    final lease = SshLease.of(session);
    final SSHDynamicForward dynamic;
    try {
      dynamic = await lease
          .read((client) => client.forwardDynamic(bindPort: localPort));
    } catch (_) {
      lease.release();
      rethrow;
    }
    final id = 'dynamic-${dynamic.port}-${++_serial}';
    state = [
      ...state,
      ActivePortForward(
        id: id,
        kind: ForwardKind.dynamic,
        localPort: dynamic.port,
        dynamic: dynamic,
        sessionId: session.id,
        client: lease.client,
        hostLabel: session.host.label,
      ),
    ];
    _endWhenLost(id, lease);
  }

  /// 借的连接没了（断线、标签关闭、切到 Mosh）：关掉本机端口和接进来的连接，条目标成已停止。
  /// 这步在会话释放时、关 SSH client 之前就跑（[ActiveTerminalSession.onRelease]）。
  void _endWhenLost(String id, SshLease lease) {
    lease.lost.then((_) {
      if (!mounted) return;
      final at = state.indexWhere((item) => item.id == id && item.running);
      if (at < 0) return;
      final item = state[at];
      _shut(item);
      final reason =
          lease.session.closedByUser ? '标签已关闭，转发已停止' : 'SSH 连接断开了，转发已停止；不会自动重开';
      state = [
        for (final value in state)
          if (identical(value, item)) item._ended(reason) else value,
      ];
    });
  }

  /// 关掉本机端口和接进来的连接。不等：连接已经死了时，SOCKS 那边关远端通道可能一直等不到回复。
  void _shut(ActivePortForward item) {
    unawaited(item.close().catchError((_) {}));
    for (final socket in _accepted.remove(item.id) ?? const <Socket>{}) {
      socket.destroy();
    }
  }

  /// 挂在 [session] 这条 SSH 连接上、还在跑的转发（按连接对象认，不按标签 id：断线恢复后同一个标签是新连接，
  /// 恢复前开的转发不在新连接上）。不是 SSH 的标签返回空。
  List<ActivePortForward> forwardsOn(ActiveTerminalSession session) {
    final client = session.sshClient;
    if (client == null) return const [];
    return [
      for (final item in state)
        if (item.running && identical(item.client, client)) item,
    ];
  }

  /// 停掉一条还在跑的转发，或者把一条已停止的从列表里去掉。
  Future<void> stop(String id) async {
    ActivePortForward? item;
    for (final value in state) {
      if (value.id == id) {
        item = value;
        break;
      }
    }
    if (item != null && item.running) {
      for (final socket in _accepted.remove(id) ?? const <Socket>{}) {
        socket.destroy();
      }
      await item.close();
    }
    state = state.where((value) => value.id != id).toList();
  }
}
