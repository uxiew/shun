import 'ai_cli.dart';
import 'ai_cli_launch.dart';
import 'tmux/ai_cli_tmux_run.dart';

/// A device-local pointer to one user-opened AI terminal. It contains no
/// conversation text, credential, prompt, or terminal output.
class AiCliWorkItem {
  AiCliWorkItem({
    required this.id,
    required this.tool,
    required this.name,
    required this.executable,
    required this.projectDirectory,
    required this.openedAt,
    this.claudeSessionId,
    this.tmuxRun,
  }) {
    validateAiCliPath(executable);
    validateAiCliPath(projectDirectory);
    if (!executable.startsWith('/') ||
        id.isEmpty ||
        id.length > 80 ||
        name.trim().isEmpty ||
        name.length > 80 ||
        RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(name)) {
      throw const FormatException('最近工作记录无效');
    }
    if (claudeSessionId != null &&
        (tool != AiCliKind.claude || !_uuid.hasMatch(claudeSessionId!))) {
      throw const FormatException('最近工作记录无效');
    }
  }

  static final _uuid =
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

  final String id;
  final AiCliKind tool;
  final String name;
  final String executable;
  final String projectDirectory;
  final DateTime openedAt;

  /// Assigned by Shun on launch. It is a candidate until Claude has written
  /// the session; an exact-ID resume can fail, but cannot select another one.
  final String? claudeSessionId;
  final AiCliTmuxRun? tmuxRun;
  String? get nativeIdSource =>
      claudeSessionId == null ? null : 'shun-assigned';

  AiCliLaunchSpec? exactResume() => claudeSessionId == null
      ? null
      : AiCliLaunchSpec(
          executable: executable,
          projectDirectory: projectDirectory,
          arguments: ['--resume', claudeSessionId!],
        );

  /// For Codex, show its own project-filtered picker. This is a user choice,
  /// not a claim that Shun knows which private conversation was last used.
  AiCliLaunchSpec? historyPicker() => tool == AiCliKind.codex
      ? AiCliLaunchSpec(
          executable: executable,
          projectDirectory: projectDirectory,
          arguments: const ['resume'],
        )
      : null;

  Map<String, Object?> toJson() => {
        'id': id,
        'tool': tool.name,
        'name': name,
        'executable': executable,
        'projectDirectory': projectDirectory,
        'openedAt': openedAt.toUtc().toIso8601String(),
        'claudeSessionId': claudeSessionId,
        'nativeIdSource': nativeIdSource,
        'tmuxRun': tmuxRun?.toJson(),
      };

  static AiCliWorkItem? fromJson(Object? raw) {
    try {
      final data = raw as Map<String, dynamic>;
      final runRaw = data['tmuxRun'];
      final run = runRaw == null ? null : AiCliTmuxRun.fromJson(runRaw);
      if (runRaw != null && run == null) {
        return null;
      }
      if (data['claudeSessionId'] != null &&
          data['nativeIdSource'] != 'shun-assigned') {
        return null;
      }
      return AiCliWorkItem(
        id: data['id'] as String,
        tool: AiCliKind.values.byName(data['tool'] as String),
        name: data['name'] as String,
        executable: data['executable'] as String,
        projectDirectory: data['projectDirectory'] as String,
        openedAt: DateTime.parse(data['openedAt'] as String),
        claudeSessionId: data['claudeSessionId'] as String?,
        tmuxRun: run,
      );
    } on Object {
      return null;
    }
  }
}
