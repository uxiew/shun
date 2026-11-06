import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flterm/flterm.dart' as flterm show TerminalView;
import 'package:flutter/cupertino.dart' show CupertinoLocalizations;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/prism_ui.dart' as p;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/app.dart';
import 'package:shun/application/app_lock.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/settings_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/settings.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/domain/security_key.dart';
import 'package:shun/infrastructure/device_auth.dart';
import 'package:shun/infrastructure/http_client_provider.dart';
import 'package:shun/infrastructure/ssh/connection_platform_service.dart';
import 'package:shun/infrastructure/ssh/security_key_channel.dart';
import 'package:shun/infrastructure/ssh/sftp_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/tailscale/catalog_cache.dart';
import 'package:shun/infrastructure/tailscale/catalog_cache_repository.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:shun/presentation/home_shell.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';
import 'package:shun/presentation/screens/terminal_screen.dart';
import 'package:shun/presentation/terminal/ghostty_terminal_view.dart';
import 'package:shun/presentation/terminal/terminal_view.dart';
import 'package:shun/presentation/ui/shun_ui_host.dart';
import 'package:shun/presentation/widgets/security_key_prompt.dart';

import 'support/ui_gallery_fixtures.dart';

// R82：用生产宿主验证根导航、兼容层、提示/锁罩和真实 Ghostty 视图。
// 设备认证由 fixture 返回结果；不把这些 Widget 测试计作真机验证。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => ShunLocalizations.use('zh-CN'));
  tearDown(() => ShunLocalizations.use('zh-CN'));

  testWidgets('遮挡和锁定阻断硬件输入，返回后恢复原焦点', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final received = <LogicalKeyboardKey>[];
    final fixture = await _HostFixture.open(
      tester,
      home: Scaffold(
        body: Focus(
          autofocus: true,
          focusNode: focus,
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent) received.add(event.logicalKey);
            return KeyEventResult.handled;
          },
          child: const Text('键盘目标'),
        ),
      ),
    );

    expect(focus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(received, [LogicalKeyboardKey.arrowRight]);
    received.clear();

    fixture.lock.settingsChanged(
      const AppSettings(appLockEnabled: true, appLockGraceSeconds: 3600),
    );
    fixture.lock.activityPaused(false);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(received, isEmpty, reason: '开始遮挡的首帧前也不能穿透');
    await tester.pump();
    expect(fixture.lock.state.covered, isTrue);
    expect(fixture.lock.state.locked, isFalse);
    expect(focus.hasFocus, isFalse, reason: '遮挡时先关闭输入，返回后还给原节点');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: 'a');
    expect(received, isEmpty, reason: '遮挡期间不能把按键交给底下的终端或输入框');

    fixture.lock.lifecycleChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(fixture.lock.state.obscured, isFalse);
    expect(focus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(received, [LogicalKeyboardKey.arrowRight]);

    // A second cover before the queued restore must retain the original node.
    fixture.lock.activityPaused(false);
    fixture.lock.lifecycleChanged(AppLifecycleState.resumed);
    fixture.lock.activityPaused(false);
    await tester.pump();
    expect(focus.hasFocus, isFalse);
    fixture.lock.lifecycleChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(focus.hasFocus, isTrue);

    received.clear();
    fixture.lock.settingsChanged(
      const AppSettings(appLockEnabled: true, appLockGraceSeconds: 0),
    );
    fixture.lock.activityPaused(false);
    await tester.pump();
    fixture.lock.lifecycleChanged(AppLifecycleState.resumed);
    // locked 已同步生效，ExcludeFocus 还没来得及 build 的这一段也要挡住。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(received, isEmpty, reason: 'covered → locked 帧间不能穿透');
    await tester.pump();
    await tester.pump();
    expect(focus.hasFocus, isFalse);
  });

  testWidgets('covered 后旧 IME client 不能向真实 Ghostty 写字或提交', (tester) async {
    _allowIdleTasks(tester);
    final terminal = GhosttyTerminalAdapter()
      ..feed(utf8.encode('\x1b[?25l'));
    final sent = <int>[];
    final binding = terminal.bind(sent.addAll);
    addTearDown(() {
      binding.release();
      terminal.dispose();
    });
    final fixture = await _HostFixture.open(
      tester,
      home: Scaffold(
        body: GhosttyTerminalView(
          adapter: terminal,
          options: const TerminalViewOptions(
            fontSize: 14,
            secureKeyboard: true,
            interactive: true,
            transparentBackground: false,
          ),
        ),
      ),
    );
    await _frames(tester);
    final engine = find.byType(flterm.TerminalView);
    final input = tester.widget<flterm.TerminalView>(engine).focusNode!;
    final oldClient = _textInputClient(tester);
    expect(input.hasFocus, isTrue);
    sent.clear();
    await _sendEditingState(tester, oldClient, 'live');
    expect(latin1.decode(sent), contains('live'),
        reason: '同一个真实 client 的 IME 通道确实能写入 PTY');
    sent.clear();
    await _sendTextInput(tester, 'TextInputClient.performAction', [
      oldClient,
      'TextInputAction.newline',
    ]);
    expect(sent, isNotEmpty, reason: '无遮挡时 action 能向终端提交');
    sent.clear();

    fixture.lock.settingsChanged(
      const AppSettings(appLockEnabled: true, appLockGraceSeconds: 3600),
    );
    fixture.lock.activityPaused(false);
    await tester.pump();
    // 模拟系统在 clearClient 前排队的消息；不使用 debug 永远放行的 -1。
    await _sendEditingState(tester, oldClient, 'blocked');
    await _sendTextInput(tester, 'TextInputClient.performAction', [
      oldClient,
      'TextInputAction.newline',
    ]);
    expect(sent, isEmpty, reason: '遮挡后旧 IME 的文字和提交都不能进 PTY');
    expect(input.hasFocus, isFalse);
    expect(tester.testTextInput.hasAnyClients, isFalse);

    fixture.lock.lifecycleChanged(AppLifecycleState.resumed);
    await _frames(tester);
    expect(tester.widget<flterm.TerminalView>(engine).focusNode, same(input));
    expect(input.hasFocus, isTrue);
    final currentClient = _textInputClient(tester);
    expect(currentClient, isNot(oldClient));
    await _sendEditingState(tester, currentClient, 'returned');
    expect(latin1.decode(sent), contains('returned'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('单 Navigator 中两套输入、主题、本地化和系统大字都有效', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final materialText = TextEditingController();
    final prismText = TextEditingController();
    addTearDown(materialText.dispose);
    addTearDown(prismText.dispose);
    final homeKey = GlobalKey();
    var pressed = 0;
    final fixture = await _HostFixture.open(
      tester,
      home: Scaffold(
        key: homeKey,
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              TextField(
                key: const ValueKey('material-field'),
                controller: materialText,
                decoration: const InputDecoration(labelText: 'Material'),
              ),
              const SizedBox(height: 20),
              p.TextField(
                key: const ValueKey('prism-field'),
                controller: prismText,
                decoration: const p.InputDecoration(hintText: 'Prism'),
              ),
              const SizedBox(height: 20),
              p.FilledButton(
                key: const ValueKey('prism-submit'),
                onPressed: () => pressed++,
                child: const Text('提交'),
              ),
            ],
          ),
        ),
      ),
    );
    final navigator = fixture.navigatorKey.currentState;
    final page = tester.state(find.byKey(homeKey));
    final rootRoute = ModalRoute.of(homeKey.currentContext!)! as PageRoute;
    expect(find.byType(WidgetsApp), findsOneWidget);
    expect(find.byType(Navigator), findsOneWidget);
    expect(find.byType(MaterialApp), findsNothing);
    expect(find.byType(p.PrismApp), findsNothing);
    expect(find.byType(p.ThemeCrossFade), findsNothing);
    expect(rootRoute, isA<PageRouteBuilder>());
    expect(rootRoute.allowSnapshotting, isFalse);
    expect(
      tester.widget<p.RemoteFocusAdapter>(find.byType(p.RemoteFocusAdapter))
          .enabled,
      isFalse,
    );
    expect(Theme.of(homeKey.currentContext!).colorScheme, _lightTheme.colorScheme);
    expect(p.Theme.of(homeKey.currentContext!).colorScheme.primary,
        _lightTheme.colorScheme.primary);
    expect(MediaQuery.textScalerOf(homeKey.currentContext!).scale(16), 32);

    await tester.enterText(find.byKey(const ValueKey('material-field')), 'draft');
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('prism-field')),
        matching: find.byType(EditableText),
      ),
      'prism draft',
    );
    await tester.tap(find.byKey(const ValueKey('prism-submit')));
    await tester.pump();
    expect(pressed, 1);

    fixture.mode.value = ThemeMode.dark;
    fixture.locale.value = const Locale('en');
    await _frames(tester);
    final context = homeKey.currentContext!;
    expect(fixture.navigatorKey.currentState, same(navigator));
    expect(tester.state(find.byKey(homeKey)), same(page));
    expect(materialText.text, 'draft');
    expect(prismText.text, 'prism draft');
    expect(Theme.of(context).colorScheme, _darkTheme.colorScheme);
    expect(p.Theme.of(context).colorScheme.primary, _darkTheme.colorScheme.primary);
    expect(MediaQuery.textScalerOf(context).scale(16), 32);
    expect(MaterialLocalizations.of(context).copyButtonLabel, 'Copy');
    expect(CupertinoLocalizations.of(context).copyButtonLabel, 'Copy');
    expect(WidgetsLocalizations.of(context).textDirection, TextDirection.ltr);
    expect(p.UiLocalizations.of(context).copy, localized('复制'));
    expect(p.UiLocalizations.of(context).copy, 'Copy');
    expect(tester.takeException(), isNull);
  });

  testWidgets('全局提示和认证弹框都在锁罩下，换主题不回放旧图', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      var backgroundTaps = 0;
      var bannerTaps = 0;
      var snackTaps = 0;
      final fixture = await _HostFixture.open(
        tester,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: TextButton(
              key: const ValueKey('background-action'),
              onPressed: () => backgroundTaps++,
              child: const Text('r82-background'),
            ),
          ),
        ),
      );
      final context = fixture.navigatorKey.currentContext!;
      final navigator = fixture.navigatorKey.currentState;
      p.BannerHost.maybeOf(context)!.show(
        'r82-banner',
        onTap: () => bannerTaps++,
      );
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('r82-snack'),
        duration: const Duration(minutes: 1),
        action: SnackBarAction(label: 'r82-action', onPressed: () => snackTaps++),
      ));
      await _frames(tester);
      expect(find.semantics.byLabel(RegExp('r82-banner')).evaluate(), isNotEmpty);
      expect(find.semantics.byLabel(RegExp('r82-snack')).evaluate(), isNotEmpty);

      final channel = _SecurityKeyChannel();
      addTearDown(channel.events.close);
      final result = showSecurityKeyPrompt<String>(
        context,
        channel,
        title: 'r82-auth',
        detail: 'fixture@example.test',
        pinFirst: true,
        run: (_) async => 'signed',
      ).then<Object>((value) => value,
          onError: (Object error, StackTrace stack) => error);
      await _frames(tester);
      final prompt = find.byType(SecurityKeyPrompt<String>);
      final promptState = tester.state(prompt);
      final pin = tester.widget<EditableText>(find.descendant(
        of: find.byKey(const ValueKey('security-key-pin')),
        matching: find.byType(EditableText),
      ));
      expect(pin.focusNode.hasFocus, isTrue);
      expect(find.semantics.byLabel(RegExp('r82-auth')).evaluate(), isNotEmpty);

      fixture.lock.settingsChanged(
        const AppSettings(appLockEnabled: true, appLockGraceSeconds: 0),
      );
      fixture.mode.value = ThemeMode.dark;
      fixture.lock.activityPaused(false);
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byKey(const ValueKey('app-lock-cover')), findsOneWidget);
      expect(pin.focusNode.hasFocus, isFalse, reason: 'covered 也要关闭 IME 连接');
      for (final text in ['r82-banner', 'r82-snack', 'r82-auth', 'r82-background']) {
        expect(find.semantics.byLabel(RegExp(text)).evaluate(), isEmpty);
      }
      await _expectCoverPixels(tester, fixture, _darkTheme.colorScheme.surface);
      await tester.tap(find.text('r82-banner'), warnIfMissed: false);
      await tester.tap(find.text('r82-action'), warnIfMissed: false);
      await tester.tap(
        find.byKey(const ValueKey('security-key-cancel')),
        warnIfMissed: false,
      );
      expect(bannerTaps, 0);
      expect(snackTaps, 0);
      expect(channel.cancelCalls, 0);

      fixture.lock.lifecycleChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect(fixture.lock.state.locked, isTrue);
      expect(pin.focusNode.hasFocus, isFalse);
      final unlockCalls = fixture.auth.authenticateCalls;
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(fixture.auth.authenticateCalls, unlockCalls + 1,
          reason: '锁罩自身的解锁按钮仍接受硬件键盘');
      expect(channel.cancelCalls, 0);
      fixture.mode.value = ThemeMode.light;
      await tester.pump(const Duration(milliseconds: 16));
      await _expectCoverPixels(tester, fixture, _lightTheme.colorScheme.surface);
      expect(find.byType(p.ThemeCrossFade), findsNothing);

      fixture.auth.next = const DeviceAuthOutcome(DeviceAuthResult.success);
      await fixture.lock.unlock();
      await tester.pump();
      await tester.pump();
      expect(fixture.navigatorKey.currentState, same(navigator));
      expect(tester.state(prompt), same(promptState));
      expect(pin.focusNode.hasFocus, isTrue);
      expect(find.byKey(const ValueKey('app-lock-cover')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('security-key-cancel')));
      await _frames(tester);
      expect(await result, isA<SecurityKeyException>());
      expect(channel.cancelCalls, 1);
      await tester.tap(find.text('r82-banner'));
      await tester.tap(find.text('r82-action'));
      await tester.tap(find.byKey(const ValueKey('background-action')));
      expect(bannerTaps, 1);
      expect(snackTaps, 1);
      expect(backgroundTaps, 1);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('Prism 本地面板背景能点、返回可收起；模态确认保持阻断', (tester) async {
    final fixture = await _HostFixture.open(tester, home: const _PanelProbe());
    final navigator = fixture.navigatorKey.currentState!;
    final state = tester.state<_PanelProbeState>(find.byType(_PanelProbe));
    await tester.tap(find.byKey(const ValueKey('open-panel')));
    await _frames(tester);
    expect(find.byKey(const ValueKey('non-modal-panel')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('panel-background')));
    expect(state.backgroundTaps, 1, reason: '真正点击背景，不按 barrier 数量猜测');
    expect(find.byKey(const ValueKey('non-modal-panel')), findsOneWidget);
    await navigator.maybePop();
    await _frames(tester);
    expect(find.byKey(const ValueKey('non-modal-panel')), findsNothing);
    expect(find.byType(_PanelProbe), findsOneWidget);

    final dialog = p.showFloatingDialog<void>(
      context: fixture.navigatorKey.currentContext!,
      dismissible: false,
      child: p.AlertDialog(
        title: 'r82-confirm',
        actions: [
          p.TextButton(
            key: const ValueKey('close-prism-dialog'),
            onPressed: navigator.pop,
            child: const Text('关闭'),
          ),
        ],
        child: const Text('r82-modal'),
      ),
    );
    await _frames(tester);
    await tester.tap(
      find.byKey(const ValueKey('panel-background')),
      warnIfMissed: false,
    );
    expect(state.backgroundTaps, 1);
    expect(find.text('r82-modal'), findsOneWidget);
    expect(find.byType(Navigator), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('close-prism-dialog')));
    await _frames(tester);
    await dialog;
    await tester.tap(find.byKey(const ValueKey('panel-background')));
    expect(state.backgroundTaps, 2);
    expect(fixture.navigatorKey.currentState, same(navigator));
    expect(tester.takeException(), isNull);
  });


  testWidgets('Ghostty 持续输出时 push/pop、切主题和锁罩保留单视图及输入焦点',
      (tester) async {
    _allowIdleTasks(tester);
    final terminal = GhosttyTerminalAdapter()
      ..feed(utf8.encode('\x1b[?25lbefore-route\r\n'));
    final sent = <int>[];
    final binding = terminal.bind(sent.addAll);
    addTearDown(() {
      binding.release();
      terminal.dispose();
    });
    final fixture = await _HostFixture.open(
      tester,
      home: Scaffold(
        body: GhosttyTerminalView(
          adapter: terminal,
          options: const TerminalViewOptions(
            fontSize: 14,
            secureKeyboard: true,
            interactive: true,
            transparentBackground: false,
            softKeyboard: false,
          ),
        ),
      ),
    );
    await _frames(tester);
    final view = find.byType(GhosttyTerminalView, skipOffstage: false);
    final engine = find.byType(flterm.TerminalView, skipOffstage: false);
    final viewState = tester.state(view);
    final engineState = tester.state(engine);
    final input = tester.widget<flterm.TerminalView>(engine).focusNode!;
    expect(input.hasFocus, isTrue);
    expect(terminal.hasActiveView, isTrue);
    expect(terminal.hasEngineView, isTrue);
    sent.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(latin1.decode(sent), '\x1b[A', reason: '方向键交给终端，不当遥控导航');

    var line = 0;
    final output = Timer.periodic(const Duration(milliseconds: 20), (_) {
      line++;
      terminal.feed(utf8.encode('stream-$line\r\n'));
    });
    addTearDown(output.cancel);
    final returned = fixture.navigatorKey.currentState!.push<void>(
      p.CardPageRoute<void>(
        settings: const RouteSettings(name: '/host-probe'),
        builder: (_) => const Scaffold(
          body: TextField(autofocus: true),
        ),
      ),
    );
    await _frames(tester);
    expect(input.hasFocus, isFalse, reason: '上层页面获得自己的输入焦点');
    final whileCovered = line;
    fixture.mode.value = ThemeMode.dark;
    await _frames(tester);
    expect(line, greaterThan(whileCovered));
    expect(terminal.allText(), contains('stream-$line'));
    expect(tester.state(view), same(viewState));
    expect(tester.state(engine), same(engineState));
    expect(engine, findsOneWidget);
    expect(terminal.isDisposed, isFalse);

    fixture.navigatorKey.currentState!.pop();
    await _frames(tester);
    await returned;
    expect(tester.state(view), same(viewState));
    expect(tester.state(engine), same(engineState));
    expect(tester.widget<flterm.TerminalView>(engine).focusNode, same(input));
    expect(input.hasFocus, isTrue);
    sent.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(latin1.decode(sent), '\x1b[B');

    fixture.lock.settingsChanged(
      const AppSettings(appLockEnabled: true, appLockGraceSeconds: 0),
    );
    fixture.lock.activityPaused(false);
    await tester.pump();
    sent.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(sent, isEmpty);
    final whileLocked = line;
    fixture.lock.lifecycleChanged(AppLifecycleState.resumed);
    // 状态先变，ExcludeFocus 还没重建的窗口也不得把输入交给终端。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(sent, isEmpty);
    await _frames(tester);
    expect(input.hasFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(sent, isEmpty);
    expect(line, greaterThan(whileLocked), reason: '锁罩不停止终端接收输出');
    fixture.auth.next = const DeviceAuthOutcome(DeviceAuthResult.success);
    await fixture.lock.unlock();
    await tester.pump();
    await tester.pump();
    expect(input.hasFocus, isTrue);
    expect(tester.state(view), same(viewState));
    expect(tester.state(engine), same(engineState));
    sent.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(latin1.decode(sent), '\x1b[A');
    expect(terminal.allText(), contains('stream-$line'));
    expect(tester.takeException(), isNull);
    output.cancel();
  });

  testWidgets('真实 ShunApp 和 HomeShell 的五入口及两个终端标签保持原导航树',
      (tester) async {
    _allowIdleTasks(tester);
    tester.view.physicalSize = const Size(824, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'shun',
      packageName: 'top.xdwa.shun.debug',
      version: '1.4.7',
      buildNumber: '33',
      buildSignature: '',
    );
    final paths = (await tester.runAsync(UiGalleryPaths.create))!;
    paths.install();
    addTearDown(() => tester.runAsync(paths.dispose));
    const secureStorage =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    const pip = MethodChannel('top.xdwa.shun/picture_in_picture');
    final messenger = tester.binding.defaultBinaryMessenger;
    final secrets = <String, String>{};
    messenger.setMockMethodCallHandler(secureStorage, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          return secrets[key];
        case 'write':
          secrets[key!] = args['value'] as String;
          return null;
        case 'delete':
          secrets.remove(key);
          return null;
        case 'readAll':
          return Map<String, String>.of(secrets);
        case 'containsKey':
          return secrets.containsKey(key);
        default:
          return null;
      }
    });
    messenger.setMockMethodCallHandler(pip, (_) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(secureStorage, null);
      messenger.setMockMethodCallHandler(pip, null);
    });

    final repository = await VaultRepository.open();
    await repository.saveSettings(const AppSettings(
      themeMode: 'light',
      language: 'zh-CN',
      autoSyncEnabled: false,
    ));
    await repository.saveVault(
      VaultData.empty().copyWith(hosts: uiGalleryHosts),
    );
    // 两个已有标签用真 Ghostty 接收 fixture VT，没有 SSH/socket。
    final seed = uiGallerySessions();
    seed.sessions.last.terminal.dispose();
    final sessions = SessionState(sessions: seed.sessions.take(2).toList());
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      catalogCacheRepositoryProvider.overrideWithValue(_NoCatalog()),
      deviceAuthProvider.overrideWithValue(_DeviceAuth()),
      connectionPlatformProvider.overrideWithValue(NoConnectionPlatform()),
      httpClientProvider.overrideWithValue(MockClient(
        (_) async => http.Response('{"tag_name":"v1.4.7"}', 200),
      )),
      sessionControllerProvider.overrideWith(
        (ref) => UiGallerySessionController(
          ref.read(vaultControllerProvider.notifier),
          ref,
          sessions,
        ),
      ),
    ]);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    });
    await container.read(vaultControllerProvider.notifier).ready();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const ShunApp(),
    ));
    await _waitForLocalFiles(tester, paths);
    await _frames(tester);
    final host = tester.widget<ShunUiHost>(find.byType(ShunUiHost));
    final rootKey = host.navigatorKey;
    final navigator = rootKey.currentState;
    final shell = tester.state(find.byType(HomeShell));
    final terminalScreen = tester.state(
      find.byType(TerminalScreen, skipOffstage: false),
    );
    final bar = find.byKey(const ValueKey('home-navigation-bar'));
    expect(tester.widget<NavigationBar>(bar).destinations, hasLength(5));
    expect(find.byType(WidgetsApp), findsOneWidget);
    expect(find.byType(Navigator), findsOneWidget);
    await tester.tap(find.descendant(of: bar, matching: find.text('终端')).last);
    await _frames(tester);
    final controller = container.read(sessionControllerProvider.notifier);
    controller.activate(1);
    await _frames(tester);
    final active = sessions.sessions[1].terminal as GhosttyTerminalAdapter;
    final view = find.byType(GhosttyTerminalView, skipOffstage: false);
    final before = tester.state(view);
    expect(tester.widget<GhosttyTerminalView>(view).adapter, same(active));
    expect(active.allText(), contains('Application log'));

    for (final index in [2, 3, 4, 0, 1]) {
      final destination =
          tester.widget<NavigationBar>(bar).destinations[index]
              as NavigationDestination;
      await tester.tap(
        find.descendant(of: bar, matching: find.text(destination.label)).last,
      );
      await _frames(tester);
      expect(container.read(homeTabProvider), index);
      expect(tester.state(find.byType(HomeShell)), same(shell));
      expect(
        tester.state(find.byType(TerminalScreen, skipOffstage: false)),
        same(terminalScreen),
      );
      if (index == 4) active.feed(utf8.encode('background-tab-output\r\n'));
    }
    expect(tester.state(view), same(before));
    expect(active.allText(), contains('background-tab-output'));
    await container.read(settingsControllerProvider.notifier).update(
          container.read(settingsControllerProvider).copyWith(themeMode: 'dark'),
        );
    await _frames(tester);
    expect(tester.widget<ShunUiHost>(find.byType(ShunUiHost)).navigatorKey,
        same(rootKey));
    expect(rootKey.currentState, same(navigator));
    expect(tester.state(view), same(before));

    final upperRoute = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('r82-upper-page')),
    );
    var upperCompleted = false;
    unawaited(upperRoute.completed.then<void>((_) => upperCompleted = true));
    unawaited(rootKey.currentState!.push<void>(upperRoute));
    await tester.pump();
    await tester.pump(upperRoute.transitionDuration);
    await tester.pump();
    expect(upperRoute.isCurrent, isTrue);
    expect(container.read(appLockControllerProvider).obscured, isFalse);
    final reverseDuration = upperRoute.reverseTransitionDuration;
    expect(await tester.binding.handlePopRoute(), isTrue);
    expect(upperRoute.isCurrent, isFalse, reason: '系统返回已交给原根导航器');
    await tester.pump();
    await tester.pump(reverseDuration);
    // Flutter's interpolation finishes at time > duration, not at equality.
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump();
    expect(upperCompleted, isTrue);
    expect(find.text('r82-upper-page', skipOffstage: false), findsNothing);
    expect(tester.state(view), same(before));
    active.input.setModifiers({'ctrl'});
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    expect(active.input.modifiers, isEmpty);
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await _frames(tester);
    expect(rootKey.currentState, same(navigator));
    expect(container.read(sessionControllerProvider).sessions, hasLength(2));
    expect(active.isDisposed, isFalse);
    expect(tester.takeException(), isNull);
  });
}

