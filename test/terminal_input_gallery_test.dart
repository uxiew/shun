import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/terminal_compose.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/settings.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';
import 'package:shun/presentation/ui/components.dart';
import 'package:shun/presentation/ui/prism_theme.dart';
import 'package:shun/presentation/ui/shun_ui_host.dart';
import 'package:shun/presentation/widgets/terminal_input_panel.dart';
import 'package:shun/presentation/widgets/terminal_key_button.dart';
import 'package:shun/presentation/widgets/terminal_key_feel_tiles.dart';
import 'package:shun/presentation/widgets/terminal_key_settings_sheet.dart';
import 'package:shun/presentation/widgets/terminal_link_sheet.dart';
import 'package:shun/presentation/widgets/terminal_paste_sheet.dart';
import 'package:shun/presentation/widgets/terminal_special_keys.dart';

import 'support/ui_gallery_fixtures.dart';

/// 终端输入这一批（R94）的出图：按键面板、快捷键栏、大输入框、粘贴预览、链接确认、快捷键设置、按键手感。
/// `test/ui_gallery_test.dart` 只有一张「按键面板」，其余几个面这里补上。只出图，不比对，平时跳过。
/// 控件直接摆在生产的 ShunUiHost 里，会话是图库的内存 fixture：没有远端连接，也不是真机截图。
///
/// `SHUN_UI_GALLERY=<绝对路径目录> flutter test --no-pub test/terminal_input_gallery_test.dart`
///
/// 字体默认借 macOS 系统目录（和 ui_gallery_test 一样）；别的系统用 `SHUN_GALLERY_FONT`、
/// `SHUN_GALLERY_MONO_FONT` 指到一份带中文的字体和一份等宽字体，找不到就跳过。
final _fontPath = Platform.environment['SHUN_GALLERY_FONT'] ??
    '/System/Library/Fonts/Supplemental/Arial Unicode.ttf';
final _monoFontPath = Platform.environment['SHUN_GALLERY_MONO_FONT'] ??
    '/System/Library/Fonts/Supplemental/Courier New.ttf';
const _shot = ValueKey('terminal-input-gallery-shot');

