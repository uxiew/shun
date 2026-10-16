import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  });
  final String id;
  final ForwardKind kind;
  final int localPort;
  final String? remoteHost;
  final int? remotePort;
  final ServerSocket? server;
  final SSHDynamicForward? dynamic;

  /// 开转发时用的是哪个标签、哪条 SSH 连接。转发只走这一条：它断了、被关了，转发也就不通了。
  /// R42 在终端里把这个标签切到 Mosh 会关掉这条 SSH，切之前按它列出会停掉哪几条（[forwardsOn]）。
  final String? sessionId;
  final SSHClient? client;

  /// 给人看的一行，和端口转发面板里写的一样。
  String describe() => kind == ForwardKind.dynamic
      ? 'SOCKS5 127.0.0.1:$localPort'
      : '127.0.0.1:$localPort → $remoteHost:$remotePort';

  Future<void> close() async {
    await server?.close();
    await dynamic?.close();
  }
}

final portForwardControllerProvider =
    StateNotifierProvider<PortForwardController, List<ActivePortForward>>(
  (ref) => PortForwardController(),
);

class PortForwardController extends StateNotifier<List<ActivePortForward>> {
  PortForwardController() : super(const []);

  Future<void> startLocal({
    required ActiveTerminalSession session,
    required int localPort,
    required String remoteHost,
    required int remotePort,
  }) async {
    final client = session.sshClient;
    if (client == null) throw StateError('需要活动 SSH 会话');
    final server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      localPort,
    );
    server.listen((socket) async {
      try {
        final channel = await client.forwardLocal(remoteHost, remotePort);
        unawaited(socket.cast<List<int>>().pipe(channel.sink));
        unawaited(channel.stream.cast<List<int>>().pipe(socket));
      } catch (_) {
        socket.destroy();
      }
    });
    state = [
      ...state,
      ActivePortForward(
        id: 'local-${server.port}-$remoteHost-$remotePort',
        kind: ForwardKind.local,
        localPort: server.port,
        remoteHost: remoteHost,
        remotePort: remotePort,
        server: server,
        sessionId: session.id,
        client: client,
      ),
    ];
  }

  Future<void> startDynamic({
    required ActiveTerminalSession session,
    required int localPort,
  }) async {
    final client = session.sshClient;
    if (client == null) throw StateError('需要活动 SSH 会话');
    final dynamic = await client.forwardDynamic(bindPort: localPort);
    state = [
      ...state,
      ActivePortForward(
        id: 'dynamic-${dynamic.port}',
        kind: ForwardKind.dynamic,
        localPort: dynamic.port,
        dynamic: dynamic,
        sessionId: session.id,
        client: client,
      ),
    ];
  }

  /// 挂在 [session] 这条 SSH 连接上的转发（按连接对象认，不按标签 id：断线恢复后同一个标签是新连接，
  /// 恢复前开的转发不在新连接上）。不是 SSH 的标签返回空。
  List<ActivePortForward> forwardsOn(ActiveTerminalSession session) {
    final client = session.sshClient;
    if (client == null) return const [];
    return [
      for (final item in state)
        if (identical(item.client, client)) item,
    ];
  }

  Future<void> stop(String id) async {
    ActivePortForward? item;
    for (final value in state) {
      if (value.id == id) {
        item = value;
        break;
      }
    }
    await item?.close();
    state = state.where((value) => value.id != id).toList();
  }
}
