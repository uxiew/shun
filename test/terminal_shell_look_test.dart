import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/screens/terminal_screen.dart';
import 'package:shun/presentation/ui/components.dart';

import 'support/test_terminal.dart';

/// FL-8（R93）：终端外壳换样子以后还得成立的几条。只看外观怎么搭，不看具体颜色值：
/// 层次靠底色、不描边不投影；主色只标当前标签；状态色只在图标上；按钮的点按范围不缩。
void main() {
  HostProfile host(String id) => HostProfile({
        'id': 'h-$id',
        'label': 'box-$id',
        'hostname': '$id.example.com',
        'port': 22,
        'username': 'ops',
        'protocol': 'ssh',
      });

  ActiveTerminalSession tab(String id, {bool connected = true}) {
    final terminal = newTestTerminal();
    addTearDown(terminal.dispose);
    return ActiveTerminalSession(
      id: id,
      host: host(id),
      terminal: terminal,
      verifyHostKey: (_, __, ___) async => true,
      keyboardInteractive: null,
    )..connected = connected;
  }

  late _Controller controller;

  Future<void> open(
    WidgetTester tester,
    SessionState state, {
    double width = 1080,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    final messenger = tester.binding.defaultBinaryMessenger;
    const pip = MethodChannel('top.xdwa.shun/picture_in_picture');
    messenger.setMockMethodCallHandler(pip, (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(pip, null));
    tester.view.physicalSize = Size(width, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    // 同 terminal_connection_banner_test：让 flterm 的空闲任务不等动画。
    final strategy = tester.binding.schedulingStrategy;
    tester.binding.schedulingStrategy =
        ({required int priority, required SchedulerBinding scheduler}) => true;
    addTearDown(() => tester.binding.schedulingStrategy = strategy);
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      sessionControllerProvider.overrideWith((ref) => controller =
          _Controller(ref.read(vaultControllerProvider.notifier), ref, state)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: TerminalScreen())),
    ));
    await tester.pump(const Duration(milliseconds: 500));
  }

  InputChip chipOf(WidgetTester tester, String key) => tester.widget<InputChip>(
        find.descendant(
            of: find.byKey(ValueKey(key)), matching: find.byType(InputChip)),
      );

  Color fillOf(InputChip chip) => chip.color!.resolve(const {})!;

  testWidgets('标签：不描边、超椭圆、底不透明；同一时刻只有一个标签是选中的样子', (tester) async {
    await open(
      tester,
      SessionState(
        sessions: [tab('a'), tab('b', connected: false)],
        pendingConnections: [
          PendingTerminalConnection(id: 'p', host: host('p')),
        ],
      ),
      // 够宽，三个标签都建出来（标签条是懒加载的）。
      width: 2400,
    );
    final a = chipOf(tester, 'terminal-tab-a');
    final b = chipOf(tester, 'terminal-tab-b');
    final p = chipOf(tester, 'pending-terminal-tab-p');
    for (final chip in [a, b, p]) {
      expect(chip.side, BorderSide.none);
      expect(chip.shape, isA<RoundedSuperellipseBorder>());
      expect(fillOf(chip).a, 1.0, reason: '自定义背景下标签名要读得清');
      expect(chip.materialTapTargetSize, MaterialTapTargetSize.padded);
    }
    expect([a.selected, b.selected, p.selected], [true, false, false]);
    expect(fillOf(a), isNot(fillOf(b)));
    expect(fillOf(b), fillOf(p), reason: '没选中的标签同一种中性底');
    expect(a.labelStyle!.color, isNot(b.labelStyle!.color));

    // 切到还在连的标签：原来的会话标签不再是选中的样子。
    controller.publish(controller.state.copyWith(activePendingId: 'p'));
    await tester.pump();
    expect([
      chipOf(tester, 'terminal-tab-a').selected,
      chipOf(tester, 'terminal-tab-b').selected,
      chipOf(tester, 'pending-terminal-tab-p').selected,
    ], [
      false,
      false,
      true
    ]);
  });

  testWidgets('标签条右边的按钮：圆形、落在高一层的底上，能点的范围仍是 48dp', (tester) async {
    await open(tester, SessionState(sessions: [tab('a')]));
    for (final key in [
      'terminal-copy-screen',
      'terminal-performance-monitor'
    ]) {
      final finder = find.byKey(ValueKey(key));
      final button = tester.widget<IconButton>(finder);
      expect(button.style!.shape!.resolve(const {}), isA<CircleBorder>(),
          reason: key);
      expect(button.style!.backgroundColor!.resolve(const {})!.a, 1.0);
      final size = tester.getSize(finder);
      expect(size.width, greaterThanOrEqualTo(48), reason: key);
      expect(size.height, greaterThanOrEqualTo(48), reason: key);
    }
    expect(
        tester.getSize(find.byKey(const ValueKey('terminal-tab-strip'))).height,
        52,
        reason: '有标签时标签条高度不变，终端行数不跟着变');
  });

  testWidgets('没有标签：和别的根页面一样的页头，空状态只有一句', (tester) async {
    await open(tester, const SessionState());
    expect(
      find.descendant(
          of: find.byKey(const ValueKey('terminal-tab-strip')),
          matching: find.byType(ShunPageHeader)),
      findsOneWidget,
    );
    expect(find.text('没有活动会话'), findsOneWidget);
    expect(find.textContaining('从「连接」页'), findsNothing);
  });

  testWidgets('横幅：断开和提醒是同一种中性底，不投影；状态只在图标的颜色上', (tester) async {
    final a = tab('a', connected: false);
    await open(tester, SessionState(sessions: [a]));
    Material surface() => tester.widget<Material>(find
        .descendant(
            of: find.byKey(const ValueKey('terminal-connection-banner')),
            matching: find.byType(Material))
        .first);
    Icon glyph(IconData icon) => tester.widget<Icon>(find.descendant(
        of: find.byKey(const ValueKey('terminal-connection-banner')),
        matching: find.byIcon(icon)));

    final disconnected = surface();
    expect(disconnected.elevation, 0);
    expect(disconnected.color!.a, 1.0);
    final disconnectedGlyph = glyph(Icons.link_off).color;
    expect(disconnectedGlyph, isNotNull);

    a.connected = true;
    controller.publish(SessionState(sessions: [a], keepAliveProblem: '保活没开'));
    await tester.pump();
    final warning = surface();
    expect(warning.color, disconnected.color);
    expect(glyph(Icons.warning_amber_outlined).color, isNot(disconnectedGlyph));
  });

  testWidgets('失败页：卡片不描边不投影；有「重试」时它是唯一的实心按钮', (tester) async {
    await open(
      tester,
      SessionState(
        sessions: [tab('a')],
        pendingConnections: [
          PendingTerminalConnection(
            id: 'p',
            host: host('p'),
            phase: PendingConnectionPhase.failed,
            error: const SocketException('Connection refused'),
            retryable: true,
          ),
        ],
        activePendingId: 'p',
      ),
    );
    final card = tester.widget<Card>(
        find.byKey(const ValueKey('terminal-connection-status-dialog')));
    expect(card.elevation, 0);
    expect(card.shape, isA<RoundedSuperellipseBorder>());
    expect((card.shape! as RoundedSuperellipseBorder).side, BorderSide.none);

    final hint = tester.widget<Container>(
        find.byKey(const ValueKey('connection-failure-hint')));
    final decoration = hint.decoration! as ShapeDecoration;
    expect(decoration.shape, isA<RoundedSuperellipseBorder>());
    expect(decoration.color, isNot(card.color), reason: '提示块比卡片高一层');
    final colors =
        prism.Theme.of(tester.element(find.byType(Card))).colorScheme;
    expect(decoration.color, isNot(colors.secondaryContainer));

    ShunButton button(String key) =>
        tester.widget<ShunButton>(find.byKey(ValueKey(key)));
    expect(button('retry-failed-connection').kind, ShunButtonKind.filled);
    expect(button('close-failed-connection').kind, ShunButtonKind.tonal);
    await tester.tap(find.byKey(const ValueKey('close-failed-connection')));
    await tester.pump();
    expect(controller.dismissed, ['p']);
  });

  testWidgets('失败页：不能重试时「关闭标签页」是主操作', (tester) async {
    await open(
      tester,
      SessionState(
        pendingConnections: [
          PendingTerminalConnection(
            id: 'p',
            host: host('p'),
            phase: PendingConnectionPhase.failed,
            error: const SocketException('Connection refused'),
          ),
        ],
        activePendingId: 'p',
      ),
    );
    expect(
      tester
          .widget<ShunButton>(
              find.byKey(const ValueKey('close-failed-connection')))
          .kind,
      ShunButtonKind.filled,
    );
    expect(find.byKey(const ValueKey('retry-failed-connection')), findsNothing);
  });
}

class _Controller extends SessionController {
  _Controller(VaultController vault, Ref ref, SessionState initial)
      : super(SshService(), vault, ref) {
    state = initial;
  }

  final dismissed = <String>[];

  void publish(SessionState value) => state = value;

  @override
  void dismissPending(String id) => dismissed.add(id);
}
