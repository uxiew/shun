/// tmux 远端命令的构造和输出解析（R21）。纯函数，不碰网络，方便逐条测。
///
/// 所有命令都长一个样：sh -c 加单引号里的固定脚本，再跟 shun 和若干个单引号包着的参数。
/// - 脚本是写死的常量：不含单引号、`!`、连续反斜杠和换行，所以不管远端登录 shell 是 sh、bash、zsh、
///   fish 还是 csh，单引号里的内容都原样交给 sh（fish 的单引号只认 `\'` 和 `\\`，csh 会在单引号里展开 `!`）。
/// - 会变的东西只作为位置参数进去，而且事先按白名单校验过（socket 名/路径、uid、`$3` 这种 ID、纯数字）。
///   session 名字、启动命令这类自由文本从 stdin 进去，从不拼进命令行（SEC11）。
/// - 远端输出先用 `head`/`cut` 截短，App 这边读取时再按字节数封顶（[tmuxProbeMaxBytes]）。
///
/// 查询只读：一律用 `-S 路径` 指定 socket。不带 `-S` 时，`tmux list-sessions` 在没有 server 的情况下
/// 虽然不起 server，却会先建 `/tmp/tmux-UID` 目录（实测 3.5a）；带 `-S` 不建。另外先看 socket 文件在不在，
/// 不在就不调用 tmux，直接回答「没有 server」，不用去认各版本不同的报错文字。
library;

import 'dart:convert';

import '../../domain/tmux/tmux_target.dart';
import '../../domain/tmux/ai_cli_tmux_run.dart';

/// 已经在真实 tmux 上走过全部测试的最老版本。更老的退回普通 SSH，不提供附着、新建、结束（R21 停止条件）。
const tmuxOldestTested = TmuxVersion(2, 4);

/// 实测过的版本，界面和证据里照这个写，不多说。
const tmuxTestedVersions = '2.4、2.7、3.0a、3.5a';

/// 查询输出读到这么多字节就停（远端已截到约 1 MB）。
const tmuxProbeMaxBytes = 1536 * 1024;

/// 最多显示多少个 session；远端 `head` 按行数截，多出来的标「输出过长」。
const tmuxMaxSessions = 1000;

/// 远端脚本的约定退出码。
abstract final class TmuxExit {
  /// 远端没有 tmux。
  static const missing = 95;

  /// 当前登录的 Unix 用户不是目标记录的那个（uid 不同）。
  static const wrongUser = 96;

  /// 目标不在了，或者已经不是同一个：socket 没了、server 换了一代、session 被结束、同号新 session。
  static const targetGone = 97;

  /// 要分离的那个 tmux 客户端已经不在了。
  static const clientGone = 98;
}

class TmuxVersion implements Comparable<TmuxVersion> {
  const TmuxVersion(this.major, this.minor, [this.suffix = '']);

  final int major;
  final int minor;
  final String suffix;

  /// 认 `tmux 3.5a`、`tmux 2.4`、`tmux next-3.6`；`tmux master`、`tmux openbsd-7.5` 这种认不出版本号，返回 null。
  static TmuxVersion? parse(String line) {
    final match =
        RegExp(r'^tmux (?:next-)?(\d{1,3})\.(\d{1,3})([a-z]?)$').firstMatch(
      line.trim(),
    );
    if (match == null) return null;
    return TmuxVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      match.group(3)!,
    );
  }

  @override
  int compareTo(TmuxVersion other) => major != other.major
      ? major.compareTo(other.major)
      : minor.compareTo(other.minor);

  bool operator >=(TmuxVersion other) => compareTo(other) >= 0;

  @override
  String toString() => '$major.$minor$suffix';
}

/// 一次查询看到的远端 tmux 状况。
enum TmuxAvailability {
  /// 远端没有 tmux 命令。没有自动安装。
  missing,

  /// 有 tmux，但版本不在实测范围或认不出来：只当普通 SSH 用。
  unsupported,

  /// 这个 socket 上没有 server（查询没有启动它）。
  noServer,

  /// 有 server，列出了 session。
  ready,

  /// 有 server，但列表读失败或者输出自相矛盾，不提供任何操作。
  failed,
}

