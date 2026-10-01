import 'dart:async';

import 'package:dartssh2/dartssh2.dart';

import '../../domain/tailscale_ssh.dart';

/// Tailscale SSH 登录时要你处理的一件事：打开 check 链接，或者知道链接被拒了。
///
/// 只在内存里、只给界面用。check 链接带一次性 token，不进日志、报错、诊断（docs/05）：
/// [toString] 不含链接，界面也只显示域名。
class TailscaleCheckPrompt {
  const TailscaleCheckPrompt({
    required this.hop,
    required this.hopCount,
    required this.hostLabel,
    required this.endpoint,
    required this.sourceNode,
    required this.banner,
    required this.deadline,
  });

  /// 从 0 数的跳序号，[hopCount] 是跳板数 + 1。
  final int hop;
  final int hopCount;
  final String hostLabel;

  /// 这一跳的 SSH 地址（已核对过指纹的那台）。
  final String endpoint;

  /// Tailscale 会把这次登录算成哪台节点发起的（见 tailscaleSourceNode）。
  final String sourceNode;

  /// [CheckLinkBanner]（可以打开）或 [RejectedLinkBanner]（不打开）。
  final AuthBanner banner;

  /// 最晚等到什么时候，过了就放弃这次连接。
  final DateTime deadline;

  CheckLinkBanner? get link =>
      banner is CheckLinkBanner ? banner as CheckLinkBanner : null;

  @override
  String toString() => 'TailscaleCheckPrompt(hop $hop, $hostLabel, $banner)';
}

/// Tailscale 拒绝了这次登录。它拒绝时不发「认证失败」，只发一条 banner 就断开 TCP
/// （tailssh v1.104.0 的 errDenied / errTerminal），所以这里靠 banner 区分「拒绝」和「网络断了」。
class TailscaleLoginDenied implements Exception {
  const TailscaleLoginDenied(this.serverMessage);

  /// 服务器发来的最后一条无链接 banner（已清洗）；没有时为 null。
  final String? serverMessage;

  @override
  String toString() => serverMessage == null
      ? '登录完成前连接断了：可能是 Tailscale 不让你登录（它拒绝时可以不给原因就断开），也可能是网络断了'
      : 'Tailscale 拒绝了这次登录，服务器说：$serverMessage';
}

/// 等登录结果超时了。[checkPending] 为 true 表示是在等你做 check 时超时的。
class SshLoginTimeout implements Exception {
  const SshLoginTimeout(this.waited, {required this.checkPending});

  final Duration waited;
  final bool checkPending;

  @override
  String toString() => checkPending
      ? '等 Tailscale check 超过 ${waited.inMinutes} 分钟，已放弃这次连接；没有执行任何命令'
      : '${waited.inSeconds} 秒内没有等到登录结果，已放弃';
}

/// 普通 SSH 模式下，服务器没要任何凭据就放行了（none 认证）。
///
/// dartssh2 2.22.5 会在所有方法都失败后自动再试一次 none（ssh_client.dart `_startAuthentication`），
/// 没有开关能关掉。对 Tailscale SSH 来说这等于用 tailnet 身份登录了——用户选的却是普通 SSH。
/// 所以登录成功后再核对一次，是 none 就关掉（docs/05「可检测的策略保证」）。
class StandardLoginFellBackToNone implements Exception {
  const StandardLoginFellBackToNone();

  @override
  String toString() => '服务器没要任何密码或私钥就让登录了（none 认证），普通 SSH 不接受这种登录，已断开。'
      '这台机器开着 Tailscale SSH 的话，在编辑器里把登录方式改成「Tailscale SSH」；'
      '否则检查服务器是不是允许空密码登录';
}

/// 普通 SSH 模式下，服务器在登录途中发来了带链接的 banner（Tailscale check 就是这样）。
class StandardLoginGotCheckLink implements Exception {
  const StandardLoginGotCheckLink();

  @override
  String toString() => '服务器要求另外到浏览器里认证（发来了带链接的提示），普通 SSH 不处理这种认证，已断开。'
      '这台机器开着 Tailscale SSH 的话，在编辑器里把登录方式改成「Tailscale SSH」';
}

/// 自动恢复连接时遇到 Tailscale check。自动恢复不替你处理 check（docs/07：外部 check 必须人工处理）。
class TailscaleCheckNeedsUser implements Exception {
  const TailscaleCheckNeedsUser();

  @override
  String toString() => 'Tailscale 要求重新做 check，自动恢复不会替你处理。关掉这个标签，从主机列表重新连接';
}

/// 一跳 SSH 登录的旁观者：记下指纹有没有确认、banner 说了什么、dartssh2 有没有试 none，
/// 并决定这一跳等登录结果等多久。每个 SSHClient 配一个，不复用。
class SshLoginWatch {
  SshLoginWatch({
    required this.mode,
    required this.allowCheck,
    required this.authWait,
    required this.checkWait,
    required this.describePrompt,
    required this.onPrompt,
  });

  final SshLoginMode mode;

  /// 能不能在这次连接里做 check：用户新开、测试连接可以；自动恢复不行。
  final bool allowCheck;

  /// 普通的登录期限（主机的「认证超时」）。Tailscale 模式在收到链接前也用它。
  final Duration authWait;

