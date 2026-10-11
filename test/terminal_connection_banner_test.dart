import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/connection_lifecycle.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:shun/presentation/screens/terminal_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

// R22：断开的标签顶上那一条——在恢复、为什么停了、「重新连接」；连着的标签不挂，也不改终端尺寸。
void main() {
  testWidgets('断开的标签写明原因、点「重新连接」交给控制器；连着的不挂', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    final messenger = tester.binding.defaultBinaryMessenger;
    const pip = MethodChannel('top.xdwa.shun/picture_in_picture');
    messenger.setMockMethodCallHandler(pip, (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(pip, null));
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    // 同 terminal_input_routing_test：让 flterm 的空闲任务不等动画，免得假时钟里卡死。
    final strategy = tester.binding.schedulingStrategy;
    tester.binding.schedulingStrategy =
        ({required int priority, required SchedulerBinding scheduler}) => true;
    addTearDown(() => tester.binding.schedulingStrategy = strategy);

    ActiveTerminalSession session(String id) => ActiveTerminalSession(
          id: id,
          host: HostProfile.create(
            id: id,
            label: id,
            hostname: '$id.example.com',
            username: 'root',
          ),
          terminal: GhosttyTerminalAdapter(),
          verifyHostKey: (_, __, ___) async => true,
          keyboardInteractive: null,
        );
    final held = session('held')
      ..connected = false
      ..restoreHold =
          const RestoreHold.untilUser('已从通知「全部断开」。不会自动重连；要继续就点「重新连接」。');
    final live = session('live');
    late _RecordingController controller;
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      sessionControllerProvider.overrideWith((ref) => controller =
          _RecordingController(ref.read(vaultControllerProvider.notifier), ref,
              SessionState(sessions: [held, live]))),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: TerminalScreen())),
    ));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('已从通知「全部断开」。不会自动重连；要继续就点「重新连接」。'), findsOneWidget);
    final terminalBefore =
        tester.getSize(find.byKey(const ValueKey('terminal-area')));
    await tester.tap(find.byKey(const ValueKey('terminal-reconnect')));
    await tester.pump();
    expect(controller.reconnected, ['held']);

    // 正在自动恢复：换成「正在恢复」，没网时说明在等网络。
    controller.publish(controller.state.copyWith(
      recovering: {'held'},
      networkAvailable: false,
    ));
    await tester.pump();
    expect(find.text('连接断了。手机现在没有网络，网络回来后自动恢复。'), findsOneWidget);

    controller.activate(1);
    await tester.pump(const Duration(milliseconds: 500));
    expect(
        find.byKey(const ValueKey('terminal-connection-banner')), findsNothing);
    expect(tester.getSize(find.byKey(const ValueKey('terminal-area'))),
        terminalBefore,
        reason: '状态条叠在终端上，不占终端的位置');
  });
}

class _RecordingController extends SessionController {
  _RecordingController(
    VaultController vaultController,
    Ref ref,
    SessionState initialState,
  ) : super(SshService(), vaultController, ref) {
    state = initialState;
  }

  final reconnected = <String>[];

  void publish(SessionState value) => state = value;

  @override
  Future<void> reconnect(
    String sessionId, {
    required HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
  }) async {
    reconnected.add(sessionId);
  }
}
