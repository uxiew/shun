import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/connection_diagnosis.dart';
import 'package:netcatty_mobile/application/session_controller.dart';
import 'package:netcatty_mobile/application/settings_controller.dart';
import 'package:netcatty_mobile/application/terminal_engine.dart';
import 'package:netcatty_mobile/domain/connection_route.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/models/settings.dart';
import 'package:netcatty_mobile/domain/tmux/tmux_target.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:netcatty_mobile/infrastructure/terminal/terminal_session_adapter.dart';
import 'package:netcatty_mobile/infrastructure/terminal/xterm_terminal_adapter.dart';
import 'package:shared_preferences/shared_preferences.dart';

// R17：设置里选终端引擎；引擎建不起来时连接如实失败（docs/06：UI 显示实际引擎与错误）。

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('设置', () {
    test('默认 xterm2；认得 ghostty；不认识的值回到 xterm2', () {
      expect(const AppSettings().terminalEngine, terminalEngineXterm2);
      expect(
        AppSettings.fromJson({'terminalEngine': 'ghostty'}).terminalEngine,
        terminalEngineGhostty,
      );
      expect(
        AppSettings.fromJson({'terminalEngine': 'kitty'}).terminalEngine,
        terminalEngineXterm2,
      );
      expect(
        AppSettings.fromJson(
          const AppSettings(terminalEngine: terminalEngineGhostty).toJson(),
        ).terminalEngine,
        terminalEngineGhostty,
      );
    });

    test('「全屏程序里滑动翻页」默认关；存了能读回来，不是 true 的一律当关', () async {
      expect(const AppSettings().terminalFullscreenSwipe, isFalse);
      expect(
        AppSettings.fromJson(
          const AppSettings(terminalFullscreenSwipe: true).toJson(),
        ).terminalFullscreenSwipe,
        isTrue,
      );
      expect(
        AppSettings.fromJson({'terminalFullscreenSwipe': 'yes'})
            .terminalFullscreenSwipe,
        isFalse,
      );

      SharedPreferences.setMockInitialValues({});
      final repository = await VaultRepository.open();
      final container = ProviderContainer(overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
      ]);
      addTearDown(container.dispose);
      await container
          .read(settingsControllerProvider.notifier)
          .updateTerminalFullscreenSwipe(true);
      expect((await repository.loadSettings()).terminalFullscreenSwipe, isTrue);
    });
  });

  test('建终端时才读设置：改了只影响之后新开的，会话控制器不重建、开着的会话不受影响', () async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    await container.read(settingsControllerProvider.notifier).load();
    final sessions = container.read(sessionControllerProvider.notifier);
    final newTerminal = container.read(terminalAdapterFactoryProvider);

    final before = newTerminal();
    addTearDown(before.dispose);
    expect(before, isA<XtermTerminalAdapter>());

    await container
        .read(settingsControllerProvider.notifier)
        .updateTerminalEngine(terminalEngineGhostty);
    final after = newTerminal();
    addTearDown(after.dispose);
    expect(after, isA<GhosttyTerminalAdapter>());
    expect(after.engine, 'Ghostty');
    expect(container.read(sessionControllerProvider.notifier), same(sessions));
  });

  test('引擎建不起来：不拨号，等待卡片标失败，写清是引擎的问题、怎么改回去', () async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    final service = _RecordingService();
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      sshServiceProvider.overrideWithValue(service),
      terminalAdapterFactoryProvider.overrideWithValue(
        () => throw TerminalEngineUnavailableException(
          'Ghostty',
          ArgumentError('Failed to load dynamic library libghostty.so'),
        ),
      ),
    ]);
    addTearDown(container.dispose);
    final controller = container.read(sessionControllerProvider.notifier);

    await expectLater(
      controller.connect(
        HostProfile.create(
          id: 'h1',
          label: 'h1',
          hostname: 'h1.example.com',
          username: 'root',
        ),
        (_, __, ___) async => true,
      ),
      throwsA(isA<TerminalEngineUnavailableException>()),
    );

    expect(service.connected, isEmpty, reason: '引擎都没起来，不去拨号');
    final failed = controller.state.pendingConnections.single;
    expect(failed.phase, PendingConnectionPhase.failed);
    expect('${failed.error}', contains('Ghostty'));
    expect('${failed.error}', contains('libghostty.so'));
    expect(connectionHint(failed.error!), contains('改回 xterm2'));
  });
}

class _RecordingService extends SshService {
  final connected = <String>[];

  @override
  Future<ActiveTerminalSession> connect({
    required String sessionId,
    required HostProfile host,
    List<HostProfile> hosts = const [],
    List<SshKeyProfile> keys = const [],
    List<ProxyProfile> proxyProfiles = const [],
    RoutePlan? routePlan,
    required HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
    required TerminalSessionAdapter terminal,
    ConnectionPurpose purpose = ConnectionPurpose.fresh,
    ConnectionAttempt? attempt,
    TmuxTarget? tmuxAttach,
  }) {
    connected.add(host.id);
    throw StateError('不该拨号');
  }
}
