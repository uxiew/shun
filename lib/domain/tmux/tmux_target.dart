/// tmux 恢复目标（R21，docs/07「tmux恢复使用host/user/socket/server代次/session ID组成目标」）。
///
/// 为什么不能只记 session 名字：tmux 的 `-t 名字` 先精确匹配，找不到就按前缀、再按通配符匹配——
/// 实测 tmux 2.7 和 3.5a 上 `kill-session -t work` 在 work 已经不在时结束的是 workshop。
/// session ID（`$3`）也只在同一个 server 进程里唯一：server 重启后又从 `$0` 数起，
/// 所以还要记 server 的 pid 和启动时间（「server 代次」）以及 session 的创建时间。
library;

/// 用哪个 tmux server。对应 tmux 的 `-L 名字`（[named]）和 `-S 路径`（[path]）；
/// [standard] 就是不带参数时 tmux 自己用的 `-L default`。
enum TmuxSocketKind { standard, named, path }

class TmuxSocketSpec {
  const TmuxSocketSpec.standard()
      : kind = TmuxSocketKind.standard,
        value = '';

  const TmuxSocketSpec._(this.kind, this.value);

  /// `-L` 的名字只收字母、数字和 `_ . -`：它会被拼进路径，不能带 `/`，也不能是 `.`、`..`。
  factory TmuxSocketSpec.named(String name) {
    final value = name.trim();
    if (!_socketName.hasMatch(value) || value == '.' || value == '..') {
      throw const FormatException(
        'socket 名称只能用字母、数字和 _ . -，最长 64 个字符',
      );
    }
    return TmuxSocketSpec._(TmuxSocketKind.named, value);
  }

  /// `-S` 的路径必须是绝对路径，只收字母、数字和 `_ . / + @ -`：路径会作为命令参数传给远端，
  /// 收窄字符集比转义更不容易出错（SEC11）。含空格之类的路径请改用符号链接。
  factory TmuxSocketSpec.path(String path) {
    final value = path.trim();
    if (!_socketPath.hasMatch(value) || value.split('/').contains('..')) {
      throw const FormatException(
        'socket 路径必须是绝对路径，只能用字母、数字和 _ . / + @ -，最长 240 个字符',
      );
    }
    return TmuxSocketSpec._(TmuxSocketKind.path, value);
  }

  static final _socketName = RegExp(r'^[A-Za-z0-9_.-]{1,64}$');
  static final _socketPath = RegExp(r'^/[A-Za-z0-9_./+@-]{1,239}$');

  final TmuxSocketKind kind;
  final String value;

  /// 给人看的写法，和 tmux 命令行一致。
  String describe() => switch (kind) {
        TmuxSocketKind.standard => '默认 socket',
        TmuxSocketKind.named => '-L $value',
        TmuxSocketKind.path => '-S $value',
      };

  @override
  bool operator ==(Object other) =>
      other is TmuxSocketSpec && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);
}

/// 一个 tmux server 进程。pid 和启动时间合起来才算「同一个 server」：pid 会被复用。
class TmuxServerIdentity {
  const TmuxServerIdentity({
    required this.socketPath,
    required this.pid,
    required this.startTime,
  });

  /// 远端实际查询的 socket 文件路径（App 按 `TMUX_TMPDIR`、uid 和 socket 名算出来的那个）。
  final String socketPath;
  final int pid;

  /// server 启动时间（Unix 秒，tmux 的 `#{start_time}`）。
  final int startTime;

  @override
  bool operator ==(Object other) =>
      other is TmuxServerIdentity &&
      other.socketPath == socketPath &&
      other.pid == pid &&
      other.startTime == startTime;

  @override
  int get hashCode => Object.hash(socketPath, pid, startTime);

  @override
  String toString() => '$socketPath（server pid $pid）';
}