class TmuxSessionRow {
  const TmuxSessionRow({
    required this.server,
    required this.sessionId,
    required this.created,
    required this.windows,
    required this.attached,
    required this.activity,
    required this.mouse,
    required this.prefix,
    required this.group,
    required this.name,
  });

  final TmuxServerIdentity server;
  final String sessionId;
  final int created;
  final int windows;
  final int attached;
  final int? activity;

  /// 这个 session 实际生效的 mouse 选项（会话设置或全局继承来的）。
  final bool mouse;

  /// 实际生效的前缀键，比如 `C-b`、`C-a`。
  final String prefix;
  final String group;

  /// 已去掉控制字符、只给人看。
  final String name;
}

class TmuxProbe {
  const TmuxProbe({
    required this.availability,
    this.unixUser = '',
    this.uid,
    this.versionLine = '',
    this.version,
    this.socketPath = '',
    this.server,
    this.sessions = const [],
    this.skippedLines = 0,
    this.truncated = false,
    this.problem,
  });

  final TmuxAvailability availability;
  final String unixUser;
  final int? uid;

  /// `tmux -V` 原样的一行（已去掉控制字符、截短）。
  final String versionLine;
  final TmuxVersion? version;
  final String socketPath;
  final TmuxServerIdentity? server;
  final List<TmuxSessionRow> sessions;

  /// 认不出来、丢掉了的行数（含 tmux 的报错行）。
  final int skippedLines;

  /// 输出太长，被截断了：列表不全。
  final bool truncated;

  /// [TmuxAvailability.failed] 或 [TmuxAvailability.unsupported] 时给人看的原因。
  final String? problem;

  bool get canOperate =>
      availability == TmuxAvailability.ready ||
      availability == TmuxAvailability.noServer;
}

/// 脚本开头都有的一段：按第 1、2 个参数算出 socket 路径，放在 `$s`。
/// `-L` 和默认 socket 按 tmux 自己的规则：`${TMUX_TMPDIR:-/tmp}/tmux-UID/名字`。
const _socketSnippet =
    r'case "$1" in S) s=$2;; L) s=${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$2;; *) s=${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/default;; esac;';

/// 和 [_socketSnippet] 配套：`-L`/`-S` 参数，给会启动 server 的 new-session 用。
/// 带 `-S` 时 tmux 不替你建 `/tmp/tmux-UID` 目录，所以默认 socket 和 `-L` 照 tmux 自己的写法传。
const _socketFlagSnippet =
    r'case "$1" in S) f=-S;; *) f=-L;; esac; n=$2; [ "$1" = D ] && n=default;';

/// 核对 uid 和目标：参数 3 是 uid，参数 4 是期望的 `$ID:pid:start:created`，参数 5 是 `$ID`。
/// tmux 3.5a 的 display-message 找不到目标时不报错，只输出空字段（实测），所以连 session_id 一起比。
const _guardSnippet =
    r'[ "$(id -u)" = "$3" ] || exit 96; command -v tmux >/dev/null 2>&1 || exit 95; '
    r'[ -S "$s" ] || exit 97; '
    r'g=$(tmux -S "$s" display-message -p -t "$5" "#{session_id}:#{pid}:#{start_time}:#{session_created}" 2>/dev/null); '
    r'[ "$g" = "$4" ] || exit 97;';

/// session 一行的格式。分隔符用 `|~|` 而不是 Tab：tmux 输出时把 Tab 之类的控制字符一律换成 `_`
/// （实测 2.4–3.5a 的 list-sessions、new-session -P、display-message 都这样）——基座按 Tab 拆，
/// 所以它的 tmux 面板在这些版本上永远显示「还没有 tmux session」。
/// 名字放最后：名字里即便有 `|~|`，多出来的字段都并回名字，前面的身份字段不受影响。
const _rowFormat =
    'S$tmuxRowSeparator#{pid}$tmuxRowSeparator#{start_time}$tmuxRowSeparator#{session_id}$tmuxRowSeparator#{session_created}$tmuxRowSeparator#{session_windows}$tmuxRowSeparator#{session_attached}$tmuxRowSeparator#{session_activity}$tmuxRowSeparator#{mouse}$tmuxRowSeparator#{prefix}$tmuxRowSeparator#{session_group}$tmuxRowSeparator#{session_name}';

