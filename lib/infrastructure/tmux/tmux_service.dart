import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../domain/tmux/tmux_target.dart';
import '../ssh/ssh_service.dart';
import 'tmux_protocol.dart';

/// 在一条已经核对过指纹、登录好的 SSH 连接上执行 tmux 查询和显式操作（R21）。
///
/// 只用调用方给的那条连接（终端标签自己的），不另建连接、不换路线（docs/07：tmux 管理同一 RoutePlan）。
/// 每条命令都有期限和输出上限：远端 tmux 卡住、吐出几十 MB，App 到点就关通道、只看读到的那部分。
class TmuxService {
  const TmuxService({
    this.probeTimeout = const Duration(seconds: 10),
    this.actionTimeout = const Duration(seconds: 15),
  });

  final Duration probeTimeout;
  final Duration actionTimeout;

  /// 只读查询：用户、tmux 版本、socket、server 身份和 session 列表。
  /// socket 文件不在时不调用 tmux，所以不会起 server，也不会建 `/tmp/tmux-UID` 目录。
  Future<TmuxProbe> probe(SSHClient client, TmuxSocketSpec socket) async {
    final result = await _run(
      client,
      tmuxProbeCommand(socket),
      timeout: probeTimeout,
      maxBytes: tmuxProbeMaxBytes,
    );
    return parseTmuxProbe(result.output, truncated: result.truncated);
  }

  /// 显式新建一个 session（只建不附着），返回它的完整目标。
  ///
  /// [startupCommand] 是用户明确填的启动命令：建好后按字面输进新 session 的 shell，再补一个回车。
  /// 从 stdin 传过去，不进远端命令行（`ps` 看不到），也不被 tmux 当成键名解释。
  Future<TmuxTarget> create(
    SSHClient client, {
    required String hostKey,
    required String unixUser,
    required int uid,
    required TmuxSocketSpec socket,
    required String name,
    String startupCommand = '',
  }) async {
    final value = validateNewSessionName(name);
    final startup = startupCommand.trim();
    if (startup.length > tmuxStartupMaxLength) {
      throw const FormatException('启动命令太长（最多 $tmuxStartupMaxLength 个字符）');
    }
    final result = await _run(
      client,
      tmuxCreateCommand(socket, uid),
      stdin: '$value\n',
      timeout: actionTimeout,
      maxBytes: 64 * 1024,
    );
    final error = tmuxExitError(result.exitCode, result.output);
    if (error != null) throw error;
    final messages = <String>[];
    final row = parseCreatedSession(result.output, messages);
    if (row == null) {
      throw TmuxCommandException(
        messages.isEmpty
            ? '新建 tmux 会话失败'
            : '新建 tmux 会话失败：${messages.join('；')}',
      );
    }
    final target = targetOf(
      row,
      hostKey: hostKey,
      unixUser: unixUser,
      uid: uid,
      socket: socket,
      displayName: value,
    );
    if (startup.isNotEmpty) {
      await _action(client, tmuxStartupCommand(target), stdin: startup);
    }
    return target;
  }

  /// 结束一个 session：按 ID，先在远端核对它还是不是原来那个，不是就不动（不会按名字/前缀结束别的会话）。
  Future<void> kill(SSHClient client, TmuxTarget target) =>
      _action(client, tmuxKillCommand(target));

  /// 打开这一个 session 的鼠标模式，或者取消这个 session 自己的设置、回到全局。
  /// 不写 tmux.conf、不改全局选项；server 重启后自然失效（TMX07）。
  Future<void> setMouse(
    SSHClient client,
    TmuxTarget target, {
    required bool enable,
  }) =>
      _action(client, tmuxMouseCommand(target, enable: enable));

  /// 一个 session 的窗口和客户端，只读。目标不在了抛 [TmuxTargetGoneException]。
  Future<({List<TmuxWindowRow> windows, List<TmuxClientRow> clients})> details(
      SSHClient client, TmuxTarget target) async {
    final result = await _run(
      client,
      tmuxDetailsCommand(target),
      timeout: probeTimeout,
      maxBytes: 256 * 1024,
    );
    final error = tmuxExitError(result.exitCode, result.output);
    if (error != null) throw error;
    return parseTmuxDetails(result.output);
  }

