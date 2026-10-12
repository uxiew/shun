/// R55: path discovery is independent of login, launch and conversation resume.
enum AiCliKind {
  claude('Claude Code', 'claude', '@anthropic-ai/claude-code'),
  codex('Codex', 'codex', '@openai/codex'),
  gemini('Gemini CLI', 'gemini', '@google/gemini-cli'),
  opencode('OpenCode', 'opencode', 'opencode-ai'),
  custom('自定义工具', '', '');

  const AiCliKind(this.label, this.command, this.packageName);
  final String label;
  final String command;
  final String packageName;
}

class AiCliCustomTool {
  AiCliCustomTool({required this.name, required this.path}) {
    if (name.trim().isEmpty ||
        name.length > 80 ||
        _controls.hasMatch(name) ||
        name.contains('|')) {
      throw const FormatException('工具名称无效（最多 80 个字符）');
    }
    validateAiCliPath(path);
  }
  final String name;
  final String path;
}

final _controls = RegExp(r'[\x00-\x1f\x7f-\x9f]');

String validateAiCliPath(String value) {
  if ((!value.startsWith('/') && !value.startsWith('~/')) ||
      value.length > 2048 ||
      _controls.hasMatch(value)) {
    throw const FormatException('请使用绝对路径或 ~/ 开头的路径，不含控制字符');
  }
  return value;
}

class AiCliScanRequest {
  AiCliScanRequest({
    List<String> directories = const [],
    List<AiCliCustomTool> customTools = const [],
  })  : directories = List.unmodifiable(directories),
        customTools = List.unmodifiable(customTools) {
    if (directories.length > 16 || customTools.length > 16) {
      throw const FormatException('最多补充 16 个目录和 16 个工具');
    }
    if (customTools.map((x) => x.name).toSet().length != customTools.length) {
      throw const FormatException('自定义工具名称不能重复');
    }
    for (final path in directories) {
      validateAiCliPath(path);
    }
  }
  final List<String> directories;
  final List<AiCliCustomTool> customTools;
}

class AiCliInstallation {
  const AiCliInstallation({
    required this.kind,
    required this.name,
    required this.path,
    required this.source,
    this.packageVersion,
  });
  final AiCliKind kind;
  final String name;
  final String path;
  final String source;

  /// Informational package metadata; never proof that this executable is genuine
  /// or that a particular launch/resume flag works.
  final String? packageVersion;
}

class AiCliScanResult {
  AiCliScanResult({
    required this.unixUser,
    required this.uid,
    required List<AiCliInstallation> installations,
    required this.scannedAt,
    this.limited = false,
  }) : installations = List.unmodifiable(installations);
  final String unixUser;
  final String uid;
  final List<AiCliInstallation> installations;
  final DateTime scannedAt;
  final bool limited;
}

class AiCliDiscoveryException implements Exception {
  const AiCliDiscoveryException(this.message);
  final String message;
  @override
  String toString() => message;
}
