import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../domain/ai_cli.dart';
import '../../domain/ai_cli_launch.dart';
import 'ai_cli_protocol.dart';
import 'ssh_service.dart';

class AiCliProbeCancellation {
  final _done = Completer<void>();
  bool get cancelled => _done.isCompleted;
  Future<void> get done => _done.future;
  void cancel() {
    if (!cancelled) _done.complete();
  }
}

/// Narrow channel seam so late-open, cancellation and output overflow can be
/// tested without mocking the route or introducing another SSH dial path.
abstract interface class AiCliProbeChannel {
  Stream<Uint8List> get stdout;
  Stream<Uint8List> get stderr;
  Future<void> writeScript(String script);
  Future<void> get done;
  int? get exitCode;
  void close();
}

class _SshProbeChannel implements AiCliProbeChannel {
  _SshProbeChannel(this.session);
  final SSHSession session;
  @override
  Stream<Uint8List> get stdout => session.stdout;
  @override
  Stream<Uint8List> get stderr => session.stderr;
  @override
  Future<void> get done => session.done;
  @override
  int? get exitCode => session.exitCode;
  @override
  void close() => session.close();
  @override
  Future<void> writeScript(String script) async {
    session.stdin.add(utf8.encode(script));
    await session.stdin.close();
  }
}

class AiCliDiscoveryService {
  const AiCliDiscoveryService({this.timeout = const Duration(seconds: 10)});
  final Duration timeout;

  Future<AiCliScanResult> discover(ActiveTerminalSession session,
      AiCliScanRequest request, AiCliProbeCancellation cancellation) async {
    final client = session.sshClient;
    bool valid() =>
        session.connected &&
        !session.closedByUser &&
        client != null &&
        !client.isClosed &&
        identical(client, session.sshClient);
    if (!valid()) throw const AiCliDiscoveryException('请先连接这台 SSH 主机');
    final guard = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!valid()) cancellation.cancel();
    });
    try {
      final result = await discoverClient(client!, request, cancellation);
      if (!valid()) throw const AiCliDiscoveryException('连接已失效，请重新检测');
      return result;
    } finally {
      guard.cancel();
    }
  }

  /// The client must already be verified/authenticated by SshService. This
  /// function only opens a query channel, and never dials or authenticates.
  Future<AiCliScanResult> discoverClient(SSHClient client,
      AiCliScanRequest request, AiCliProbeCancellation cancellation) async {
    if (client.isClosed) throw const AiCliDiscoveryException('连接已失效，请重新检测');
    final output = await runAiCliProbe(
      open: () async =>
          _SshProbeChannel(await client.execute('exec /bin/sh -s')),
      script: aiCliProbeScript(request),
      cancellation: cancellation,
      timeout: timeout,
    );
    if (client.isClosed || cancellation.cancelled) {
      throw const AiCliDiscoveryException('连接已失效或检测已取消');
    }
    return parseAiCliScan(output, request);
  }

  /// Resolve the chosen directory on the verified target without launching
  /// the CLI. The new PTY repeats the checks to handle changes after preflight.
  Future<String> canonicalProject(SSHClient client, AiCliLaunchSpec launch,
      AiCliProbeCancellation cancel) async {
    final output = await runAiCliProbe(
      open: () async =>
          _SshProbeChannel(await client.execute('exec /bin/sh -s')),
      script: launch.projectProbeScript,
      cancellation: cancel,
      timeout: timeout,
      maxBytes: 8192,
    );
    if (output == 'M\n') {
      throw const AiCliDiscoveryException('项目目录不存在或无法进入');
    }
    if (output == 'E\n') {
      throw const AiCliDiscoveryException('工具路径已失效，请重新检测');
    }
    if (!output.startsWith('P') || !output.endsWith('\n')) {
      throw const AiCliDiscoveryException('无法确认项目实际路径');
    }
    final directory = output.substring(1, output.length - 1);
    if (directory.contains('\n')) {
      throw const AiCliDiscoveryException('无法确认项目实际路径');
    }
    try {
      validateAiCliPath(directory);
    } on FormatException {
      throw const AiCliDiscoveryException('无法确认项目实际路径');
    }
    return directory;
  }
}

Future<String> runAiCliProbe({
  required Future<AiCliProbeChannel> Function() open,
  required String script,
  required AiCliProbeCancellation cancellation,
  required Duration timeout,
  int maxBytes = aiCliProbeMaxBytes,
}) async {
  if (cancellation.cancelled) throw const AiCliDiscoveryException('检测已取消');
  final stop = Completer<void>();
  final finished = Completer<void>();
  AiCliProbeChannel? channel;
  var closed = false;
  final subscriptions = <StreamSubscription<Uint8List>>[];
  void fail(String message) {
    if (!stop.isCompleted) stop.completeError(AiCliDiscoveryException(message));
  }

  // Attach the race handler before opening: an already closed/cancelled view can
  // never leave an unhandled error or a late-open channel behind.
  Future<T> race<T>(Future<T> future) => Future.any([
        future,
        stop.future.then<T>((_) => throw const AiCliDiscoveryException('检测已取消'))
      ]);
  final timer = Timer(timeout, () => fail('检测超时，已关闭查询通道'));
  unawaited(cancellation.done.then((_) {
    if (!closed) fail('检测已取消');
  }));
  try {
    final opening = open().then((value) {
      if (closed || cancellation.cancelled || stop.isCompleted) value.close();
      return value;
    });
    final active = await race(opening);
    channel = active;
    final bytes = BytesBuilder(copy: false);
    var consumed = 0, streams = 2;
    void collect(Uint8List chunk, {required bool stdout}) {
      consumed += chunk.length;
      if (consumed > maxBytes) {
        channel?.close();
        fail('检测输出超出上限，未采用不完整结果');
      } else if (stdout) {
        bytes.add(chunk);
      }
    }

    void done() {
      if (--streams == 0 && !finished.isCompleted) finished.complete();
    }

    subscriptions.add(active.stdout.listen((x) => collect(x, stdout: true),
        onDone: done, onError: (_) => fail('查询通道读取失败')));
    subscriptions.add(active.stderr.listen((x) => collect(x, stdout: false),
        onDone: done, onError: (_) => fail('查询通道读取失败')));
    await race(active.writeScript(script));
    await race(Future.wait([finished.future, active.done]));
    if (active.exitCode != 0) {
      throw const AiCliDiscoveryException('远端未能完成检测（需要 POSIX /bin/sh）');
    }
    return utf8.decode(bytes.takeBytes());
  } on FormatException {
    throw const AiCliDiscoveryException('检测输出编码无效');
  } finally {
    closed = true;
    timer.cancel();
    channel?.close();
    for (final sub in subscriptions) {
      unawaited(sub.cancel());
    }
  }
}
