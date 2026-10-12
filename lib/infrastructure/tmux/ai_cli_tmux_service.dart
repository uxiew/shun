import 'package:dartssh2/dartssh2.dart';

import '../../domain/ai_cli_launch.dart';
import '../../domain/tmux/ai_cli_tmux_run.dart';
import '../../domain/tmux/tmux_target.dart';
import 'tmux_protocol.dart';
import 'tmux_service.dart';

/// Explicit creation of one dedicated session and its sole pane. It never
/// retries a mutating request, and never kills a possibly-created session.
class AiCliTmuxService {
  const AiCliTmuxService({this.tmux = const TmuxService()});
  final TmuxService tmux;

  Future<AiCliTmuxRun> start(
    SSHClient client, {
    required String hostKey,
    required TmuxSocketSpec socket,
    required String requestId,
    required AiCliLaunchSpec launch,
    required void Function() onCreateAttempted,
  }) async {
    // Validate the ID and command length before any mutating remote request.
    final command = launch.sshCommand;
    if (command.length > tmuxStartupMaxLength) {
      throw const FormatException('启动命令太长（最多 4096 个字符）');
    }
    final name = validateNewSessionName('shun-ai-$requestId');
    if (!RegExp(r'^shun-ai-[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$')
        .hasMatch(name)) {
      throw const FormatException('AI tmux 目标无效');
    }
    final probe = await tmux.probe(client, socket);
    if (!probe.canOperate || probe.uid == null || probe.unixUser.isEmpty) {
      throw TmuxCommandException(probe.problem ?? '远端 tmux 不可用');
    }
    onCreateAttempted();
    final target = await tmux.create(
      client,
      hostKey: hostKey,
      unixUser: probe.unixUser,
      uid: probe.uid!,
      socket: socket,
      name: name,
    );
    final pane = await _pane(client, target);
    final run = AiCliTmuxRun(
      requestId: requestId,
      target: target,
      windowId: pane.windowId,
      paneId: pane.paneId,
      panePid: pane.panePid,
    );
    final result = await tmux.runBounded(
      client,
      tmuxAiStartupCommand(run),
      stdin: command,
      timeout: tmux.actionTimeout,
      maxBytes: 8192,
    );
    if (result.truncated) {
      throw const TmuxCommandException('AI tmux 启动输出超出上限');
    }
    final error = tmuxExitError(result.exitCode, result.output);
    if (error != null) throw error;
    return run;
  }

  /// Read-only check of the full session, window, pane and pane process.
  Future<void> verify(SSHClient client, AiCliTmuxRun run) async {
    final pane = await _pane(client, run.target);
    if (pane.windowId != run.windowId ||
        pane.paneId != run.paneId ||
        pane.panePid != run.panePid) {
      throw const TmuxTargetGoneException('原 AI 窗格已结束或被替换，没有附着其他窗格');
    }
  }

  Future<({String windowId, String paneId, int panePid})> _pane(
      SSHClient client, TmuxTarget target) async {
    final result = await tmux.runBounded(
      client,
      tmuxAiPaneCommand(target),
      timeout: tmux.probeTimeout,
      maxBytes: 8192,
    );
    if (result.truncated) {
      throw const TmuxCommandException('AI tmux 窗格查询输出超出上限');
    }
    final error = tmuxExitError(result.exitCode, result.output);
    if (error != null) throw error;
    final pane = parseTmuxAiPane(result.output, target);
    if (pane == null) {
      throw const TmuxTargetGoneException('AI tmux 目标不再是独立的单窗格，不能继续');
    }
    return pane;
  }
}
