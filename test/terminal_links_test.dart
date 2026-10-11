import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/terminal_link.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:shun/infrastructure/terminal/terminal_session_adapter.dart';
import 'package:shun/presentation/terminal/terminal_view.dart';
import 'package:shun/presentation/widgets/tailscale_check_card.dart'
    show externalLinkLauncherProvider;

// R19 / TER08、SEC08：终端里的链接。10-07 起点一下终端只叫键盘；长按选字时选中的是链接（或长按落在
// Ghostty 认出的链接上），选字菜单里多「打开链接」，点了只弹确认框，能交给浏览器的只有 http/https；
// 拖动、长按本身不弹框也不打开；远端发不出任何东西。

const _options = TerminalViewOptions(
  fontSize: 14,
  secureKeyboard: false,
  interactive: true,
  transparentBackground: false,
);

const _sheetHost = ValueKey('terminal-link-host');
const _open = ValueKey('terminal-link-open');

void main() {
  group('哪些链接能交给浏览器', () {
    TerminalLinkReview review(String address, {String? shown}) =>
        TerminalLinkReview.of(shownText: shown ?? address, address: address);

    test('http、https 能打开，确认框显示域名', () {
      expect(review('https://example.com/a?b=1').canOpen, isTrue);
      expect(review('http://example.com').canOpen, isTrue);
      expect(review('https://example.com/a').host, 'example.com');
    });

    test('会在手机上触发本地动作的类型一律不打开', () {
      for (final address in [
        'intent://scan/#Intent;scheme=zxing;package=com.evil;end',
        'file:///sdcard/Download/a.apk',
        'javascript:alert(1)',
        'content://com.android.contacts/contacts',
        'tel:10086',
        'sms:10086?body=x',
        'market://details?id=com.evil',
        'ssh://root@host',
        'top.xdwa.shun://callback?state=x',
        'data:text/html,<script>alert(1)</script>',
      ]) {
        expect(review(address).canOpen, isFalse, reason: address);
      }
    });

    test('@ 前面带用户名的网址（https://google.com@evil.example）不打开', () {
      final link = review('https://google.com@evil.example/');
      expect(link.canOpen, isFalse);
      expect(link.host, 'evil.example');
    });

    test('有空白、控制字符、超长、空的都不打开', () {
      expect(review('https://example.com/a b').canOpen, isFalse);
      expect(review('https://example.com/\x1b[31m').canOpen, isFalse);
      expect(
        review('https://example.com/${'a' * TerminalLinkReview.maxLength}')
            .canOpen,
        isFalse,
      );
      expect(review('').canOpen, isFalse);
    });

    test('显示的文字和地址不一样、域名有非英文字符，要提醒', () {
      expect(review('https://evil.example', shown: 'docs').textDiffers, isTrue);
      expect(review('https://example.com').textDiffers, isFalse);
      expect(review('https://exämple.com').nonAsciiHost, isTrue);
      expect(review('https://xn--exmple-cua.com').nonAsciiHost, isTrue);
      expect(review('https://example.com').nonAsciiHost, isFalse);
    });
  });

  group('选中的字是不是网址（选字菜单里给不给「打开链接」）', () {
    test('整段是一个网址才算；两头空白、句末标点可以有', () {
      expect(
          webLinkIn('https://example.com/a?b=1'), 'https://example.com/a?b=1');
      expect(webLinkIn('  http://example.com/x  \n'), 'http://example.com/x');
      expect(webLinkIn('https://example.com/a).'), 'https://example.com/a');
    });

    test('夹着别的字、不是 http/https、空的，都不算', () {
      expect(webLinkIn('打开 https://example.com'), isNull);
      expect(webLinkIn('https://example.com and more'), isNull);
      expect(webLinkIn('https://a.example https://b.example'), isNull);
      expect(webLinkIn('ftp://example.com'), isNull);
      expect(webLinkIn('example.com'), isNull);
      expect(webLinkIn(''), isNull);
    });
  });

  final engines = <String, TerminalSessionAdapterBase Function()>{
    'Ghostty': GhosttyTerminalAdapter.new,
  };

  for (final MapEntry(key: engine, value: newTerminal) in engines.entries) {
    group(engine, () {
      late TerminalSessionAdapterBase terminal;
      late StringBuffer sent;
      late List<Uri> launched;

      Future<void> mount(WidgetTester tester, String output) async {
        tester.view.physicalSize = const Size(1080, 1800);
        tester.view.devicePixelRatio = 2.625;
        addTearDown(tester.view.reset);
        final strategy = tester.binding.schedulingStrategy;
        tester.binding.schedulingStrategy = (
                {required int priority, required SchedulerBinding scheduler}) =>
            true;
        addTearDown(() => tester.binding.schedulingStrategy = strategy);
        terminal = newTerminal();
        addTearDown(terminal.dispose);
        sent = StringBuffer();
        launched = [];
        terminal.bind((bytes) => sent.write(latin1.decode(bytes)));
        terminal.feed(Uint8List.fromList(utf8.encode(output)));
        await tester.pumpWidget(ProviderScope(
          overrides: [
            externalLinkLauncherProvider.overrideWithValue((uri) async {
              launched.add(uri);
              return true;
            }),
          ],
          child: MaterialApp(
            home: Scaffold(body: terminalViewFor(terminal, _options)),
          ),
        ));
        await tester.pump();
        sent.clear();
      }

      Future<void> settle(WidgetTester tester) async {
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      /// 第一行开头几个字的位置（视图四周留 8 的边）。链接都放在第一行开头。
      Offset firstCells(WidgetTester tester) =>
          tester.getTopLeft(find.byType(Scaffold)) + const Offset(20, 14);

      Future<void> longPress(WidgetTester tester, Offset at,
          {Offset drag = Offset.zero}) async {
        final gesture =
            await tester.startGesture(at, kind: PointerDeviceKind.touch);
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
        if (drag != Offset.zero) {
          await gesture.moveBy(drag);
          await tester.pump(const Duration(milliseconds: 50));
        }
        await gesture.up();
        await settle(tester);
      }

      const openLink = ValueKey('open-terminal-link');

      testWidgets('点一下网址：只叫键盘，不弹框、不打开、远端什么都没收到', (tester) async {
        await mount(tester, 'https://example.com/a. trailing text\r\n');
        tester.testTextInput.hide();
        await tester.tapAt(firstCells(tester));
        await settle(tester);
        expect(find.byKey(_sheetHost), findsNothing);
        expect(find.byKey(openLink), findsNothing);
        expect(tester.testTextInput.isVisible, isTrue, reason: '点一下就是叫键盘');
        expect(launched, isEmpty);
        expect(sent.toString(), isEmpty);
      });

      testWidgets('长按网址：选字菜单里多「打开链接」，点了才弹框，点「用浏览器打开」才打开', (
        tester,
      ) async {
        await mount(tester, 'https://example.com/a. trailing text\r\n');
        // 手指不拖：flterm 把整个链接选上。
        await longPress(tester, firstCells(tester));
        expect(find.byKey(_sheetHost), findsNothing, reason: '长按本身不弹框');
        expect(find.byKey(openLink), findsOneWidget);
        expect(launched, isEmpty);

        await tester.tap(find.byKey(openLink));
        await settle(tester);
        expect(find.byKey(_sheetHost), findsOneWidget);
        expect(find.text('example.com'), findsOneWidget);
        expect(find.text('https://example.com/a'), findsOneWidget,
            reason: '句末的句号不算网址');
        expect(launched, isEmpty, reason: '弹框本身不打开');

        await tester.tap(find.byKey(_open));
        await settle(tester);
        expect(launched, [Uri.parse('https://example.com/a')]);
        expect(sent.toString(), isEmpty);
      });

      testWidgets('远端用 OSC 8 把「docs」标成 javascript: 链接：长按后提醒文字和地址不一样，不给打开', (
        tester,
      ) async {
        await mount(
          tester,
          '\x1b]8;;javascript:alert(document.cookie)\x1b\\docs-page\x1b]8;;\x1b\\\r\n',
        );
        await tester.tapAt(firstCells(tester));
        await settle(tester);
        expect(find.byKey(_sheetHost), findsNothing);
        expect(
            find.byKey(const ValueKey('terminal-link-refused')), findsNothing,
            reason: '点一下不弹框');

        await longPress(tester, firstCells(tester));
        await tester.tap(find.byKey(openLink));
        await settle(tester);
        expect(find.byKey(const ValueKey('terminal-link-refused')),
            findsOneWidget);
        expect(find.byKey(const ValueKey('terminal-link-text-differs')),
            findsOneWidget);
        expect(find.byKey(_open), findsNothing);
        expect(launched, isEmpty);
        expect(sent.toString(), isEmpty);
      });

      testWidgets('长按普通的字：菜单里只有「复制」；选区没了按钮跟着消失', (tester) async {
        await mount(tester, 'plain words here\r\nhttps://example.com/b\r\n');
        await longPress(tester, firstCells(tester), drag: const Offset(60, 0));
        expect(find.byKey(const ValueKey('copy-terminal-selection')),
            findsOneWidget);
        expect(find.byKey(openLink), findsNothing);

        // 点一下别处：选区清掉，菜单也没了。
        await tester.tapAt(firstCells(tester).translate(200, 300));
        await tester.pump(kDoubleTapTimeout);
        await settle(tester);
        expect(find.byKey(const ValueKey('copy-terminal-selection')),
            findsNothing);
        expect(find.byKey(openLink), findsNothing);
      });

      testWidgets('从网址上拖动：不弹框、不打开、不发东西', (tester) async {
        await mount(
          tester,
          [for (var i = 0; i < 80; i++) 'https://example.com/$i'].join('\r\n'),
        );
        // 拖动：手指从网址上起步往下拉（翻滚动区）。
        await tester.timedDragFrom(
          firstCells(tester).translate(0, 200),
          const Offset(0, 300),
          const Duration(milliseconds: 300),
        );
        await settle(tester);
        expect(find.byKey(_sheetHost), findsNothing);
        expect(find.byKey(openLink), findsNothing);
        expect(launched, isEmpty);
        expect(sent.toString(), isEmpty);
      });
    });
  }
}
