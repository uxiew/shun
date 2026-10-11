import 'dart:convert';

import 'package:flterm/flterm.dart' as flterm show TerminalView;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:shun/presentation/terminal/ghostty_terminal_view.dart';
import 'package:shun/presentation/terminal/terminal_view.dart';

// R17 / GST02：Ghostty 视图的交接。flterm 一个控制器同一时刻只能挂一个 flterm 视图，
// 第二个来挂直接抛 StateError；R16 的显示权换手时旧视图又不会立刻重建。这里直接造出
// 「同一个终端，旧视图还在、新视图挂上来」的情况（分屏、画中画、换布局时都可能出现）。

const _options = TerminalViewOptions(
  fontSize: 14,
  secureKeyboard: false,
  interactive: true,
  transparentBackground: false,
);

Widget _app(GhosttyTerminalAdapter terminal, List<Key> views,
        {TerminalViewOptions options = _options}) =>
    MaterialApp(
      home: Scaffold(
        body: Column(children: [
          for (final key in views)
            // key 也挂在 Expanded 上：去掉前面的视图时，后面的视图元素原样保留，不按位置换人。
            Expanded(
              key: key,
              child: GhosttyTerminalView(
                key: key,
                adapter: terminal,
                options: options,
              ),
            ),
        ]),
      ),
    );

/// 哪个 Ghostty 视图里挂着 flterm 视图。
List<Key?> _engineHolders(WidgetTester tester) => [
      for (final element in find.byType(flterm.TerminalView).evaluate())
        element.findAncestorWidgetOfExactType<GhosttyTerminalView>()?.key,
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('新视图挂上来时等旧视图先卸下，全程不抛错，最后只挂一个', (tester) async {
    final terminal = GhosttyTerminalAdapter();
    addTearDown(terminal.dispose);
    terminal.feed(Uint8List.fromList(utf8.encode('hello')));
    const a = ValueKey('a');
    const b = ValueKey('b');

    await tester.pumpWidget(_app(terminal, [a]));
    expect(_engineHolders(tester), [a]);

    await tester.pumpWidget(_app(terminal, [a, b]));
    expect(tester.takeException(), isNull, reason: 'flterm 不能被挂第二次');
    expect(_engineHolders(tester), [a], reason: '这一帧旧视图还挂着，新视图先空着');
    for (var i = 0; i < 3; i++) {
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
    expect(_engineHolders(tester), [b], reason: '旧视图让出，新视图接上');

    await tester.pumpWidget(_app(terminal, [b]));
    expect(_engineHolders(tester), [b], reason: '旧视图晚一步销毁不影响新视图');
    expect(tester.takeException(), isNull);

    // 同一个位置换成另一个视图（布局切换时会这样）：同一帧里旧的停用、新的挂上，
    // flterm 的解绑在停用时就做了，新视图这一帧就能接上，不抛错。
    const c = ValueKey('c');
    await tester.pumpWidget(_app(terminal, [c]));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(_engineHolders(tester), [c]);
  });

  testWidgets('自己重建（改字号）不卸下自己的 flterm 视图', (tester) async {
    final terminal = GhosttyTerminalAdapter();
    addTearDown(terminal.dispose);
    const a = ValueKey('a');
    await tester.pumpWidget(_app(terminal, [a]));
    final engine = tester.element(find.byType(flterm.TerminalView));

    await tester.pumpWidget(_app(
      terminal,
      [a],
      options: const TerminalViewOptions(
        fontSize: 18,
        secureKeyboard: false,
        interactive: true,
        transparentBackground: false,
      ),
    ));

    expect(_engineHolders(tester), [a]);
    expect(tester.element(find.byType(flterm.TerminalView)), same(engine),
        reason: '同一个 flterm 视图，不重挂（重挂会丢选区和滚动位置）');
  });

  testWidgets('视图挂着时关掉终端：视图卸下 flterm 视图，之后原生控制器才释放', (tester) async {
    final terminal = GhosttyTerminalAdapter();
    const a = ValueKey('a');
    await tester.pumpWidget(_app(terminal, [a]));

    terminal.dispose();
    expect(terminal.engineReleased, isFalse, reason: '这一帧视图还在');
    await tester.pump();
    await tester.pump();

    expect(find.byType(flterm.TerminalView), findsNothing);
    expect(terminal.engineReleased, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('画中画小窗只看不操作：不抢焦点', (tester) async {
    final terminal = GhosttyTerminalAdapter();
    addTearDown(terminal.dispose);
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.textInput,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.textInput, null));

    await tester.pumpWidget(_app(
      terminal,
      [const ValueKey('pip')],
      options: const TerminalViewOptions(
        fontSize: 14,
        secureKeyboard: false,
        interactive: false,
        transparentBackground: false,
      ),
    ));
    await tester.pump();

    expect(calls.where((call) => call.method == 'TextInput.show'), isEmpty);
    expect(find.byKey(const ValueKey('copy-terminal-selection')), findsNothing);
  });

  // R18：设置里的「安全键盘」在 Ghostty 下也生效（R17 时输入框类型写死 emailAddress）。
  testWidgets('安全键盘：输入框按可见密码处理，关掉后换回', (tester) async {
    final terminal = GhosttyTerminalAdapter();
    addTearDown(terminal.dispose);
    final types = <String?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.textInput,
      (call) async {
        final config = switch (call.method) {
          'TextInput.setClient' => (call.arguments as List)[1] as Map,
          'TextInput.updateConfig' => call.arguments as Map,
          _ => null,
        };
        if (config != null) types.add((config['inputType'] as Map)['name']);
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.textInput, null));
    const secure = TerminalViewOptions(
      fontSize: 14,
      secureKeyboard: true,
      interactive: true,
      transparentBackground: false,
    );

    await tester
        .pumpWidget(_app(terminal, [const ValueKey('a')], options: secure));
    await tester.pump();
    expect(types.last, 'TextInputType.visiblePassword');

    await tester.pumpWidget(_app(terminal, [const ValueKey('a')]));
    await tester.pump();
    expect(types.last, 'TextInputType.emailAddress');
  });
}