  /// 分离一个确定的 tmux 客户端（标签附着时远端报回来的终端和 pid 都对上才分离）。
  Future<void> detach(SSHClient client, TmuxClientBinding binding) =>
      _action(client, tmuxDetachCommand(binding));

  Future<void> _action(SSHClient client, String command,
      {String? stdin}) async {
    final result = await _run(
      client,
      command,
      stdin: stdin,
      timeout: actionTimeout,
      maxBytes: 64 * 1024,
    );
    final error = tmuxExitError(result.exitCode, result.output);
    if (error != null) throw error;
  }

  /// 执行一条远端命令：到期限就关通道，输出读到 [maxBytes] 就停（远端吐 20 MB 也只占这么多内存）。
  /// 只给本类和测试用。
  @visibleForTesting
  Future<({String output, int? exitCode, bool truncated})> runBounded(
    SSHClient client,
    String command, {
    String? stdin,
    required Duration timeout,
    required int maxBytes,
  }) =>
      _run(client, command, stdin: stdin, timeout: timeout, maxBytes: maxBytes);

  Future<({String output, int? exitCode, bool truncated})> _run(
    SSHClient client,
    String command, {
    String? stdin,
    required Duration timeout,
    required int maxBytes,
  }) async {
    final deadline = Stopwatch()..start();
    Duration left() {
      final rest = timeout - deadline.elapsed;
      return rest.isNegative ? Duration.zero : rest;
    }

    final SSHSession session;
    try {
      session = await client.execute(command).timeout(left());
    } on TimeoutException {
      throw TmuxCommandException('远端在 ${timeout.inSeconds} 秒内没有回应，已放弃');
    }
    final buffer = BytesBuilder(copy: false);
    var truncated = false;
    final finished = Completer<void>();
    var open = 2;
    void collect(Uint8List chunk) {
      if (truncated) return;
      final room = maxBytes - buffer.length;
      if (chunk.length > room) {
        buffer.add(Uint8List.sublistView(chunk, 0, room));
        truncated = true;
        // 读够了就关通道，不再接收：远端吐 20 MB 也只占这么多内存（SEC11）。
        session.close();
        if (!finished.isCompleted) finished.complete();
        return;
      }
      buffer.add(chunk);
    }

    void streamDone() {
      if (--open == 0 && !finished.isCompleted) finished.complete();
    }

    final subscriptions = [
      session.stdout.listen(collect, onDone: streamDone, onError: (_) {}),
      session.stderr.listen(collect, onDone: streamDone, onError: (_) {}),
    ];
    try {
      if (stdin != null) session.stdin.add(utf8.encode(stdin));
      await session.stdin.close();
      await finished.future.timeout(left());
      if (!truncated) {
        await session.done.timeout(const Duration(seconds: 2));
      }
    } on TimeoutException {
      session.close();
      throw TmuxCommandException(
        '远端 tmux 在 ${timeout.inSeconds} 秒内没有完成，已放弃（远端命令可能还卡着）',
      );
    } finally {
      for (final subscription in subscriptions) {
        unawaited(subscription.cancel());
      }
    }
    return (
      output: utf8.decode(buffer.takeBytes(), allowMalformed: true),
      exitCode: truncated ? 0 : session.exitCode,
      truncated: truncated,
    );
  }
}

/// 一条连接最终到的是哪台主机：路线目标的 `地址:端口`。托管终端是主机配置的临时副本，id 每次不同，
/// 所以不用主机 id；同一条冻结路线到同一个地址，指纹在每次连接时照常核对。
String tmuxHostKeyOf(ActiveTerminalSession session) =>
    session.routePlan?.target.endpoint.authority ??
    '${session.host.hostname}:${session.host.port}';

TmuxTarget targetOf(
  TmuxSessionRow row, {
  required String hostKey,
  required String unixUser,
  required int uid,
  required TmuxSocketSpec socket,
  String? displayName,
}) =>
    TmuxTarget(
      hostKey: hostKey,
      unixUser: unixUser,
      uid: uid,
      socket: socket,
      server: row.server,
      sessionId: row.sessionId,
      sessionCreated: row.created,
      displayName: displayName ?? row.name,
    );