  /// 收到 check 链接之后改用的期限：要留出开浏览器、登录 Tailscale 的时间，不能沿用几十秒的网络期限（docs/04）。
  final Duration checkWait;

  final TailscaleCheckPrompt Function(AuthBanner banner, DateTime deadline)
      describePrompt;
  final void Function(TailscaleCheckPrompt? prompt) onPrompt;

  bool _hostKeyAccepted = false;
  bool _noneAttempted = false;
  bool _checkPending = false;
  PlainAuthBanner? _lastPlain;
  Object? _abort;
  Timer? _timer;
  Completer<void>? _result;
  SSHClient? _client;

  /// 指纹核对通过之后才算数的 banner 里，最后一条无链接的（Tailscale 拒绝的原因就在这里）。
  String? get lastServerMessage => _lastPlain?.text;

  /// 在 dartssh2 的指纹回调里，确认通过时调用。
  ///
  /// Tailscale 模式的登录期限从这里才开始算：指纹确认框是在等人看、等人点，
  /// 不能吃掉登录的时间（docs/04）。dartssh2 自己的 authTimeout 也是指纹确认后才起算。
  /// 以前从建 client 就开始计时，模拟器上在确认框停了 30 多秒，点完就报「30 秒内没有等到登录结果」。
  void hostKeyAccepted() {
    _hostKeyAccepted = true;
    final result = _result;
    if (mode == SshLoginMode.tailscale &&
        result != null &&
        !result.isCompleted &&
        _timer == null) {
      _arm(authWait);
    }
  }

  /// 接 dartssh2 的 printDebug。只认一句话：它要发 none 认证了；其余一概丢掉，不打印、不留存
  /// （有些调试信息里带 banner 原文，也就是 check 链接）。
  ///
  /// 依赖 dartssh2 2.22.5 的调试文字 `SSHClient._authWithNone`。升级 dartssh2 时
  /// test/tailscale_ssh_login_test.dart 的「普通模式拒绝 none」会在这里失效时报错（plan/v3/docs/12）。
  void debug(String? message) {
    if (message == 'SSHClient._authWithNone') _noneAttempted = true;
  }

  /// 接 dartssh2 的 onUserauthBanner。
  void banner(String raw) {
    // 指纹没确认前到的 banner 一律不理：dartssh2 不管当时处在哪一步都会回调它，
    // 恶意服务器可以趁指纹确认框还开着塞一条链接进来（docs/05：host trust 先于外部浏览器）。
    if (!_hostKeyAccepted || _result?.isCompleted == true) return;
    final value = classifyAuthBanner(raw);
    switch (value) {
      case PlainAuthBanner():
        _lastPlain = value;
      case CheckLinkBanner() || RejectedLinkBanner():
        if (mode == SshLoginMode.standard) {
          _fail(const StandardLoginGotCheckLink());
        } else if (!allowCheck) {
          _fail(const TailscaleCheckNeedsUser());
        } else {
          _checkPending = true;
          final deadline = DateTime.now().add(checkWait);
          _arm(checkWait);
          onPrompt(describePrompt(value, deadline));
        }
    }
  }

  /// 等这一跳登录完成。失败时抛出说得清原因的异常；超时或中途判定失败时会关掉 [client]。
  Future<void> authenticated(SSHClient client) {
    _client = client;
    final result = _result = Completer<void>();
    final abort = _abort;
    if (abort != null) {
      client.close();
      return Future.error(abort);
    }
    // 普通模式的期限仍由 dartssh2 的 authTimeout 管（键盘交互要等人输验证码，原来就是这样）；
    // Tailscale 模式不交给它，因为收到 check 链接后要换成长得多的期限。期限从指纹确认后起算（见 [hostKeyAccepted]）。
    if (mode == SshLoginMode.tailscale && _hostKeyAccepted) _arm(authWait);
    client.authenticated.then(
      (_) {
        if (result.isCompleted) return;
        _finish();
        if (mode == SshLoginMode.standard && _noneAttempted) {
          client.close();
          result.completeError(const StandardLoginFellBackToNone());
          return;
        }
        result.complete();
      },
      onError: (Object error, StackTrace stack) {
        if (result.isCompleted) return;
        _finish();
        result.completeError(_explain(error), stack);
      },
    );
    return result.future;
  }

  Object _explain(Object error) {
    if (mode != SshLoginMode.tailscale || !_hostKeyAccepted) return error;
    if (error is SSHAuthAbortError || error is SSHAuthFailError) {
      return TailscaleLoginDenied(_lastPlain?.text);
    }
    return error;
  }

  void _arm(Duration wait) {
    _timer?.cancel();
    _timer = Timer(wait, () {
      final result = _result;
      if (result == null || result.isCompleted) return;
      final checkPending = _checkPending;
      _finish();
      _client?.close();
      result.completeError(SshLoginTimeout(wait, checkPending: checkPending));
    });
  }

  void _fail(Object error) {
    final result = _result;
    if (result == null) {
      // 还没开始等（理论上不会：banner 只在认证阶段到）。记下，开始等时立刻失败。
      _abort ??= error;
      return;
    }
    if (result.isCompleted) return;
    _finish();
    _client?.close();
    result.completeError(error);
  }

  void _finish() {
    _timer?.cancel();
    _timer = null;
    if (_checkPending) {
      _checkPending = false;
      onPrompt(null);
    }
  }
}
