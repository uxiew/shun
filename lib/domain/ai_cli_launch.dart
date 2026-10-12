import 'ai_cli.dart';

String _shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

/// One explicit launch in a fresh SSH PTY. The executable and working
/// directory are separate values; no arbitrary command template is accepted.
class AiCliLaunchSpec {
  AiCliLaunchSpec({
    required this.executable,
    required this.projectDirectory,
    List<String> arguments = const [],
  }) : arguments = List.unmodifiable(arguments) {
    validateAiCliPath(executable);
    validateAiCliPath(projectDirectory);
    if (!executable.startsWith('/')) {
      throw const FormatException('启动工具须使用检测返回的绝对路径');
    }
    if (arguments.length > 16 ||
        arguments.any((value) =>
            value.length > 2048 ||
            RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value))) {
      throw const FormatException('工具参数过多或包含控制字符');
    }
  }

  final String executable;
  final String projectDirectory;
  final List<String> arguments;

  String get _directoryExpression => projectDirectory.startsWith('~/')
      ? '"\$HOME"/${_shellQuote(projectDirectory.substring(2))}'
      : _shellQuote(projectDirectory);

  /// Read-only preflight. Output is one status line followed by the canonical
  /// directory; a failure never silently falls back to HOME.
  String get projectProbeScript =>
      'cd $_directoryExpression 2>/dev/null || { printf "M\\n"; exit 0; }\n'
      '[ -f ${_shellQuote(executable)} ] && '
      '[ -x ${_shellQuote(executable)} ] || { printf "E\\n"; exit 0; }\n'
      'printf "P%s\\n" "\$(pwd -P)"';

  /// The SSH exec request runs this through the account's shell. The only
  /// supported outer-shell syntax is POSIX single-quoted words; then /bin/sh
  /// checks the exact directory and executable before replacing itself.
  String get sshCommand {
    final words = [executable, ...arguments].map(_shellQuote).join(' ');
    final script = 'cd $_directoryExpression || exit 125\n'
        '[ -f ${_shellQuote(executable)} ] && '
        '[ -x ${_shellQuote(executable)} ] || exit 126\n'
        'exec $words';
    return 'exec /bin/sh -c ${_shellQuote(script)}';
  }
}

/// The exec request reached SSH, but its final remote effect is unconfirmed.
class AiCliLaunchUnknownException implements Exception {
  const AiCliLaunchUnknownException();
  @override
  String toString() => '启动请求已发出，但结果未知。请先检查远端，再决定是否新建。';
}
