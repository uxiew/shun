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
import 'package:shun/presentation/screens/settings_screen.dart';
import 'package:shun/presentation/screens/terminal_screen.dart';
import 'package:shun/presentation/terminal/ghostty_terminal_view.dart';
import 'package:shun/presentation/terminal/terminal_view.dart';
import 'package:shun/presentation/ui/material_compat.dart';
import 'package:shun/presentation/ui/prism_theme.dart';
import 'package:shun/presentation/ui/shun_ui_host.dart';
import 'package:shun/presentation/widgets/custom_background.dart';
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
    // 按入口 key 找，不按导航控件的类型找（R85 换成了 Prism 的底栏）。
    for (var index = 0; index < 5; index++) {
      expect(
          find.descendant(of: bar, matching: find.byKey(homeNavigationKey(index))),
          findsOneWidget);
    }
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
      await tester.tap(find.byKey(homeNavigationKey(index)));
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

  // R83 / UIM04：旧版本存下的主题 ID、模式、自定义背景、终端字号和输入方式照样生效；
  // 逐项改设置时主题当帧就换好，HomeShell、终端页、挂着的终端视图和大输入框都是原来那一个，
  // 草稿和焦点还在，前台和后台终端回答的背景色都等于当前主题。
  testWidgets('R83 旧设置生效；切模式、主题、背景、字号不重建页面和终端，草稿焦点保留、终端配色同步',
      (tester) async {
    _allowIdleTasks(tester);
    tester.view.physicalSize = const Size(824, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    late final String backgroundFile;
    final app = await _openShunApp(tester, (paths) async {
      // 旧版本存下的背景：受管目录里的文件，设置里是可移植引用（格式不变，不迁移）。
      final directory = Directory('${paths.supportPath}/custom-backgrounds');
      await directory.create(recursive: true);
      final file = File('${directory.path}/background-r83.png');
      await file.writeAsBytes(base64Decode(_onePixelPng));
      backgroundFile = file.absolute.path;
      return const AppSettings(
        themeMode: 'light',
        uiThemeId: 'catppuccin',
        terminalFontSize: 18,
        terminalInputMode: terminalInputCompose,
        customBackgroundEnabled: true,
        customBackgroundPath: 'shun-background:background-r83.png',
        customBackgroundOpacity: 0.65,
        customBackgroundAlignment: 'bottomRight',
        customBackgroundScope: 'global',
        language: 'zh-CN',
        autoSyncEnabled: false,
      );
    });
    final container = app.container;
    expect(container.read(settingsControllerProvider).customBackgroundPath,
        backgroundFile);

    // 旧设置生效。
    final catppuccin = ShunUiTheme.resolve(Brightness.light, 'catppuccin');
    final shell = find.byType(HomeShell);
    expect(Theme.of(tester.element(shell)).colorScheme,
        materialThemeFor(catppuccin).colorScheme);
    expect(p.Theme.of(tester.element(shell)), same(catppuccin.prismTheme));
    final background = find.byType(CustomBackgroundImage);
    expect(background, findsOneWidget);
    final image = tester.widget<Image>(
      find.descendant(of: background, matching: find.byType(Image)),
    );
    expect((image.image as FileImage).file.path, backgroundFile);
    expect(image.alignment, Alignment.bottomRight);
    expect(
      tester
          .widget<Opacity>(
            find.descendant(of: background, matching: find.byType(Opacity)),
          )
          .opacity,
      0.65,
    );

    final bar = find.byKey(const ValueKey('home-navigation-bar'));
    await tester.tap(find.descendant(of: bar, matching: find.text('终端')).last);
    await _frames(tester);
    container.read(sessionControllerProvider.notifier).activate(1);
    await _frames(tester);
    final shown = app.sessions.sessions[1].terminal as GhosttyTerminalAdapter;
    final hidden = app.sessions.sessions[0].terminal as GhosttyTerminalAdapter;
    final view = find.byType(GhosttyTerminalView);
    expect(tester.widget<GhosttyTerminalView>(view).adapter, same(shown));
    expect(tester.widget<GhosttyTerminalView>(view).options.fontSize, 18);
    expect(
      tester.widget<GhosttyTerminalView>(view).options.transparentBackground,
      isTrue,
    );
    expect(hidden.hasActiveView, isFalse);

    // 上次用的是大输入框：面板开着，在里面写一段还没发的草稿。
    final editor = find.byKey(const ValueKey('terminal-compose-editor'));
    expect(editor, findsOneWidget);
    await tester.enterText(editor, 'r83-draft');
    await _frames(tester);
    final focus = FocusManager.instance.primaryFocus!;
    expect(focus.hasFocus, isTrue);
    final editable = find.descendant(of: editor, matching: find.byType(EditableText));
    final before = (
      shell: tester.state(shell),
      screen: tester.state(find.byType(TerminalScreen, skipOffstage: false)),
      view: tester.state(view),
      engine: tester.state(find.byType(flterm.TerminalView)),
      editable: tester.state(editable),
    );
    final rootKey = tester.widget<ShunUiHost>(find.byType(ShunUiHost)).navigatorKey;
    final navigator = rootKey.currentState;

    final changes = <(String, AppSettings Function(AppSettings), Brightness?)>[
      ('深色', (s) => s.copyWith(themeMode: 'dark'), null),
      ('认不出的主题 ID', (s) => s.copyWith(uiThemeId: 'no-such-theme'), null),
      ('跟随系统，系统浅色', (s) => s.copyWith(themeMode: 'system'), Brightness.light),
      ('跟随系统，系统换深色', (s) => s, Brightness.dark),
      ('换回 tokyo-night', (s) => s.copyWith(uiThemeId: 'tokyo-night'), null),
      ('关掉自定义背景', (s) => s.copyWith(customBackgroundEnabled: false), null),
      ('重新打开背景', (s) => s.copyWith(customBackgroundEnabled: true), null),
      ('终端字号 12', (s) => s.copyWith(terminalFontSize: 12), null),
      ('浅色', (s) => s.copyWith(themeMode: 'light'), null),
    ];
    for (final (label, change, system) in changes) {
      if (system != null) {
        tester.platformDispatcher.platformBrightnessTestValue = system;
      }
      final next = change(container.read(settingsControllerProvider));
      // 存盘要把背景的绝对路径换回可移植引用，是真文件 IO：在真实时间里等它存完，
      // 假时钟里 await 会一直等下去。内存里的设置在调用时就已经换好。
      await tester.runAsync(
        () => container.read(settingsControllerProvider.notifier).update(next),
      );
      final settings = container.read(settingsControllerProvider);
      final dark = switch (settings.themeMode) {
        'light' => false,
        'system' => tester.platformDispatcher.platformBrightness ==
            Brightness.dark,
        _ => true,
      };
      final expected = ShunUiTheme.resolve(
        dark ? Brightness.dark : Brightness.light,
        settings.uiThemeId,
      );
      final colors = materialThemeFor(expected).colorScheme;
      // 只过一帧就是新主题：没有插值，也没有旧主题截图。
      await tester.pump();
      final context = tester.element(view);
      expect(Theme.of(context).colorScheme, colors, reason: label);
      expect(p.Theme.of(context), same(expected.prismTheme), reason: label);
      await _frames(tester);
      expect(find.byType(p.ThemeCrossFade), findsNothing, reason: label);
      // 按钮自己里面有 AnimatedTheme（Flutter 的 ButtonStyleButton），那是按钮局部的；
      // 要防的是套在整页外面、让终端跟着插值的那种。
      expect(
        find.ancestor(of: shell, matching: find.byType(AnimatedTheme)),
        findsNothing,
        reason: label,
      );
      // 终端正文上不加玻璃、模糊。
      expect(find.byType(p.LiquidGlass), findsNothing, reason: label);
      expect(find.byType(BackdropFilter), findsNothing, reason: label);
      expect(rootKey.currentState, same(navigator), reason: label);
      expect(tester.state(shell), same(before.shell), reason: label);
      expect(
        tester.state(find.byType(TerminalScreen, skipOffstage: false)),
        same(before.screen),
        reason: label,
      );
      expect(tester.state(view), same(before.view), reason: label);
      expect(tester.state(find.byType(flterm.TerminalView)), same(before.engine),
          reason: label);
      expect(tester.state(editable), same(before.editable), reason: label);
      expect(tester.widget<TextField>(editor).controller!.text, 'r83-draft',
          reason: label);
      expect(FocusManager.instance.primaryFocus, same(focus), reason: label);
      expect(focus.hasFocus, isTrue, reason: label);
      expect(_askBackground(shown), _answer(colors.surface), reason: label);
      expect(_askBackground(hidden), _answer(colors.surface), reason: label);
      final options = tester.widget<GhosttyTerminalView>(view).options;
      expect(options.fontSize, settings.terminalFontSize, reason: label);
      expect(options.transparentBackground, settings.customBackgroundEnabled,
          reason: label);
      expect(background.evaluate().isNotEmpty, settings.customBackgroundEnabled,
          reason: label);
      // 自定义背景只把页面这一层让给图片，卡片仍是不透明的卡片色。
      final page = Theme.of(context);
      expect(
        page.scaffoldBackgroundColor,
        settings.customBackgroundEnabled
            ? Colors.transparent
            : expected.prismTheme.scaffoldBackgroundColor,
        reason: label,
      );
      expect(page.cardTheme.color, expected.preset.card, reason: label);
      expect(page.cardTheme.color!.a, 1, reason: label);
    }
    expect(container.read(sessionControllerProvider).sessions, hasLength(2));
    expect(shown.isDisposed, isFalse);
    expect(hidden.isDisposed, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('R83 减少动画：Prism 与 Material 都看到，展开一帧到位，切主题一帧完成', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final homeKey = GlobalKey();
    final fixture = await _HostFixture.open(
      tester,
      home: Scaffold(
        key: homeKey,
        body: ListView(
          children: const [
            ExpansionTile(
              key: ValueKey('r83-expansion'),
              title: Text('r83-expand'),
              children: [Text('r83-inside')],
            ),
          ],
        ),
      ),
    );
    var context = homeKey.currentContext!;
    expect(MediaQuery.disableAnimationsOf(context), isTrue);
    expect(context.disableAnimations, isTrue, reason: 'Prism 的判断');
    expect(context.motionDuration(p.commonDuration), Duration.zero);
    expect(Theme.of(context).expansionTileTheme.expansionAnimationStyle,
        AnimationStyle.noAnimation);
    expect(Theme.of(context).colorScheme, _lightTheme.colorScheme);

    await tester.tap(find.text('r83-expand'));
    await tester.pump();
    // 第一帧就是展开后的样子：再等到动画（含按压水波）全部结束，位置和大小都不再变。
    final firstFrame = tester.getRect(find.text('r83-inside'));
    expect(firstFrame.height, greaterThan(0));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('r83-inside')), firstFrame,
        reason: '展开直接到位');

    fixture.mode.value = ThemeMode.dark;
    await tester.pump();
    context = homeKey.currentContext!;
    expect(Theme.of(context).colorScheme, _darkTheme.colorScheme);
    expect(p.Theme.of(context), same(_darkUi.prismTheme));
    expect(
      find.ancestor(of: find.byKey(homeKey), matching: find.byType(AnimatedTheme)),
      findsNothing,
    );
    expect(find.byType(p.ThemeCrossFade), findsNothing);

    // 系统里关掉「移除动画」：展开回到 Prism 的公开时长。
    tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
    await tester.pump();
    context = homeKey.currentContext!;
    expect(context.motionDuration(p.commonDuration), p.commonDuration);
    expect(
      Theme.of(context).expansionTileTheme.expansionAnimationStyle?.duration,
      p.UnfoldEntryTransition.duration,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('R83 宿主和主题不替换系统的非线性字号', (tester) async {
    const scaler = _NonlinearTextScaler();
    final homeKey = GlobalKey();
    final fixture = await _HostFixture.open(
      tester,
      textScaler: scaler,
      home: Scaffold(
        key: homeKey,
        body: const Text('r83-body'),
      ),
    );
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      fixture.mode.value = mode;
      await tester.pump();
      final context = homeKey.currentContext!;
      expect(MediaQuery.textScalerOf(context), same(scaler));
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.text('r83-body'),
          matching: find.byType(RichText),
        ),
      );
      expect(paragraph.textScaler, same(scaler));
      // 正文是 Prism 的 15；非线性放大后不是线性倍数。
      expect(paragraph.text.style?.fontSize, 15);
      expect(scaler.scale(15), isNot(closeTo(15 * scaler.scale(30) / 30, 0.01)));
    }
    expect(tester.takeException(), isNull);
  });

  // R85 / UIM06：底栏换成 Prism 的 NavigationBar 以后，五入口、切页留存、返回顺序、锁定、
  // 全屏/画中画和各种屏幕尺寸照旧。入口按 key、读屏语义和真实点击找，不按控件类型。
  group('R85 主导航外壳', () {
    const names = ['连接', '终端', '文件', '片段', '设置'];
    final bar = find.byKey(const ValueKey('home-navigation-bar'));
    Finder entry(int index) => find.byKey(homeNavigationKey(index));
    final view = find.byType(GhosttyTerminalView, skipOffstage: false);
    final engine = find.byType(flterm.TerminalView, skipOffstage: false);

    void size(WidgetTester tester, Size logical, {double textScale = 1}) {
      tester.view.physicalSize = logical * 2;
      tester.view.devicePixelRatio = 2;
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }

    Future<({ProviderContainer container, SessionState sessions})> open(
      WidgetTester tester, {
      String inputMode = terminalInputSystem,
    }) =>
        _openShunApp(
          tester,
          (_) async => AppSettings(
            themeMode: 'light',
            language: 'zh-CN',
            autoSyncEnabled: false,
            terminalInputMode: inputMode,
          ),
        );

    Future<void> go(
        WidgetTester tester, ProviderContainer container, int index) async {
      await tester.tap(entry(index));
      await _frames(tester);
      expect(container.read(homeTabProvider), index);
    }

    testWidgets('五个入口：读屏是五个按钮、标出选中；底栏不透明，只有这五页', (tester) async {
      _allowIdleTasks(tester);
      size(tester, const Size(412, 892));
      final handle = tester.ensureSemantics();
      final app = await open(tester);
      final container = app.container;
      expect(
        find.descendant(
          of: bar,
          matching: find.byWidgetPredicate((widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith('home-nav-')),
        ),
        findsNWidgets(5),
      );
      final stack = tester.widget<IndexedStack>(find
          .descendant(
              of: find.byType(HomeShell), matching: find.byType(IndexedStack))
          .first);
      expect(stack.children, hasLength(5), reason: '没有第六页（管理页）');

      for (var selected = 0; selected < 5; selected++) {
        await go(tester, container, selected);
        for (var index = 0; index < 5; index++) {
          final node = tester.getSemantics(entry(index));
          expect(node.label, names[index]);
          expect(node.flagsCollection.isButton, isTrue);
          expect(
            node.flagsCollection.isSelected,
            index == selected ? ui.Tristate.isTrue : ui.Tristate.isFalse,
            reason: '选中第 $selected 页时第 $index 个入口',
          );
          final hit = tester.getSize(entry(index));
          expect(hit.width, greaterThanOrEqualTo(24));
        }
        // 每个入口整格可点：宽是整行的五分之一，高 80。
        final cell = tester.getRect(find
            .ancestor(of: entry(selected), matching: find.byType(p.PressRegion))
            .first);
        expect(cell.height, greaterThanOrEqualTo(48));
        expect(cell.width, greaterThanOrEqualTo(48));
      }

      final colors = _lightUi.colorScheme;
      final surface = tester.widget<p.Surface>(
          find.descendant(of: bar, matching: find.byType(p.Surface)).first);
      expect(surface.color, p.SurfaceLevel.floatingOf(colors).colorOf(colors));
      expect(surface.color!.a, 1.0, reason: '底栏不透明，背景透不过来');
      expect(tester.takeException(), isNull);
      handle.dispose();
    });

    testWidgets('切页保留滚动、草稿、标签和会话；不新建终端视图', (tester) async {
      _allowIdleTasks(tester);
      size(tester, const Size(412, 892));
      final app = await open(tester, inputMode: terminalInputCompose);
      final container = app.container;
      final shell = tester.state(find.byType(HomeShell));

      // 设置页往下滚一段。
      await go(tester, container, 4);
      final settingsScroll = find
          .descendant(
              of: find.byType(SettingsScreen),
              matching: find.byType(Scrollable))
          .first;
      await tester.drag(settingsScroll, const Offset(0, -400));
      await _frames(tester);
      final scrolled =
          tester.state<ScrollableState>(settingsScroll).position.pixels;
      expect(scrolled, greaterThan(100));

      // 终端页：第二个标签，大输入框里写一段没发的草稿。
      await go(tester, container, 1);
      container.read(sessionControllerProvider.notifier).activate(1);
      await _frames(tester);
      final editor = find.byKey(const ValueKey('terminal-compose-editor'));
      await tester.enterText(editor, 'r85-draft');
      await _frames(tester);
      final viewState = tester.state(view);
      final engineState = tester.state(engine);
      final terminalScreen =
          tester.state(find.byType(TerminalScreen, skipOffstage: false));

      for (final index in [0, 2, 3, 4, 1, 4, 0, 1]) {
        await go(tester, container, index);
        expect(tester.state(find.byType(HomeShell)), same(shell));
        expect(tester.state(find.byType(TerminalScreen, skipOffstage: false)),
            same(terminalScreen));
        expect(view, findsOneWidget, reason: '切页不复制终端视图');
        expect(tester.state(view), same(viewState));
        expect(tester.state(engine), same(engineState));
        expect(
            container.read(sessionControllerProvider).sessions, hasLength(2));
        expect(container.read(sessionControllerProvider).activeIndex, 1);
      }
      expect(
        tester
            .widget<EditableText>(find.descendant(
                of: editor, matching: find.byType(EditableText)))
            .controller
            .text,
        'r85-draft',
      );
      await go(tester, container, 4);
      expect(tester.state<ScrollableState>(settingsScroll).position.pixels,
          scrolled);
      expect(tester.takeException(), isNull);
    });

    testWidgets('持续输出时切主 tab、push/pop 二级页：视图、输出、焦点连续', (tester) async {
      _allowIdleTasks(tester);
      size(tester, const Size(412, 892));
      final app = await open(tester);
      final container = app.container;
      final rootKey =
          tester.widget<ShunUiHost>(find.byType(ShunUiHost)).navigatorKey;
      await go(tester, container, 1);
      container.read(sessionControllerProvider.notifier).activate(1);
      await _frames(tester);
      final active =
          app.sessions.sessions[1].terminal as GhosttyTerminalAdapter;
      final viewState = tester.state(view);
      final engineState = tester.state(engine);
      final input = tester.widget<flterm.TerminalView>(engine).focusNode!;

      var line = 0;
      final output = Timer.periodic(const Duration(milliseconds: 20), (_) {
        line++;
        active.feed(utf8.encode('r85-stream-$line\r\n'));
      });
      addTearDown(output.cancel);

      for (final index in [0, 2, 3, 4, 1]) {
        final before = line;
        await go(tester, container, index);
        expect(line, greaterThan(before), reason: '切到第 $index 页时输出没停');
        expect(tester.state(view), same(viewState));
        expect(tester.state(engine), same(engineState));
      }
      expect(active.allText(), contains('r85-stream-$line'));
      // 终端拿着焦点时点底栏切走：焦点跟着页面隐藏而离开，切回来也不自己回到终端（不自动弹键盘）。
      // 这是原有行为：11-14 把底栏临时换回旧的 Material NavigationBar 跑同一段，结果相同。
      input.requestFocus();
      await _frames(tester);
      expect(input.hasFocus, isTrue);
      for (final index in [3, 1]) {
        await go(tester, container, index);
        expect(input.hasFocus, isFalse, reason: '切到第 $index 页');
      }
      expect(tester.state(engine), same(engineState));

      // 二级页：终端先拿着焦点，push 后交给二级页，pop 回来还给终端。
      input.requestFocus();
      await _frames(tester);
      expect(input.hasFocus, isTrue);

      final route = p.CardPageRoute<void>(
        settings: const RouteSettings(name: '/r85-secondary'),
        builder: (_) => const Scaffold(body: TextField(autofocus: true)),
      );
      unawaited(rootKey.currentState!.push<void>(route));
      await _frames(tester);
      expect(route.isCurrent, isTrue);
      expect(input.hasFocus, isFalse, reason: '二级页拿走输入焦点');
      final covered = line;
      await _frames(tester);
      expect(line, greaterThan(covered), reason: '被盖住时终端照收输出');
      expect(tester.state(view), same(viewState));
      expect(tester.state(engine), same(engineState));

      expect(await tester.binding.handlePopRoute(), isTrue);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(route.isActive, isFalse);
      expect(tester.state(view), same(viewState));
      expect(tester.state(engine), same(engineState));
      expect(input.hasFocus, isTrue, reason: '回来后焦点还给终端');
      expect(active.allText(), contains('r85-stream-$line'));
      expect(container.read(homeTabProvider), 1);
      output.cancel();
      expect(tester.takeException(), isNull);
    });

    testWidgets('返回顺序：总览 > 全屏 > 根；画中画返回先退画中画；锁着时返回不弹底下的页', (tester) async {
      _allowIdleTasks(tester);
      size(tester, const Size(412, 892));
      final app = await open(tester);
      final container = app.container;
      final rootKey =
          tester.widget<ShunUiHost>(find.byType(ShunUiHost)).navigatorKey;
      final messenger = tester.binding.defaultBinaryMessenger;
      final pip = <String>[];
      messenger.setMockMethodCallHandler(
          const MethodChannel('top.xdwa.shun/picture_in_picture'),
          (call) async {
        pip.add(call.method);
        return null;
      });
      final system = <String>[];
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        system.add(call.method);
        return null;
      });
      addTearDown(() =>
          messenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final overview = find.byKey(const ValueKey('session-overview-scrim'));

      await go(tester, container, 1);
      container.read(terminalFullscreenProvider.notifier).state = true;
      container.read(sessionOverviewRequestProvider.notifier).state++;
      await _frames(tester);
      expect(bar, findsNothing, reason: '全屏时没有底栏');
      expect(overview, findsOneWidget);

      expect(await tester.binding.handlePopRoute(), isTrue);
      await _frames(tester);
      expect(overview, findsNothing, reason: '先关总览');
      expect(container.read(terminalFullscreenProvider), isTrue);

      expect(await tester.binding.handlePopRoute(), isTrue);
      await _frames(tester);
      expect(container.read(terminalFullscreenProvider), isFalse,
          reason: '再退全屏');
      expect(bar, findsOneWidget, reason: '底栏回来');
      expect(container.read(homeTabProvider), 1);

      container.read(terminalPictureInPictureProvider.notifier).state = true;
      await _frames(tester);
      expect(bar, findsNothing, reason: '画中画时没有底栏');
      expect(await tester.binding.handlePopRoute(), isTrue);
      await _frames(tester);
      expect(container.read(terminalPictureInPictureProvider), isFalse);
      expect(pip, contains('stop'));
      expect(bar, findsOneWidget);

      // 根上没有可退的：交给系统（退到桌面），HomeShell 不被弹掉。
      system.clear();
      expect(await tester.binding.handlePopRoute(), isFalse);
      expect(find.byType(HomeShell), findsOneWidget);

      // 锁着时：返回退到桌面，盖子底下的二级页不弹。
      final route = MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('r85-under-lock')),
      );
      unawaited(rootKey.currentState!.push<void>(route));
      await _frames(tester);
      final lock = container.read(appLockControllerProvider.notifier);
      lock.settingsChanged(
        const AppSettings(appLockEnabled: true, appLockGraceSeconds: 0),
      );
      lock.activityPaused(false);
      await _frames(tester);
      expect(container.read(appLockControllerProvider).obscured, isTrue);
      system.clear();
      expect(await tester.binding.handlePopRoute(), isTrue);
      await _frames(tester);
      expect(system, contains('SystemNavigator.pop'));
      expect(route.isCurrent, isTrue, reason: '锁着时不弹底下的页');
      expect(tester.takeException(), isNull);
    });

    testWidgets('全局自定义背景：底栏仍不透明，背景只铺到底栏上方（R83 记下的字偏淡）', (tester) async {
      _allowIdleTasks(tester);
      size(tester, const Size(412, 892));
      final app = await _openShunApp(tester, (paths) async {
        final directory = Directory('${paths.supportPath}/custom-backgrounds');
        await directory.create(recursive: true);
        await File('${directory.path}/background-r85.png')
            .writeAsBytes(base64Decode(_onePixelPng));
        return const AppSettings(
          themeMode: 'light',
          language: 'zh-CN',
          autoSyncEnabled: false,
          customBackgroundEnabled: true,
          customBackgroundPath: 'shun-background:background-r85.png',
          customBackgroundScope: 'global',
        );
      });
      final container = app.container;
      for (final index in [0, 1, 4]) {
        await go(tester, container, index);
        final background = find.byType(CustomBackgroundImage);
        expect(background, findsOneWidget, reason: '第 $index 页有全局背景');
        final barRect = tester.getRect(bar);
        expect(
            tester.getRect(background).bottom, lessThanOrEqualTo(barRect.top),
            reason: '背景不伸到底栏底下');
        final surface = tester.widget<p.Surface>(
            find.descendant(of: bar, matching: find.byType(p.Surface)).first);
        expect(surface.color!.a, 1.0);
      }
      expect(tester.takeException(), isNull);
    });

    for (final (label, logical, textScale) in const [
      ('窄屏 320×640', Size(320, 640), 1.0),
      ('窄屏大字 320×640 ×2', Size(320, 640), 2.0),
      ('常见 412×892', Size(412, 892), 1.0),
      ('横屏 892×412', Size(892, 412), 1.0),
      ('平板 1280×800', Size(1280, 800), 1.0),
    ]) {
      testWidgets('布局：$label 五个入口都点得到，底栏贴底、不溢出', (tester) async {
        _allowIdleTasks(tester);
        size(tester, logical, textScale: textScale);
        final app = await open(tester);
        final container = app.container;
        final rect = tester.getRect(bar);
        expect(rect.bottom, logical.height);
        expect(rect.width, logical.width);
        for (final index in [1, 2, 3, 4, 0]) {
          final center = tester.getCenter(entry(index));
          expect(rect.contains(center), isTrue);
          await go(tester, container, index);
        }
        // 终端页的终端区在底栏上面，不被盖住。
        await go(tester, container, 1);
        final area =
            tester.getRect(find.byKey(const ValueKey('terminal-area')));
        expect(area.bottom, lessThanOrEqualTo(rect.top));
        expect(area.height, greaterThan(0));
        expect(tester.takeException(), isNull);
      });
    }
  });
}

