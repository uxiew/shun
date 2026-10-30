import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// R16 的分层约束，按源码检查。目的是防止"只换了 import、引擎专用访问照样穿透到各层"（R16 停止条件）：
// 以后谁在连接层、会话控制器、终端页里直接用 Ghostty（flterm），这里就失败。
// R20 起安装包里只有 Ghostty：lib/ 里谁再引 xterm2，这里也失败（docs/06 E 步：不在安装包里带两个引擎）。

List<File> _dartFiles(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => file.path.endsWith('.dart'))
    .toList();

String _read(File file) => file.readAsStringSync();

String _relative(File file) => file.path.replaceFirst(RegExp(r'^\./'), '');

void main() {
  test('App 里没有任何地方认识 xterm2（R20）', () {
    final users = [
      for (final file in _dartFiles('lib'))
        if (_read(file).contains('package:xterm2/')) _relative(file),
    ];
    expect(users, isEmpty);
    // 只留在 dev_dependencies 给对照测试用；挪回 dependencies 就会打进安装包。
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final dependencies = pubspec.substring(pubspec.indexOf('\ndependencies:'),
        pubspec.indexOf('\ndev_dependencies:'));
    expect(dependencies, isNot(contains('\n  xterm2:')));
    expect(pubspec, contains('\n  xterm2:'), reason: '对照测试还要用它');
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
      r'ghostty_terminal_(adapter|view)\.dart|'
      r'GhosttyTerminal(Adapter|View)\b',
    );
    final allowed = {
      // 建终端的唯一位置。
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
    // 白名单，不是黑名单。R28 之前按「不许 import '../ssh/…'」这类写法拦，
    // 换成 package:shun/infrastructure/ssh/… 或双引号就拦不住（实测过）。
    // 要加依赖先想清楚：终端信任的是远端发来的字节，它能碰到的东西远端就可能碰到。
    final allowed = RegExp(
      r'^(dart:(async|collection|convert|math|typed_data)'
      r'|package:flutter/(foundation|scheduler)\.dart'
      r'|package:flterm/flterm\.dart|package:libghostty/libghostty\.dart'
      r'|[a-z_]+\.dart)$', // 同目录的文件
    );
    final directive = RegExp(
      r'''^\s*(import|export|part)\s+['"]([^'"]+)['"]''',
      multiLine: true,
    );
    final directives = [
      for (final file in _dartFiles('lib/infrastructure/terminal'))
        for (final match in directive.allMatches(_read(file)))
          (file: _relative(file), uri: match.group(2)!, text: match.group(0)),
    ];
    expect(directives, isNotEmpty, reason: '对照：要真扫到 import');
    expect([
      for (final d in directives)
        if (!allowed.hasMatch(d.uri)) '${d.file}: ${d.text}',
    ], isEmpty);
  });

  test('连接层把远端字节原样交给终端，不在网络分包处转字符串（TER01）', () {
    final source = _read(File('lib/infrastructure/ssh/ssh_service.dart'));
    expect(source, contains('session.stdout.listen(terminal.feed)'));
    expect(source, contains('terminal.feed(Uint8List.fromList(visible))'));
    expect(source, isNot(contains('decodeTerminalText')));
  });
}