const tmuxRowSeparator = '|~|';

/// 查询脚本。参数：socket 种类（D/L/S）、socket 名或路径。
///
/// tmux 带 -u：exec 通道里没有用户的 LANG，不加的话 tmux 按 C 语言环境输出，名字里的中文每个字节都变成 `_`
/// （实测 2.4、3.5a；存着的名字没坏，只是输出被替换）。
const tmuxProbeScript = r'LC_ALL=C; export LC_ALL; '
    r'printf "U\t%s\t%s\n" "$(id -un 2>/dev/null)" "$(id -u 2>/dev/null)"; '
    r'command -v tmux >/dev/null 2>&1 || { printf "X\tmissing\n"; exit 0; }; '
    r'printf "V\t%s\n" "$(tmux -V 2>&1 | head -n 1 | cut -c 1-120)"; '
    '$_socketSnippet '
    r'printf "P\t%s\n" "$s"; '
    r'[ -S "$s" ] || { printf "X\tnoserver\n"; exit 0; }; '
    r'{ tmux -u -S "$s" list-sessions -F "'
    '$_rowFormat'
    r'" 2>&1; printf "R\t%s\n" "$?"; } | head -n 1001 | cut -c 1-1024; '
    r'printf "X\tend\n"';

/// 新建脚本。参数：socket 种类、名或路径、uid；session 名字从 stdin 第一行进来。
/// 只建、不附着（-d），用 -P -F 拿回新 session 的身份。名字已在 App 里按白名单校验，
/// 不含 `#`：tmux 会对 -s 的值做格式展开，`#(命令)` 会被执行（实测 2.7、3.0a、3.5a）。
const tmuxCreateScript = r'LC_ALL=C; export LC_ALL; '
    r'[ "$(id -u)" = "$3" ] || exit 96; command -v tmux >/dev/null 2>&1 || exit 95; '
    '$_socketSnippet $_socketFlagSnippet '
    r'IFS= read -r name; printf "P\t%s\n" "$s"; '
    r'tmux -u $f "$n" new-session -d -P -F "'
    '$_rowFormat'
    r'" -s "$name" 2>&1 | head -n 5 | cut -c 1-1024';

/// 往刚建好的 session 里输入启动命令。参数同 [tmuxKillScript]；命令文本从 stdin 进来，按字面输入（send-keys -l），
/// 不当成 tmux 键名解释，最后单独补一个回车。
const tmuxStartupScript = '$_socketSnippet $_guardSnippet '
    r't=$(cat); tmux -S "$s" send-keys -l -t "$5" -- "$t" && tmux -S "$s" send-keys -t "$5" Enter';

/// 结束 session。参数：socket 种类、名或路径、uid、期望身份、`$ID`。按 ID 结束，先核对身份。
const tmuxKillScript =
    '$_socketSnippet $_guardSnippet exec tmux -S "\$s" kill-session -t "\$5"';

/// 只改这一个 session 的 mouse 选项（打开或取消会话级设置、回到全局），不碰 tmux.conf 和全局选项。
const tmuxMouseOnScript =
    '$_socketSnippet $_guardSnippet exec tmux -S "\$s" set-option -t "\$5" mouse on';
const tmuxMouseUnsetScript =
    '$_socketSnippet $_guardSnippet exec tmux -S "\$s" set-option -u -t "\$5" mouse';

/// 分离一个确定的客户端。参数在 [tmuxKillScript] 之后再加客户端终端和 pid：
/// 列出这个 session 的客户端，终端和 pid 都对上才分离，对不上就退出 98，不去猜别的客户端。
const tmuxDetachScript = '$_socketSnippet $_guardSnippet '
    r'tmux -S "$s" list-clients -t "$5" -F "#{client_tty}:#{client_pid}" 2>/dev/null | grep -x -F -q -- "$6:$7" || exit 98; '
    r'exec tmux -S "$s" detach-client -t "$6"';

