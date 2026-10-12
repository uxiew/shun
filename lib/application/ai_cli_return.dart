import '../domain/ai_cli_identity.dart';
import '../domain/ai_cli_work.dart';
import '../domain/models/host.dart';
import '../infrastructure/ssh/ssh_service.dart';

/// A saved tab ID alone does not prove that its current transport still owns
/// the original work. Recheck this after every asynchronous operation.
bool matchesAiWorkTerminal(
    ActiveTerminalSession session, AiCliWorkItem item, HostProfile host) {
  if (session.id != item.id ||
      !session.connected ||
      session.closedByUser ||
      aiCliHostScope(session.host) != aiCliHostScope(host)) {
    return false;
  }
  final run = item.tmuxRun;
  if (run != null) return session.aiTmuxRun?.sameAs(run) == true;
  final launch = session.aiLaunch;
  if (!session.aiTerminalOriginal ||
      launch == null ||
      launch.executable != item.executable ||
      launch.projectDirectory != item.projectDirectory) {
    return false;
  }
  final nativeId = item.claudeSessionId;
  return nativeId == null ||
      (launch.arguments.length == 2 &&
          const ['--session-id', '--resume'].contains(launch.arguments.first) &&
          launch.arguments.last == nativeId);
}