final _lightTheme = ThemeData(
  colorScheme: ColorScheme.fromSeed(
    seedColor: Colors.teal,
    brightness: Brightness.light,
  ),
);
final _darkTheme = ThemeData(
  colorScheme: ColorScheme.fromSeed(
    seedColor: Colors.teal,
    brightness: Brightness.dark,
  ),
);

class _HostFixture {
  _HostFixture();

  final navigatorKey = GlobalKey<NavigatorState>();
  final captureKey = GlobalKey();
  final mode = ValueNotifier(ThemeMode.light);
  final locale = ValueNotifier(const Locale('zh', 'CN'));
  final auth = _DeviceAuth();
  late final AppLockController lock;
  late final ProviderContainer container;

  static Future<_HostFixture> open(
    WidgetTester tester, {
    required Widget home,
  }) async {
    final fixture = _HostFixture();
    fixture.lock = AppLockController(
      auth: fixture.auth,
      settings: const AppSettings(),
      hasConnectedTerminal: () => false,
    );
    fixture.container = ProviderContainer(overrides: [
      appLockControllerProvider.overrideWith((ref) => fixture.lock),
    ]);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.container.dispose();
      fixture.mode.dispose();
      fixture.locale.dispose();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: fixture.container,
        child: RepaintBoundary(
          key: fixture.captureKey,
          child: ValueListenableBuilder<ThemeMode>(
            valueListenable: fixture.mode,
            builder: (_, mode, __) => ValueListenableBuilder<Locale>(
              valueListenable: fixture.locale,
              builder: (_, locale, __) {
                return ShunUiHost(
                  navigatorKey: fixture.navigatorKey,
                  theme: _lightTheme,
                  darkTheme: _darkTheme,
                  themeMode: mode,
                  locale: locale,
                  home: home,
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return fixture;
  }
}

class _DeviceAuth implements DeviceAuth {
  var authenticateCalls = 0;
  DeviceAuthOutcome next =
      const DeviceAuthOutcome(DeviceAuthResult.canceled);

  @override
  set onActivityPaused(void Function(bool ownActivity)? callback) {}

  @override
  Future<bool> isDeviceSecure() async => true;

  @override
  Future<DeviceAuthOutcome> authenticate({
    required String title,
    String? description,
    required bool pinOnly,
    required bool allowWeak,
  }) async {
    authenticateCalls++;
    return next;
  }

  @override
  Future<void> setProtectRecents(bool enabled) async {}
}

Future<void> _frames(WidgetTester tester) async {
  // 终端光标和提示有自己的时钟，不用 pumpAndSettle 等它们永久停下。
  for (var frame = 0; frame < 5; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void _allowIdleTasks(WidgetTester tester) {
  final strategy = tester.binding.schedulingStrategy;
  tester.binding.schedulingStrategy =
      ({required int priority, required SchedulerBinding scheduler}) => true;
  addTearDown(() => tester.binding.schedulingStrategy = strategy);
}

Future<void> _expectCoverPixels(
  WidgetTester tester,
  _HostFixture fixture,
  Color expected,
) async {
  final boundary =
      fixture.captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = (await tester.runAsync(() => boundary.toImage(pixelRatio: 1)))!;
  try {
    final bytes = (await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    // 顶部 Banner、底部 SnackBar 和页面侧边都必须是当前锁罩的实色，
    // 不仅检查 Widget 层级；避开中央锁图标和解锁按钮。
    final points = [
      Offset(image.width / 2, 24),
      Offset(image.width / 2, image.height - 24),
      Offset(16, image.height / 2),
    ];
    for (final point in points) {
      final offset = (point.dy.floor() * image.width + point.dx.floor()) * 4;
      expect(
        [for (var channel = 0; channel < 4; channel++) bytes.getUint8(offset + channel)],
        [
          (expected.r * 255).round(),
          (expected.g * 255).round(),
          (expected.b * 255).round(),
          255,
        ],
        reason: '锁罩必须覆盖提示和旧主题：$point',
      );
    }
  } finally {
    image.dispose();
  }
}

class _PanelProbe extends StatefulWidget {
  const _PanelProbe();

  @override
  State<_PanelProbe> createState() => _PanelProbeState();
}

class _PanelProbeState extends State<_PanelProbe> {
  var _open = false;
  var backgroundTaps = 0;

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_open,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && _open) setState(() => _open = false);
        },
        child: Scaffold(
          body: Stack(
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      key: const ValueKey('panel-background'),
                      onPressed: () => backgroundTaps++,
                      child: const Text('背景操作'),
                    ),
                    p.FilledButton(
                      key: const ValueKey('open-panel'),
                      onPressed: () => setState(() => _open = true),
                      child: const Text('打开面板'),
                    ),
                  ],
                ),
              ),
              if (_open)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: SizedBox(
                    width: double.infinity,
                    height: 200,
                    child: p.Surface(
                      key: const ValueKey('non-modal-panel'),
                      color: p.Theme.of(context).colorScheme.surfaceContainer,
                      shape: p.AppShape.top(p.AppCorner.xl),
                      child: Center(
                        child: p.TextButton(
                          onPressed: () => setState(() => _open = false),
                          child: const Text('关闭面板'),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
}

class _SecurityKeyChannel extends SecurityKeyChannel {
  _SecurityKeyChannel()
      : super(channel: const MethodChannel('test/r82-security-key'));

  final events = StreamController<SecurityKeyStage>.broadcast();
  var cancelCalls = 0;

  @override
  Stream<SecurityKeyStage> get stages => events.stream;

  @override
  Future<SecurityKeyAvailability> availability() async =>
      const SecurityKeyAvailability(nfc: true, nfcEnabled: true, usb: true);

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }
}

class _NoCatalog extends CatalogCacheRepository {
  _NoCatalog() : super(() async => Directory.systemTemp);

  @override
  Future<CatalogCache?> load(String catalogId) async => null;

  @override
  Future<List<CatalogCache>> loadAll() async => const [];
}

Future<void> _waitForLocalFiles(
  WidgetTester tester,
  UiGalleryPaths paths,
) async {
  final loader = tester.widget<FutureBuilder<MountableFileTransferService>>(
    find.byWidgetPredicate(
      (widget) => widget is FutureBuilder<MountableFileTransferService>,
      skipOffstage: false,
    ),
  );
  MountableFileTransferService? local;
  Object? error;
  StackTrace? stack;
  var completed = false;
  unawaited(loader.future!.then<void>((value) {
    local = value;
    completed = true;
  }, onError: (Object cause, StackTrace trace) {
    error = cause;
    stack = trace;
    completed = true;
  }));
  // Future 建在 FakeAsync 中：轮转真实 IO 和 pump，不在 runAsync 里死等。
  for (var attempt = 0; !completed && attempt < 100; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  expect(completed, isTrue, reason: '本机文件服务必须真实完成初始化');
  if (error != null) Error.throwWithStackTrace(error!, stack!);
  expect(local!.rootPath, '${paths.documentsPath}/shun');
  expect(paths.documentsRequests, greaterThan(0));
}

int _textInputClient(WidgetTester tester) {
  final call = tester.testTextInput.log.lastWhere(
    (call) => call.method == 'TextInput.setClient',
  );
  final client = (call.arguments as List<dynamic>).first as int;
  expect(client, greaterThan(0));
  return client;
}

Future<void> _sendTextInput(
  WidgetTester tester,
  String method,
  List<Object?> arguments,
) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.textInput.name,
    const JSONMethodCodec().encodeMethodCall(MethodCall(method, arguments)),
    (_) {},
  );
}

Future<void> _sendEditingState(
  WidgetTester tester,
  int client,
  String text,
) =>
    _sendTextInput(tester, 'TextInputClient.updateEditingState', [
      client,
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ).toJSON(),
    ]);