/// 一个 session 的窗口和客户端（只读，按 ID，先核对身份）。参数同 [tmuxKillScript]。
const tmuxDetailsScript = '$_socketSnippet $_guardSnippet '
    r'{ tmux -u -S "$s" list-windows -t "$5" -F "W'
    '$tmuxRowSeparator#{window_index}$tmuxRowSeparator#{window_panes}$tmuxRowSeparator#{window_active}$tmuxRowSeparator#{window_name}'
    r'" 2>&1; tmux -u -S "$s" list-clients -t "$5" -F "C'
    '$tmuxRowSeparator#{client_pid}$tmuxRowSeparator#{client_tty}'
    r'" 2>&1; } | head -n 401 | cut -c 1-512';

/// Dedicated AI run: require exactly one window and pane and capture both
/// stable tmux IDs plus the pane process ID before sending any tool command.
const tmuxAiPaneScript = '$_socketSnippet $_guardSnippet '
    r'v=$(tmux -S "$s" display-message -p -t "$5" "#{session_windows}:#{window_panes}:#{session_id}:#{window_id}:#{pane_id}:#{pane_pid}" 2>/dev/null) || exit 97; '
    r'[ -n "$v" ] || exit 97; printf "%s\n" "$v"';

const _aiPaneGuardSnippet =
    r'p=$(tmux -S "$s" display-message -p -t "$6" "#{session_id}:#{window_id}:#{pane_id}:#{pane_pid}" 2>/dev/null) || exit 97; '
    r'[ "$p" = "$7" ] || exit 97;';

/// Startup text goes through stdin into the one verified pane. If that pane
/// was replaced between creation and dispatch, nothing is sent anywhere.
const tmuxAiStartupScript = '$_socketSnippet $_guardSnippet '
    '$_aiPaneGuardSnippet '
    r't=$(cat); tmux -S "$s" send-keys -l -t "$6" -- "$t" && tmux -S "$s" send-keys -t "$6" Enter';

/// The attach handshake rechecks the pane after the user terminal binds. A
/// changed pane cannot be silently presented as the original AI run.
const tmuxAiAttachScript = '$_socketSnippet $_guardSnippet '
    '$_aiPaneGuardSnippet '
    r'printf "\r\n'
    '$tmuxAttachMarker'
    r' %s %s\r\n" "$(tty)" "$$"; '
    r'stty -echo 2>/dev/null; IFS= read -r x; '
    r'g=$(tmux -S "$s" display-message -p -t "$5" "#{session_id}:#{pid}:#{start_time}:#{session_created}" 2>/dev/null); '
    r'[ "$g" = "$4" ] || exit 97; '
    '$_aiPaneGuardSnippet '
    r'exec tmux -u -S "$s" attach-session -t "$5"';

/// 附着脚本，在带 PTY 的 exec 通道里跑，不经交互式 shell（用户 .bashrc 里的自动 tmux 碰不到它，也不进 shell 历史）。
///
/// 1. 核对 uid 和目标身份，不对就退出（95/96/97），不附着、不新建。
/// 2. 报出本客户端的终端设备和 pid（`exec` 之后 tmux 客户端就是这个进程），App 据此精确分离这个标签。
/// 3. 关回显，等 App 回一个换行：App 先把终端尺寸发过去，tmux 一附着就是对的大小。
/// 4. 再核对一次，`exec tmux -u attach-session`。不带 -d：不踢掉别的客户端（TMX03）。
///    -u：exec 通道里没有用户的 LANG，不加的话 tmux 当终端不支持 UTF-8，中文全画成下划线。
const tmuxAttachScript = '$_socketSnippet $_guardSnippet '
    r'printf "\r\n'
    '$tmuxAttachMarker'
    r' %s %s\r\n" "$(tty)" "$$"; '
    r'stty -echo 2>/dev/null; IFS= read -r x; '
    r'g=$(tmux -S "$s" display-message -p -t "$5" "#{session_id}:#{pid}:#{start_time}:#{session_created}" 2>/dev/null); '
    r'[ "$g" = "$4" ] || exit 97; '
    r'exec tmux -u -S "$s" attach-session -t "$5"';

const tmuxAttachMarker = 'SHUN-TMUX-ATTACH';

final _sessionId = RegExp(r'^\$\d{1,9}$');
final _clientTty = RegExp(r'^/dev/[A-Za-z0-9/_.-]{1,64}$');

