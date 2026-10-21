import 'dart:async';

import 'package:dartssh2/dartssh2.dart';

import 'ssh_service.dart';

/// 借来的连接已经断了（或者标签已经换成了新连接），这一步没有发出去：服务器上什么都没变。
/// 只读的一步（列目录、读文件、采样）中途断了也是它：读不改东西。
class ConnectionGone implements Exception {
  const ConnectionGone(this.hostLabel);

  final String hostLabel;

  @override
  String toString() => '$hostLabel 的 SSH 连接已断开，这一步没有执行。这里不会自己重连，也不会改走别的路线：'
      '回到终端标签重新连接后，再从新连接打开。';
}

/// 会改动服务器的一步已经发出去了，等结果时连接断了：服务器上做没做成，手机这边无从知道。
/// 不自动重试——重发一次「删除」「重启」「覆盖」未必无害。
class OutcomeUnknown implements Exception {
  const OutcomeUnknown(this.action);

  /// 给人看的那一步，比如「删除 /tmp/a」。
  final String action;

  @override
  String toString() => '$action：请求发出后连接断了，不知道服务器上有没有做成。不会自动重试；重新连接后先看一眼再决定。';
}

/// 借用标签上那条已登录的 SSH 连接（R24）。文件页、性能监控、系统管理、端口转发都从这里借。
///
/// 借的是「这一代」：借的那一刻标签用的是哪个 [SSHClient]，之后就只用它。标签断线后恢复成新连接，
/// 旧的借用不跟过去，只会报 [ConnectionGone] / [OutcomeUnknown]；借用者自己从不拨号、不重连、
/// 不改走别的路线（RTE04、REG01，docs/03）。
///
/// 每个操作都和「连接断了」赛跑：dartssh2 2.22.5 的 SFTP 在连接断掉后不再回复还在等的请求，
/// 不赛跑的话上传、列目录会永远等下去（R24 实测：断线后 15 秒仍不返回，进度条一直挡着别的传输）。
class SshLease {
  SshLease._(this.session, this.client) {
    _forget = session.onRelease(_markLost);
    client.done.then((_) => _markLost(), onError: (_) => _markLost());
  }

  /// 借 [session] 现在的那条 SSH 连接。已经断开、或者根本不是 SSH（Telnet、Mosh）就报 [ConnectionGone]。
  factory SshLease.of(ActiveTerminalSession session) {
    final client = session.sshClient;
    if (client == null || !session.connected || client.isClosed) {
      throw ConnectionGone(session.host.label);
    }
    return SshLease._(session, client);
  }

  /// 同一个借用者对同一个会话只借一次，存在 [cache] 里。每次借都会在标签上登记一个释放钩子，
  /// 按命令借的话，每 3 秒采样一次的监控会把钩子越攒越多。会话对象就是一代连接，它断了也不会再连上，
  /// 所以借用失效以后重新借只会得到 [ConnectionGone]。
  static SshLease reuse(
      Expando<SshLease> cache, ActiveTerminalSession session) {
    final cached = cache[session];
    if (cached != null && cached.alive) return cached;
    return cache[session] = SshLease.of(session);
  }

  final ActiveTerminalSession session;
  final SSHClient client;
  final _lost = Completer<void>();
  late final void Function() _forget;

  String get hostLabel => session.host.label;

  /// 借的这条连接还能用。一旦变成 false 就不会再变回来——恢复出来的是另一条连接、另一个借用。
  bool get alive => !_lost.isCompleted && session.connected && !client.isClosed;

  /// 这条连接断了、或标签释放了它时完成。
  Future<void> get lost => _lost.future;

  void _markLost() {
    if (_lost.isCompleted) return;
    _lost.complete();
    _forget();
  }

  /// 借用者自己不用了（比如开转发时本机端口被占了）：撤销在标签上的登记，之后按已失效处理。
  /// 不关连接——连接归标签。
  void release() => _markLost();

  /// 还能用就返回 client，不然报 [ConnectionGone]（什么都还没发）。
  SSHClient check() {
    if (!alive) throw ConnectionGone(hostLabel);
    return client;
  }

  /// 只读的一步。先断的、中途断的，都报 [ConnectionGone]；别的错（没有这个文件……）原样抛。
  Future<T> read<T>(Future<T> Function(SSHClient client) work) async {
    final value = check();
    try {
      return await _raceLoss(work(value));
    } catch (_) {
      if (!alive) throw ConnectionGone(hostLabel);
      rethrow;
    }
  }

  /// 会改动服务器的一步（写文件、删除、改名、停止/重启这类命令），[action] 写给人看。
  /// 发出去之前就断了 → [ConnectionGone]（确定没做）；发出去以后断了 → [OutcomeUnknown]。
  Future<T> write<T>(
    String action,
    Future<T> Function(SSHClient client) work,
  ) async {
    final value = check();
    try {
      return await _raceLoss(work(value));
    } catch (_) {
      if (!alive) throw OutcomeUnknown(action);
      rethrow;
    }
  }

  /// 只读的字节流（下载、预览）。连接一断就报 [ConnectionGone] 并结束，不等 dartssh2 那个永远不来的回复。
  ///
  /// 取消时不等里面那个流关完：连接已经死了的话，它关文件句柄也会一直等下去。
  Stream<T> readStream<T>(Stream<T> source) {
    late final StreamController<T> controller;
    StreamSubscription<T>? subscription;
    void lostNow() {
      if (controller.isClosed) return;
      controller.addError(ConnectionGone(hostLabel));
      unawaited(controller.close());
      unawaited(subscription?.cancel());
    }

    controller = StreamController<T>(
      onListen: () {
        if (!alive) return lostNow();
        subscription = source.listen(
          controller.add,
          onError: (Object error, StackTrace stack) {
            if (!alive) return lostNow();
            controller.addError(error, stack);
          },
          onDone: () {
            if (!controller.isClosed) unawaited(controller.close());
          },
        );
        lost.then((_) => lostNow());
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () {
        unawaited(subscription?.cancel());
      },
    );
    return controller.stream;
  }

  Future<T> _raceLoss<T>(Future<T> work) {
    final result = Completer<T>();
    work.then(
      (value) {
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    lost.then((_) {
      if (!result.isCompleted) result.completeError(ConnectionGone(hostLabel));
    });
    return result.future;
  }
}
