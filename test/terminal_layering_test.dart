import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// R16 的分层约束，按源码检查。目的是防止"只换了 import、xterm 专用访问照样穿透到各层"（R16 停止条件）：
// 以后谁在连接层、会话控制器、终端页里直接用 xterm2 或 Ghostty（flterm），这里就失败。

List<File> _dartFiles(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => file.path.endsWith('.dart'))
    .toList();

String _read(File file) => file.readAsStringSync();

String _relative(File file) => file.path.replaceFirst(RegExp(r'^\./'), '');

void main() {
  test('App 里只有 xterm2 适配器和它的视图认识 xterm2', () {
    final users = [
      for (final file in _dartFiles('lib'))
        if (_read(file).contains('package:xterm2/')) _relative(file),
    ]..sort();
    expect(users, [
      'lib/infrastructure/terminal/xterm_terminal_adapter.dart',
      'lib/presentation/terminal/xterm_terminal_view.dart',
    ]);
  });

  test('App 里只有 Ghostty 适配器和它的视图认识 flterm、libghostty（R17）', () {
    final users = [
      for (final file in _dartFiles('lib'))
        if (RegExp(r'package:(flterm|libghostty)/').hasMatch(_read(file)))
          _relative(file),
    ]..sort();
    expect(users, [
      'lib/infrastructure/terminal/ghostty_terminal_adapter.dart',
      'lib/presentation/terminal/ghostty_terminal_view.dart',
    ]);
  });

  test('连接层、会话控制器、终端页不依赖具体引擎', () {
    final engineSpecific = RegExp(
      r'(xterm|ghostty)_terminal_(adapter|view)\.dart|'
      r'(Xterm|Ghostty)Terminal(Adapter|View)\b',
    );
    final allowed = {
      // 按设置建终端的唯一位置。
      'lib/application/terminal_engine.dart',
      // 按适配器类型挑视图的唯一位置。
      'lib/presentation/terminal/terminal_view.dart',
    };
    final offenders = [
      for (final dir in [
        'lib/infrastructure/ssh',
        'lib/infrastructure/transport',
        'lib/application',
        'lib/presentation/screens',
        'lib/presentation/widgets',
      ])
        for (final file in _dartFiles(dir))
          if (!allowed.contains(_relative(file)) &&
              engineSpecific.hasMatch(_read(file)))
            _relative(file),
    ];
    expect(offenders, isEmpty);
  });

  test('终端适配层拿不到网络、凭据和存储：不能拨号、读不到 secret（SEC09）', () {
    final forbidden = RegExp(
      r"import '(dart:io|package:dartssh2/|package:flutter_secure_storage/|"
      r'package:shared_preferences/|\.\./ssh/|\.\./transport/|\.\./storage/|'
      r'\.\./tailscale/|\.\./plugins/|\.\./\.\./domain/|\.\./\.\./application/)',
    );
    final offenders = [
      for (final file in _dartFiles('lib/infrastructure/terminal'))
        for (final line in _read(file).split('\n'))
          if (forbidden.hasMatch(line)) '${_relative(file)}: $line',
    ];
    expect(offenders, isEmpty);
  });

  test('连接层把远端字节原样交给终端，不在网络分包处转字符串（TER01）', () {
    final source = _read(File('lib/infrastructure/ssh/ssh_service.dart'));
    expect(source, contains('session.stdout.listen(terminal.feed)'));
    expect(source, contains('terminal.feed(Uint8List.fromList(visible))'));
    expect(source, isNot(contains('decodeTerminalText')));
  });
}