/// 新建 session 时名字的白名单：字母（含中文）、数字、`_`、`-`、中间的空格，最长 64，不以 `-` 开头（免得像命令行选项）。
/// 不收 `#`（tmux 会展开 `#(命令)`）、`:` `.`（tmux 会改成 `_`）、引号、分号、通配符和任何控制字符。
final _newSessionName = RegExp(
  r'^[\p{L}\p{N}_](?:[\p{L}\p{N}_ -]{0,62}[\p{L}\p{N}_-])?$',
  unicode: true,
);

String validateNewSessionName(String raw) {
  final value = raw.trim();
  if (!_newSessionName.hasMatch(value)) {
    throw const FormatException(
      'session 名称只能用字母、数字、_ 和 -（中间可以有空格），最长 64 个字符；'
      '不能含 # : . 引号、分号或换行',
    );
  }
  return value;
}

/// 启动命令最长多少字符。它是用户明确填的、按字面输进新 session 的 shell。
const tmuxStartupMaxLength = 4096;

/// 一条 `sh -c` 命令。[arguments] 必须都已校验过。
String _command(String script, List<String> arguments) {
  assert(isPortableScript(script), 'tmux script is not portable across shells');
  for (final value in arguments) {
    if (!_safeArgument.hasMatch(value)) {
      throw ArgumentError.value(value, 'argument', 'character not allowed');
    }
  }
  return "sh -c '$script' shun ${arguments.map((value) => "'$value'").join(' ')}";
}

/// 位置参数的字符集：都是事先按白名单校验过的东西，这里再挡一次。
final _safeArgument = RegExp(r'^[A-Za-z0-9_./+@:%$-]{1,240}$');

/// 脚本能不能原样放进单引号、在常见登录 shell 里都不被改动。
bool isPortableScript(String script) =>
    !script.contains("'") &&
    !script.contains('!') &&
    !script.contains(r'\\') &&
    !script.contains('\n') &&
    !script.contains('\r');

List<String> _socketArguments(TmuxSocketSpec socket) => switch (socket.kind) {
      TmuxSocketKind.standard => ['D', '-'],
      TmuxSocketKind.named => ['L', socket.value],
      TmuxSocketKind.path => ['S', socket.value],
    };

List<String> _targetArguments(TmuxTarget target) {
  if (!_sessionId.hasMatch(target.sessionId)) {
    throw ArgumentError.value(target.sessionId, 'sessionId');
  }
  return [
    ..._socketArguments(target.socket),
    '${target.uid}',
    target.guard,
    target.sessionId,
  ];
}

String tmuxProbeCommand(TmuxSocketSpec socket) =>
    _command(tmuxProbeScript, _socketArguments(socket));

String tmuxCreateCommand(TmuxSocketSpec socket, int uid) =>
    _command(tmuxCreateScript, [..._socketArguments(socket), '$uid']);

String tmuxStartupCommand(TmuxTarget target) =>
    _command(tmuxStartupScript, _targetArguments(target));

String tmuxKillCommand(TmuxTarget target) =>
    _command(tmuxKillScript, _targetArguments(target));

String tmuxMouseCommand(TmuxTarget target, {required bool enable}) => _command(
      enable ? tmuxMouseOnScript : tmuxMouseUnsetScript,
      _targetArguments(target),
    );

String tmuxAttachCommand(TmuxTarget target) =>
    _command(tmuxAttachScript, _targetArguments(target));

String tmuxDetailsCommand(TmuxTarget target) =>
    _command(tmuxDetailsScript, _targetArguments(target));

String tmuxAiPaneCommand(TmuxTarget target) =>
    _command(tmuxAiPaneScript, _targetArguments(target));

String tmuxAiStartupCommand(AiCliTmuxRun run) => _command(tmuxAiStartupScript,
    [..._targetArguments(run.target), run.paneId, run.paneGuard]);

String tmuxAiAttachCommand(AiCliTmuxRun run) => _command(tmuxAiAttachScript,
    [..._targetArguments(run.target), run.paneId, run.paneGuard]);