// R83 起宿主只接受语义主题；用默认 uiThemeId 的真实浅/深预设，断言照旧比对 Material 表示。
final _lightUi = ShunUiTheme.resolve(Brightness.light, 'tokyo-night');
final _darkUi = ShunUiTheme.resolve(Brightness.dark, 'tokyo-night');
final _lightTheme = materialThemeFor(_lightUi);
final _darkTheme = materialThemeFor(_darkUi);

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
    TextScaler? textScaler,
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
                final host = ShunUiHost(
                  navigatorKey: fixture.navigatorKey,
                  theme: _lightUi,
                  darkTheme: _darkUi,
                  themeMode: mode,
                  locale: locale,
                  home: home,
                );
                if (textScaler == null) return host;
                // WidgetsApp 的 MediaQuery.fromView 从上层继承平台字号，和系统给的一样。
                return Builder(
                  builder: (context) => MediaQuery(
                    data: MediaQueryData.fromView(View.of(context))
                        .copyWith(textScaler: textScaler),
                    child: host,
                  ),
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

/// R83 的真实 ShunApp：和上面 R82 的五入口测试同一套隔离夹具（内存存储、临时目录、
/// 两个真 Ghostty 标签），设置由调用方给：[settings] 在真实 IO 里跑，可以先写文件。
Future<({ProviderContainer container, SessionState sessions})> _openShunApp(
  WidgetTester tester,
  Future<AppSettings> Function(UiGalleryPaths paths) settings,
) async {
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
  final initial = (await tester.runAsync(() => settings(paths)))!;
  await repository.saveSettings(initial);
  await repository.saveVault(
    VaultData.empty().copyWith(hosts: uiGalleryHosts),
  );
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
  // 设置异步读入（背景路径要解析），读完之前是默认值。
  for (var attempt = 0;
      container.read(settingsControllerProvider).uiThemeId !=
              initial.uiThemeId &&
          attempt < 100;
      attempt++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
  expect(container.read(settingsControllerProvider).uiThemeId,
      initial.uiThemeId);
  await _frames(tester);
  return (container: container, sessions: sessions);
}

/// 远端问背景色（OSC 11）时终端的回答。
String _askBackground(GhosttyTerminalAdapter terminal) {
  final sent = <String>[];
  final binding = terminal.bind((bytes) => sent.add(latin1.decode(bytes)));
  terminal.feed(utf8.encode('\x1b]11;?\x07'));
  binding.release();
  return sent.join();
}

String _answer(Color color) {
  String channel(double value) {
    final hex = (value * 255).round().toRadixString(16).padLeft(2, '0');
    return '$hex$hex';
  }

  final rgb = [color.r, color.g, color.b].map(channel).join('/');
  return '\x1b]11;rgb:$rgb\x07';
}

/// 1×1 PNG，只用来让背景路径指向一个真实文件。
const _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

/// 像 Android 14 起的系统字号：小字放大得多、大字放大得少。只用来确认宿主不把它换成线性倍数。
class _NonlinearTextScaler extends TextScaler {
  const _NonlinearTextScaler();

  @override
  double scale(double fontSize) => fontSize * (fontSize < 20 ? 2.0 : 1.5);

  @override
  double get textScaleFactor => 2.0;

  @override
  TextScaler clamp({double minScaleFactor = 0, double maxScaleFactor = double.infinity}) =>
      this;
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
