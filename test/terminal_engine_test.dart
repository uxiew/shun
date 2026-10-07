import 'package:flutter/material.dart';
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
import 'package:netcatty_mobile/presentation/widgets/terminal_engine_status.dart';
import 'package:shared_preferences/shared_preferences.dart';

// R17 起引擎建不起来时连接如实失败（docs/06：UI 显示实际引擎与错误）。R20 起只有 Ghostty，
// 设置里不再有引擎可选；这次运行里引擎实际怎样记在 terminalEngineStatusProvider，设置页照实显示（TER12）。

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('设置', () {
    test('R20 之前存的「终端引擎」（xterm2 / ghostty）照常读进来、被忽略，存回去时不再写', () {
      for (final old in ['xterm2', 'ghostty', 'kitty']) {
        final settings = AppSettings.fromJson(
            {'terminalEngine': old, 'terminalFontSize': 18});
        expect(settings.terminalFontSize, 18, reason: '别的设置不受影响');
        expect(settings.toJson(), isNot(contains('terminalEngine')));
      }
    });

    test('快捷键栏：存的是 R18 的旧默认顺序就换成新默认（PgUp/PgDn 插在方向键旁边）；自己排过的不动', () {
      expect(
        AppSettings.fromJson({'terminalQuickKeys': r18DefaultTerminalQuickKeys})
            .terminalQuickKeys,
        defaultTerminalQuickKeys,
      );
      final mine = [...r18DefaultTerminalQuickKeys.reversed];
      expect(
        AppSettings.fromJson({'terminalQuickKeys': mine}).terminalQuickKeys,
        mine,
        reason: '自己排过的顺序原样保留，PgUp/PgDn 由快捷键栏补在最后',
      );
      expect(defaultTerminalQuickKeys, containsAll(['pageUp', 'pageDown']));
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

  test('新标签只建 Ghostty；引擎状态照实记下：要的、实际用的、建过几个', () async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    final status = container.read(terminalEngineStatusProvider);
    expect(status.requested, 'Ghostty');
    expect(status.effective, isNull, reason: '还没建过终端，不知道就说不知道');

    final terminal = container.read(terminalAdapterFactoryProvider)();
    addTearDown(terminal.dispose);
    expect(terminal, isA<GhosttyTerminalAdapter>());
    expect(terminal.engine, terminalEngineName);
    final after = container.read(terminalEngineStatusProvider);
    expect(after.effective, 'Ghostty');
    expect(after.started, 1);
    expect(after.failure, isNull);
    expect(after.nativeVersion, isNotEmpty, reason: '原生库自己报的版本，设置页显示');

    container.read(terminalEngineStatusProvider.notifier).check();
    expect(container.read(terminalEngineStatusProvider).started, 2,
        reason: '「检查」真建了一个终端');
  });

  test('TER12：建不起来时记下原话，effective 为空；之后又建成了就清掉', () {
    var fail = true;
    final controller = TerminalEngineStatusController(() => fail
        ? throw TerminalEngineUnavailableException(
            'Ghostty',
            ArgumentError('Failed to load dynamic library libghostty.so'),
          )
        : GhosttyTerminalAdapter());
    addTearDown(controller.dispose);

    expect(
        controller.create, throwsA(isA<TerminalEngineUnavailableException>()));
    expect(controller.state.effective, isNull, reason: '没有别的引擎顶上');
    expect('${controller.state.failure}', contains('libghostty.so'));
    expect(controller.state.started, 0);

    controller.check();
    expect(controller.state.failure, isNotNull, reason: '「检查」失败不抛到界面上，照样记下');

    fail = false;
    controller.create().dispose();
    expect(controller.state.failure, isNull);
    expect(controller.state.effective, 'Ghostty');
  });

  test('引擎建不起来：不拨号，等待卡片标失败，写清是引擎的问题、没有别的引擎可换', () async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    final service = _RecordingService();
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      sshServiceProvider.overrideWithValue(service),
      terminalEngineStatusProvider.overrideWith(
        (ref) => TerminalEngineStatusController(
          () => throw TerminalEngineUnavailableException(
            'Ghostty',
            ArgumentError('Failed to load dynamic library libghostty.so'),
          ),
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
    expect(connectionHint(failed.error!), contains('没有别的引擎可换'));
    expect(connectionHint(failed.error!), isNot(contains('xterm2')));
    final status = container.read(terminalEngineStatusProvider);
    expect(status.effective, isNull);
    expect('${status.failure}', contains('libghostty.so'), reason: '设置页看得到原话');
  });
  testWidgets('设置页的终端引擎：照实写引擎、原生库版本、失败原话；点「检查」再试一次', (tester) async {
    var fail = true;
    final container = ProviderContainer(overrides: [
      terminalEngineStatusProvider.overrideWith(
        (ref) => TerminalEngineStatusController(() => fail
            ? throw TerminalEngineUnavailableException(
                'Ghostty',
                ArgumentError('Failed to load dynamic library libghostty.so'),
              )
            : GhosttyTerminalAdapter()),
      ),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: TerminalEngineStatusTile()),
      ),
    ));
    expect(find.text('Ghostty'), findsOneWidget);
    expect(find.text('这次运行还没开过终端'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('terminal-engine-check')));
    await tester.pump();
    final failure = tester
        .widget<Text>(find.byKey(const ValueKey('terminal-engine-failure')))
        .data!;
    expect(failure, contains('libghostty.so'));
    expect(failure, contains('没有别的引擎可换'));

    fail = false;
    await tester.tap(find.byKey(const ValueKey('terminal-engine-check')));
    await tester.pump();
    expect(find.byKey(const ValueKey('terminal-engine-failure')), findsNothing);
    expect(find.textContaining('正常'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^Ghostty \S+')), findsOneWidget,
        reason: '建成过终端后显示原生库自己报的版本');
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