({String windowId, String paneId, int panePid})? parseTmuxAiPane(
    String raw, TmuxTarget target) {
  final line = raw.trim();
  final parts = line.split(':');
  if (parts.length != 6 ||
      parts[0] != '1' ||
      parts[1] != '1' ||
      parts[2] != target.sessionId ||
      !RegExp(r'^@\d{1,9}$').hasMatch(parts[3]) ||
      !RegExp(r'^%\d{1,9}$').hasMatch(parts[4])) {
    return null;
  }
  final pid = int.tryParse(parts[5]);
  if (pid == null || pid <= 0) return null;
  return (windowId: parts[3], paneId: parts[4], panePid: pid);
}

String tmuxDetachCommand(TmuxClientBinding binding) {
  if (!_clientTty.hasMatch(binding.clientTty) || binding.clientPid <= 0) {
    throw ArgumentError.value(binding.clientTty, 'clientTty');
  }
  return _command(tmuxDetachScript, [
    ..._targetArguments(binding.target),
    binding.clientTty,
    '${binding.clientPid}',
  ]);
}

/// 解析附着脚本报回来的那一行（[tmuxAttachMarker] 之后的终端设备和 pid）。认不出来返回 null。
({String tty, int pid})? parseAttachMarker(String line) {
  final match = RegExp('$tmuxAttachMarker (\\S{1,80}) (\\d{1,9})').firstMatch(
    line,
  );
  if (match == null) return null;
  final tty = match.group(1)!;
  if (!_clientTty.hasMatch(tty)) return null;
  return (tty: tty, pid: int.parse(match.group(2)!));
}

/// 解析查询输出。[truncated] 表示 App 这边读到字节上限后停了。
TmuxProbe parseTmuxProbe(String raw, {bool truncated = false}) {
  var user = '';
  int? uid;
  var versionLine = '';
  var socketPath = '';
  String? end;
  int? listExit;
  final rows = <TmuxSessionRow>[];
  final messages = <String>[];
  var skipped = 0;
  var listLines = 0;

  for (final line in const LineSplitter().convert(raw)) {
    if (line.startsWith('S$tmuxRowSeparator')) {
      listLines++;
      final row = _parseRow(line.split(tmuxRowSeparator), socketPath);
      if (row == null) {
        skipped++;
      } else {
        rows.add(row);
      }
      continue;
    }
    final fields = line.split('\t');
    switch (fields.first) {
      case 'U' when fields.length == 3:
        user = displaySafe(fields[1], max: 64);
        uid = int.tryParse(fields[2]);
      case 'V' when fields.length >= 2:
        versionLine = displaySafe(fields.sublist(1).join(' '), max: 120);
      case 'P' when fields.length == 2:
        socketPath = fields[1];
      case 'X' when fields.length == 2:
        end = fields[1];
      case 'R' when fields.length == 2:
        listExit = int.tryParse(fields[1]);
      default:
        skipped++;
        if (messages.length < 3) messages.add(displaySafe(line, max: 200));
    }
  }

  final version = TmuxVersion.parse(versionLine);
  TmuxProbe result(TmuxAvailability availability,
          {String? problem,
          TmuxServerIdentity? server,
          List<TmuxSessionRow> sessions = const []}) =>
      TmuxProbe(
        availability: availability,
        unixUser: user,
        uid: uid,
        versionLine: versionLine,
        version: version,
        socketPath: socketPath,
        server: server,
        sessions: sessions,
        skippedLines: skipped,
        truncated: truncated || (end == 'end' && listExit == null),
        problem: problem,
      );

  if (uid == null) {
    return result(
      TmuxAvailability.failed,
      problem: truncated ? '远端输出被截断，没读到用户信息' : '远端输出无法识别',
    );
  }
  if (end == 'missing') return result(TmuxAvailability.missing);
  if (version == null || !(version >= tmuxOldestTested)) {
    return result(
      TmuxAvailability.unsupported,
      problem: version == null
          ? '认不出 tmux 版本（$versionLine）'
          : 'tmux $version 早于实测过的最老版本 $tmuxOldestTested',
    );
  }
  if (end == 'noserver') return result(TmuxAvailability.noServer);
  if (end != 'end' && !truncated) {
    return result(TmuxAvailability.failed, problem: '查询中途断了，列表不完整');
  }
  if (listExit != null && listExit != 0) {
    // socket 文件还在、server 已经没了（被杀、机器重启过）：和「没有 server」一样，不是读取故障。
    if (rows.isEmpty &&
        messages.any((value) => RegExp(
              r'no server running|error connecting|connection refused',
              caseSensitive: false,
            ).hasMatch(value))) {
      return result(TmuxAvailability.noServer);
    }
    // server 开着但一个 session 都没有（exit-empty off）：老版本报 no sessions、退出码 1。
    if (rows.isEmpty &&
        messages.length == 1 &&
        messages.single.toLowerCase().startsWith('no sessions')) {
      return result(TmuxAvailability.ready);
    }
    return result(
      TmuxAvailability.failed,
      problem: messages.isEmpty
          ? 'tmux 列表读取失败（退出码 $listExit）'
          : 'tmux 列表读取失败：${messages.join('；')}',
    );
  }
  // 同一个 socket 只会有一个 server：行里出现两个 server 身份、或同一个 session ID 出现两次，
  // 说明输出不可信（被篡改、混进了别的东西），不猜哪行是真的，整个列表不提供操作。
  final servers = rows.map((row) => row.server).toSet();
  final ids = rows.map((row) => row.sessionId).toSet();
  if (servers.length > 1) {
    return result(TmuxAvailability.failed,
        problem: 'tmux 输出里出现了 ${servers.length} 个不同的 server，无法确定目标');
  }
  if (ids.length != rows.length) {
    return result(TmuxAvailability.failed,
        problem: 'tmux 输出里同一个 session ID 出现了多次，无法确定目标');
  }
  if (rows.isEmpty && listLines == 0 && messages.isNotEmpty) {
    return result(TmuxAvailability.failed,
        problem: 'tmux 列表读取失败：${messages.join('；')}');
  }
  return result(
    TmuxAvailability.ready,
    server: servers.isEmpty ? null : servers.single,
    sessions: rows.take(tmuxMaxSessions).toList(growable: false),
  );
}