/// 一个 tmux 会话目标：哪台主机、哪个 Unix 用户、哪个 socket 上的哪一代 server 里的哪个 session。
///
/// 附着、结束、恢复都按它整体核对；任何一项对不上就当目标已经不在，不按名字找替身，也不新建（TMX04/TMX05）。
class TmuxTarget {
  const TmuxTarget({
    required this.hostKey,
    required this.unixUser,
    required this.uid,
    required this.socket,
    required this.server,
    required this.sessionId,
    required this.sessionCreated,
    required this.displayName,
  });

  /// 哪台主机：这条连接路线最终到达的目标地址（`主机:端口`）。
  /// 恢复和新标签都沿用同一条冻结的路线，指纹照常逐跳核对。
  final String hostKey;

  /// 远端 `id -un` / `id -u` 报的用户，不是主机配置里填的用户名。
  final String unixUser;
  final int uid;

  final TmuxSocketSpec socket;
  final TmuxServerIdentity server;

  /// tmux 的 `#{session_id}`，形如 `$3`。
  final String sessionId;

  /// session 创建时间（Unix 秒）。
  final int sessionCreated;

  /// 只给人看：已去掉控制字符，不参与任何比较或命令。
  final String displayName;

  /// 远端核对用的那一串，和 attach 脚本里 `display-message` 的输出逐字比较。
  String get guard =>
      '$sessionId:${server.pid}:${server.startTime}:$sessionCreated';

  bool sameAs(TmuxTarget other) =>
      other.hostKey == hostKey &&
      other.uid == uid &&
      other.socket == socket &&
      other.server == server &&
      other.sessionId == sessionId &&
      other.sessionCreated == sessionCreated;

  /// App 被系统结束后，标签靠它记住附着的是哪个目标（R22）。只有标识，没有凭据。
  Map<String, Object> toJson() => {
        'hostKey': hostKey,
        'unixUser': unixUser,
        'uid': uid,
        'socketKind': socket.kind.name,
        'socketValue': socket.value,
        'serverSocketPath': server.socketPath,
        'serverPid': server.pid,
        'serverStartTime': server.startTime,
        'sessionId': sessionId,
        'sessionCreated': sessionCreated,
        'displayName': displayName,
      };

  /// 读回 [toJson] 写的东西。socket 照新建时的白名单再核一遍，不认的整条丢掉（返回 null），
  /// 不拿一个读坏了的目标去远端核对。
  static TmuxTarget? fromJson(Map<String, Object?> json) {
    try {
      final socket = switch (json['socketKind']) {
        'standard' => const TmuxSocketSpec.standard(),
        'named' => TmuxSocketSpec.named(json['socketValue'] as String),
        'path' => TmuxSocketSpec.path(json['socketValue'] as String),
        _ => null,
      };
      final sessionId = json['sessionId'] as String;
      if (socket == null || !RegExp(r'^\$\d{1,9}$').hasMatch(sessionId)) {
        return null;
      }
      return TmuxTarget(
        hostKey: json['hostKey'] as String,
        unixUser: json['unixUser'] as String,
        uid: (json['uid'] as num).toInt(),
        socket: socket,
        server: TmuxServerIdentity(
          socketPath: json['serverSocketPath'] as String,
          pid: (json['serverPid'] as num).toInt(),
          startTime: (json['serverStartTime'] as num).toInt(),
        ),
        sessionId: sessionId,
        sessionCreated: (json['sessionCreated'] as num).toInt(),
        displayName: json['displayName'] as String,
      );
    } on Object {
      return null;
    }
  }

  @override
  String toString() => '$displayName（$sessionId，$unixUser@$hostKey，$server）';
}

/// 标签和它的 tmux 客户端的绑定：附着时远端报回来的终端设备和客户端 pid。
///
/// 只有它才能精确地分离「这个标签」：tmux 自己在没有 `-t` 时按「最近活动的客户端」猜，
/// 多个标签或电脑上也开着同一个会话时会猜错（TMX06）。
class TmuxClientBinding {
  const TmuxClientBinding({
    required this.target,
    required this.clientTty,
    required this.clientPid,
  });

  final TmuxTarget target;
  final String clientTty;
  final int clientPid;
}