void main() {
  final dir = Platform.environment['SHUN_UI_GALLERY'];
  final skip = dir == null
      ? '设了 SHUN_UI_GALLERY 才跑'
      : ([_fontPath, _monoFontPath].every((path) => File(path).existsSync())
          ? null
          : '没有出图用的字体');

  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final secrets = <String, String>{};

  setUp(() {
    secrets.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async {
      final args = (call.arguments as Map?) ?? const {};
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
        case 'containsKey':
          return secrets.containsKey(key);
        case 'readAll':
          return Map<String, String>.of(secrets);
        default:
          return null;
      }
    });
    final language = ShunLocalizations.language;
    ShunLocalizations.use('zh-CN');
    addTearDown(() => ShunLocalizations.use(language));
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, null);
  });

  Future<void> loadFonts(WidgetTester tester) => tester.runAsync(() async {
        Future<void> load(String family, String path) => (FontLoader(family)
              ..addFont(File(path)
                  .readAsBytes()
                  .then((bytes) => ByteData.sublistView(bytes))))
            .load();
        await load('Roboto', _fontPath);
        await load('monospace', _monoFontPath);
        final root = Platform.environment['FLUTTER_ROOT'] ??
            '/opt/homebrew/share/flutter';
        await load(
          'MaterialIcons',
          '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        );
      });

  for (final brightness in [Brightness.dark, Brightness.light]) {
    group(brightness.name, () {
      late ActiveTerminalSession session;

      Future<void> pumpPage(
        WidgetTester tester,
        Widget Function(ActiveTerminalSession session) home, {
        double width = 412,
        double height = 892,
        AppSettings settings = const AppSettings(),
      }) async {
        await loadFonts(tester);
        final paths = (await tester.runAsync(UiGalleryPaths.create))!;
        paths.install();
        addTearDown(() => tester.runAsync(paths.dispose));
        tester.view.physicalSize = Size(width * 2, height * 2);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);

        final id = brightness == Brightness.dark ? 'midnight' : 'snow';
        final repository = await VaultRepository.open();
        await repository.saveSettings(settings.copyWith(
          themeMode: brightness.name,
          uiThemeId: id,
          language: 'zh-CN',
        ));
        await repository
            .saveVault(VaultData.empty().copyWith(hosts: uiGalleryHosts));
        final sessions = uiGallerySessions();
        session = sessions.sessions.first;
        final container = ProviderContainer(overrides: [
          vaultRepositoryProvider.overrideWithValue(repository),
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
        await tester.pumpWidget(RepaintBoundary(
          key: _shot,
          child: UncontrolledProviderScope(
            container: container,
            child: ShunUiHost(
              navigatorKey: GlobalKey<NavigatorState>(),
              theme: ShunUiTheme.resolve(Brightness.light, id),
              darkTheme: ShunUiTheme.resolve(Brightness.dark, id),
              themeMode: brightness == Brightness.dark
                  ? ThemeMode.dark
                  : ThemeMode.light,
              locale: const Locale('zh', 'CN'),
              home: home(session),
            ),
          ),
        ));
        await _settle(tester);
      }

      Future<void> save(WidgetTester tester, String name) async {
        await _settle(tester);
        expect(tester.takeException(), isNull, reason: '出图前不能有未处理异常');
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(_shot),
        );
        final suffix = brightness == Brightness.light ? '-light' : '';
        await tester.runAsync(() async {
          await Directory(dir!).create(recursive: true);
          final image = await boundary.toImage(pixelRatio: 2);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          await File('$dir/$name$suffix.png')
              .writeAsBytes(data!.buffer.asUint8List());
        });
      }

      testWidgets('快捷键栏和按键面板：常用（Ctrl 亮着）、符号、F 键', skip: skip != null,
          (tester) async {
        await pumpPage(tester, (session) => _InputStage(session: session));
        session.terminal.input.setModifiers({'ctrl'});
        await save(tester, 'terminal-input-keys-common-412x892-zh-s1');
        session.terminal.input.setModifiers(const {});
        await tester
            .tap(find.byKey(const ValueKey('terminal-key-page-symbols')));
        await save(tester, 'terminal-input-keys-symbols-412x892-zh-s1');
        await tester
            .tap(find.byKey(const ValueKey('terminal-key-page-function')));
        await save(tester, 'terminal-input-keys-function-412x892-zh-s1');
      });

      testWidgets('大输入框：空着、多行草稿带提醒', skip: skip != null, (tester) async {
        await pumpPage(
          tester,
          (session) => _InputStage(session: session, compose: true),
        );
        await save(tester, 'terminal-input-compose-empty-412x892-zh-s1');
        await tester.enterText(
          find.byKey(const ValueKey('terminal-compose-editor')),
          'cd ~/workspace\n./check --all',
        );
        await save(tester, 'terminal-input-compose-draft-412x892-zh-s1');
      });

      testWidgets('横屏：一行的快捷键栏和两行的按键面板', skip: skip != null, (tester) async {
        await pumpPage(
          tester,
          (session) => _InputStage(session: session, compact: true),
          width: 892,
          height: 412,
        );
        await save(tester, 'terminal-input-keys-892x412-zh-s1');
      });

      testWidgets('粘贴预览：多行会逐行执行、末尾换行、控制字符', skip: skip != null, (tester) async {
        await pumpPage(tester, (_) => const Scaffold());
        unawaited(showTerminalPasteSheet(
          tester.element(find.byType(Scaffold)),
          target: session,
          text: 'cd ~/workspace\n./check --all\x07\n',
        ));
        await save(tester, 'terminal-paste-sheet-412x892-zh-s1');
      });

      testWidgets('链接确认：文字和地址不一样、域名非英文；不能打开的地址', skip: skip != null,
          (tester) async {
        await pumpPage(tester, (_) => const Scaffold());
        unawaited(showTerminalLinkSheet(
          tester.element(find.byType(Scaffold)),
          shownText: 'https://github.com/login',
          address: 'https://gіthub.com/login?next=%2Fsettings',
        ));
        await save(tester, 'terminal-link-sheet-412x892-zh-s1');
        await tester.tap(find.byKey(const ValueKey('terminal-link-cancel')));
        await _settle(tester);
        unawaited(showTerminalLinkSheet(
          tester.element(find.byType(Scaffold)),
          shownText: 'file:///etc/passwd',
          address: 'file:///etc/passwd',
        ));
        await save(tester, 'terminal-link-sheet-refused-412x892-zh-s1');
      });

      testWidgets('快捷键设置：只给这台主机、模板、内置键和自定义键', skip: skip != null,
          (tester) async {
        await pumpPage(tester, (_) => const Scaffold());
        unawaited(showTerminalKeySettings(
          tester.element(find.byType(Scaffold)),
          globalOrder: [...defaultTerminalQuickKeys.take(5), 'custom-clear'],
          customKeys: const [
            TerminalCustomKey(
                id: 'custom-clear', label: '清屏', value: r'clear\n'),
          ],
          hostLabel: 'web',
        ));
        await save(tester, 'terminal-key-settings-412x892-zh-s1');
      });

      testWidgets('按键手感：设置页里的三行', skip: skip != null, (tester) async {
        await pumpPage(
          tester,
          (_) => Scaffold(
            body: SafeArea(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  ShunSection(title: '终端', children: terminalKeyFeelRows()),
                ],
              ),
            ),
          ),
          height: 420,
        );
        await save(tester, 'terminal-key-feel-412x420-zh-s1');
      });
    });
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 终端页下半截的摆法：上面一块代替终端的底，下面是快捷键栏和输入面板。
class _InputStage extends StatefulWidget {
  const _InputStage({
    required this.session,
    this.compose = false,
    this.compact = false,
  });

  final ActiveTerminalSession session;
  final bool compose;
  final bool compact;

  @override
  State<_InputStage> createState() => _InputStageState();
}

class _InputStageState extends State<_InputStage> {
  late var _mode = widget.compose ? terminalInputCompose : terminalInputKeys;
  final _drafts = TerminalComposeDrafts();
  final _focus = FocusNode();

  @override
  void dispose() {
    _drafts.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final input = widget.session.terminal.input;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const Expanded(child: ColoredBox(color: Color(0xFF101014))),
            TerminalSpecialKeys(
              order: defaultTerminalQuickKeys,
              customKeys: const [],
              onSend: (_, {bool enter = false}) {},
              onKey: (_) {},
              onPaste: () {},
              inputController: input,
              onAi: null,
              onPortForward: () {},
              pictureInPicture: false,
              onPictureInPicture: () {},
              fullscreen: false,
              onFullscreen: () {},
              split: false,
              onSplit: () {},
              compact: widget.compact,
              inputPanel: true,
              onInputPanel: () {},
              onPerformanceMonitor: () {},
            ),
            SizedBox(
              height: widget.compact ? 156 : 300,
              child: TerminalInputPanel(
                session: widget.session,
                mode: _mode,
                onModeChanged: (mode) => setState(() => _mode = mode),
                keyActions: TerminalKeyActions(
                  input: input,
                  onKey: (_) {},
                  onText: (_) {},
                  onPaste: () {},
                ),
                customKeys: const [],
                drafts: _drafts,
                composeFocus: _focus,
                onSystemKeyboard: () {},
                onHide: () {},
              ),
            ),
          ],
        ),
      ),
    );
  }
}