/// 解析新建脚本的输出：一行 socket 路径加一行新 session。tmux 报错（重名之类）时返回 null，
/// 报错文字放进 [messages]。
TmuxSessionRow? parseCreatedSession(String raw, List<String> messages) {
  var socketPath = '';
  TmuxSessionRow? row;
  for (final line in const LineSplitter().convert(raw)) {
    final fields = line.split('\t');
    if (fields.first == 'P' && fields.length == 2) {
      socketPath = fields[1];
    } else if (line.startsWith('S$tmuxRowSeparator') && row == null) {
      row = _parseRow(line.split(tmuxRowSeparator), socketPath);
    } else if (line.trim().isNotEmpty && messages.length < 3) {
      messages.add(displaySafe(line, max: 200));
    }
  }
  return row;
}

class TmuxWindowRow {
  const TmuxWindowRow({
    required this.index,
    required this.panes,
    required this.active,
    required this.name,
  });

  final int index;
  final int panes;
  final bool active;
  final String name;
}

class TmuxClientRow {
  const TmuxClientRow({required this.pid, required this.tty});

  final int pid;
  final String tty;
}

/// 解析 [tmuxDetailsScript] 的输出；认不出的行丢掉。
({List<TmuxWindowRow> windows, List<TmuxClientRow> clients}) parseTmuxDetails(
    String raw) {
  final windows = <TmuxWindowRow>[];
  final clients = <TmuxClientRow>[];
  for (final line in const LineSplitter().convert(raw)) {
    final fields = line.split(tmuxRowSeparator);
    if (fields.first == 'W' && fields.length >= 5) {
      final index = int.tryParse(fields[1]);
      final panes = int.tryParse(fields[2]);
      if (index == null || panes == null) continue;
      windows.add(TmuxWindowRow(
        index: index,
        panes: panes,
        active: fields[3] == '1',
        name: displaySafe(fields.sublist(4).join(tmuxRowSeparator), max: 120),
      ));
    } else if (fields.first == 'C' && fields.length == 3) {
      final pid = _positive(fields[1]);
      if (pid == null || !_clientTty.hasMatch(fields[2])) continue;
      clients.add(TmuxClientRow(pid: pid, tty: fields[2]));
    }
  }
  return (windows: windows, clients: clients);
}

