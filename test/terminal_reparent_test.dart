import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/screens/terminal_screen.dart';

import 'support/test_terminal.dart';

/// 10-22 Pixel（Android 17）上调试包整页黑屏：终端页被搬家（GlobalKey 移动）时，flterm 的渲染对象重新 attach，
/// 给上一个视图连接里已经销毁的 LinkInteraction 加监听，断言失败，搬家半路中断，首页从路由上脱落。
/// 日常触发它的是 Android 14 起的预测性返回：拖动任何一个压在上面的页面时，底下的首页也换成预测性返回的过场，
/// 整页（含 IndexedStack 里挂着的终端页）搬一次家，手势结束再搬回来。Android 11 模拟器没有这个手势，复现不出来。
/// 去掉 flterm 里 `TerminalRenderBox.attach` 的那个判断，这里两条都会报 “A LinkInteraction was used after being disposed”。
void main() {
  ActiveTerminalSession tab(String id) {
    final terminal = newTestTerminal();
    addTearDown(terminal.dispose);
    return ActiveTerminalSession(
      id: id,
      host: HostProfile({
        'id': 'h-$id',
        'label': 'box',
        'hostname': 'box.example.com',
        'port': 22,
        'username': 'ops',
        'protocol': 'ssh',
      }),
      terminal: terminal,
      verifyHostKey: (_, __, ___) async => true,
      keyboardInteractive: null,
    );
  }

  Future<void> open(WidgetTester tester, Widget Function(Widget) wrap) async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    final messenger = tester.binding.defaultBinaryMessenger;
    const pip = MethodChannel('top.xdwa.shun/picture_in_picture');
    messenger.setMockMethodCallHandler(pip, (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(pip, null));
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    // 同 terminal_transport_ui_test：让 flterm 的空闲任务不等动画。
    final strategy = tester.binding.schedulingStrategy;
    tester.binding.schedulingStrategy =
        ({required int priority, required SchedulerBinding scheduler}) => true;
    addTearDown(() => tester.binding.schedulingStrategy = strategy);
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      sessionControllerProvider.overrideWith((ref) => _Controller(
          ref.read(vaultControllerProvider.notifier),
          ref,
          SessionState(sessions: [tab('a'), tab('b')]))),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: wrap(const TerminalScreen()),
    ));
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// 终端页还挂在树上：往上能走到根（黑屏时它的祖先链半路断了），整棵树里没有已销毁还挂着的元素。
  void expectAttached(WidgetTester tester) {
    // 取消手势后首页又被上层页面盖住，默认的查找跳过被盖住的。
    final screen =
        tester.element(find.byType(TerminalScreen, skipOffstage: false));
    Element? top;
    screen.visitAncestorElements((element) {
      top = element;
      return true;
    });
    expect(top, same(WidgetsBinding.instance.rootElement));
    expect(WidgetsBinding.instance.rootElement!.toStringDeep(),
        isNot(contains('DEFUNCT')));
  }

  Future<void> pumpFor(WidgetTester tester, Duration total) async {
    for (var spent = Duration.zero;
        spent < total;
        spent += const Duration(milliseconds: 100)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> backGesture(WidgetTester tester, String method,
      [Map<String, Object?>? args]) async {
    final message =
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args));
    await tester.binding.defaultBinaryMessenger
        .handlePlatformMessage('flutter/backgesture', message, (_) {});
  }

  for (final ending in ['commitBackGesture', 'cancelBackGesture']) {
    testWidgets('终端页上压一页，用 Android 预测性返回拖动（$ending）：终端页不脱落、不报错',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await open(tester, (child) => MaterialApp(home: Scaffold(body: child)));
        tester.state<NavigatorState>(find.byType(Navigator)).push(
            MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('上层页面'))));
        // 终端光标一直闪，pumpAndSettle 等不到停。
        await pumpFor(tester, const Duration(milliseconds: 600));

        await backGesture(tester, 'startBackGesture', {
          'touchOffset': <double>[5.0, 300.0],
          'progress': 0.0,
          'swipeEdge': 0,
        });
        await tester.pump();
        for (final progress in [0.1, 0.25, 0.4]) {
          await backGesture(tester, 'updateBackGestureProgress', {
            'x': 1000.0 * progress,
            'y': 300.0,
            'progress': progress,
            'swipeEdge': 0,
          });
          await tester.pump(const Duration(milliseconds: 16));
        }
        expectAttached(tester);
        await backGesture(tester, ending);
        await pumpFor(tester, const Duration(milliseconds: 800));

        expect(tester.takeException(), isNull);
        expectAttached(tester);
        expect(find.text('上层页面'),
            ending == 'commitBackGesture' ? findsNothing : findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('终端页用 GlobalKey 搬到别的父组件下：终端照常挂着、不报错', (tester) async {
    final key = GlobalKey();
    final moved = ValueNotifier(false);
    addTearDown(moved.dispose);
    await open(
      tester,
      (child) => MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: moved,
            builder: (context, value, _) {
              final keyed = KeyedSubtree(key: key, child: child);
              return value
                  ? Padding(padding: EdgeInsets.zero, child: keyed)
                  : keyed;
            },
          ),
        ),
      ),
    );
    final before = tester.state(find.byType(TerminalScreen));

    moved.value = true;
    await tester.pump();
    expect(tester.takeException(), isNull);
    expectAttached(tester);
    expect(tester.state(find.byType(TerminalScreen)), same(before),
        reason: '是搬家，不是重建：标签和终端状态都在');

    moved.value = false;
    await tester.pump();
    expect(tester.takeException(), isNull);
    expectAttached(tester);
  });
}

class _Controller extends SessionController {
  _Controller(VaultController vault, Ref ref, SessionState initial)
      : super(SshService(), vault, ref) {
    state = initial;
  }
}
