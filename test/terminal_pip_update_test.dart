import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/ssh/terminal_picture_in_picture_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:shun/presentation/screens/terminal_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 画中画小窗里的文字是终端页按适配器的通知、隔 1 秒推给原生层的。R20 换成只剩 Ghostty 时查出：
// flterm 只在模式这类状态变时通知，远端只是多出几行字的话，小窗一直停在旧内容上。
const _channel = MethodChannel('top.xdwa.shun/picture_in_picture');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('画中画开着时远端来了新输出：一秒内推给小窗的文字里有它', (tester) async {
    // flterm 的空闲任务碰上动画时，假时钟下推进时间会死循环（docs/dev/README.md 第 7 节）。
    final strategy = tester.binding.schedulingStrategy;
    tester.binding.schedulingStrategy =
        ({required int priority, required SchedulerBinding scheduler}) => true;
    addTearDown(() => tester.binding.schedulingStrategy = strategy);

    final updates = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'enter') return true;
      if (call.method == 'update') {
        updates.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));

    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    final terminal = GhosttyTerminalAdapter();
    terminal.feed(utf8.encode('before-pip\r\n'));
    final session = ActiveTerminalSession(
      id: 's1',
      host: HostProfile.create(
          id: 'h1', label: 'h1', hostname: 'h1.example.com', username: 'u'),
      terminal: terminal,
      verifyHostKey: (_, __, ___) async => true,
      keyboardInteractive: null,
    );
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      sessionControllerProvider.overrideWith(
        (ref) => _Seeded(ref.read(vaultControllerProvider.notifier), ref,
            SessionState(sessions: [session])),
      ),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: TerminalScreen())),
    ));
    await tester.pump();

    // 和点「画中画」按钮一样：原生层进了画中画，页面切到小窗布局。
    expect(
      await TerminalPictureInPictureService.enter(
        title: 'h1',
        text: 'before-pip',
        connected: true,
        backgroundColor: 0,
        foregroundColor: 0,
        accentColor: 0,
      ),
      isTrue,
    );
    container.read(terminalPictureInPictureProvider.notifier).state = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1200));
    updates.clear();

    terminal.feed(utf8.encode('only-new-text-arrived\r\n'));
    await tester.pump(const Duration(milliseconds: 1200));

    expect(updates, isNotEmpty, reason: '只多了几行字，小窗也要刷新');
    expect(updates.last, contains('only-new-text-arrived'));

    container.read(terminalPictureInPictureProvider.notifier).state = false;
    await tester.pump();
    terminal.dispose();
  });
}

class _Seeded extends SessionController {
  _Seeded(VaultController vaultController, Ref ref, SessionState initial)
      : super(SshService(), vaultController, ref) {
    state = initial;
  }
}