TmuxSessionRow? _parseRow(List<String> fields, String socketPath) {
  if (fields.length < 12) return null;
  final pid = _positive(fields[1]);
  final start = _positive(fields[2]);
  final created = _positive(fields[4]);
  final windows = int.tryParse(fields[5]);
  final attached = int.tryParse(fields[6]);
  if (pid == null ||
      start == null ||
      created == null ||
      windows == null ||
      attached == null ||
      !_sessionId.hasMatch(fields[3]) ||
      socketPath.isEmpty) {
    return null;
  }
  return TmuxSessionRow(
    server: TmuxServerIdentity(
      socketPath: socketPath,
      pid: pid,
      startTime: start,
    ),
    sessionId: fields[3],
    created: created,
    windows: windows,
    attached: attached,
    activity: int.tryParse(fields[7]),
    mouse: fields[8] == '1' || fields[8] == 'on',
    prefix: displaySafe(fields[9], max: 32),
    group: displaySafe(fields[10], max: 64),
    name: displaySafe(fields.sublist(11).join(tmuxRowSeparator), max: 200),
  );
}

int? _positive(String value) {
  final parsed = int.tryParse(value);
  return parsed == null || parsed <= 0 ? null : parsed;
}

/// 远端来的文字只给人看：控制字符、换行、Tab 换成可见的转义，双向文字控制符去掉（防止界面上把名字倒着显示来冒充），
/// 再截到 [max] 个字符。
String displaySafe(String value, {int max = 200}) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    if (buffer.length >= max) {
      buffer.write('…');
      break;
    }
    if (rune < 0x20 || rune == 0x7f || (rune >= 0x80 && rune < 0xa0)) {
      buffer.write(switch (rune) {
        0x09 => r'\t',
        0x0a => r'\n',
        0x0d => r'\r',
        _ => '\\x${rune.toRadixString(16).padLeft(2, '0')}',
      });
    } else if ((rune >= 0x202a && rune <= 0x202e) ||
        (rune >= 0x2066 && rune <= 0x2069) ||
        rune == 0x200e ||
        rune == 0x200f) {
      buffer.write('�');
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

/// tmux 操作失败。[message] 直接给人看。
class TmuxCommandException implements Exception {
  const TmuxCommandException(this.message, {this.exitCode});

  final String message;
  final int? exitCode;

  @override
  String toString() => message;
}

/// 目标已经不在了或已经不是同一个。恢复碰上它就停下，不按同名附着、不新建（TMX04/TMX05）。
class TmuxTargetGoneException extends TmuxCommandException {
  const TmuxTargetGoneException(super.message, {super.exitCode});
}

/// 按远端脚本的退出码给出说法。0 返回 null。
TmuxCommandException? tmuxExitError(int? exitCode, String output) {
  if (exitCode == 0) return null;
  return switch (exitCode) {
    TmuxExit.missing => const TmuxCommandException(
        '远端没有 tmux（没有自动安装）',
        exitCode: TmuxExit.missing,
      ),
    TmuxExit.wrongUser => const TmuxTargetGoneException(
        '现在登录的 Unix 用户不是这个 tmux 会话的用户，没有附着；请在 tmux 面板里重新选择',
        exitCode: TmuxExit.wrongUser,
      ),
    TmuxExit.targetGone => const TmuxTargetGoneException(
        '原来的 tmux 会话已经不在了（被结束、server 重启过，或者只剩同名/同号的另一个会话）。'
        '没有按名字附着别的会话，也没有新建；请在 tmux 面板里重新选择',
        exitCode: TmuxExit.targetGone,
      ),
    TmuxExit.clientGone => const TmuxCommandException(
        '这个标签的 tmux 客户端已经不在了，没有分离任何别的客户端',
        exitCode: TmuxExit.clientGone,
      ),
    null => const TmuxCommandException('远端命令没有报告结果就结束了'),
    _ => TmuxCommandException(
        output.trim().isEmpty
            ? 'tmux 命令失败（退出码 $exitCode）'
            : 'tmux 命令失败：${displaySafe(output.trim(), max: 300)}',
        exitCode: exitCode,
      ),
  };
}
