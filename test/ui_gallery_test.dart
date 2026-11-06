import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/models/settings.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/infrastructure/http_client_provider.dart';
import 'package:shun/infrastructure/ssh/sftp_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/tailscale/catalog_cache.dart';
import 'package:shun/infrastructure/tailscale/catalog_cache_repository.dart';
import 'package:shun/presentation/home_shell.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';
import 'package:shun/presentation/screens/cloud_backup_screen.dart';
import 'package:shun/presentation/screens/sftp_screen.dart';
import 'package:shun/presentation/screens/settings_screen.dart';
import 'package:shun/presentation/screens/tailscale_settings_screen.dart';
import 'package:shun/presentation/terminal/ghostty_terminal_view.dart';
import 'package:shun/presentation/theme.dart';
import 'package:shun/presentation/widgets/host_editor.dart';
import 'package:shun/presentation/widgets/proxy_profile_editor.dart';
import 'package:shun/presentation/widgets/session_overview.dart';

import 'support/ui_gallery_fixtures.dart';

/// 当前 UI 基线：真实首页/终端/总览/文件页及原有表单/设置。只出图，不自动比对。
/// 主机/会话和独立 SFTP 列表使用内存 fixture；HomeShell 隐藏的本机服务使用隔离临时目录。
/// 没有远端会话、传输或真机流畅度的验收含义。平时跳过。
///
/// `SHUN_UI_GALLERY=<绝对路径目录> flutter test --no-pub test/ui_gallery_test.dart`
///
/// 测试环境默认字体每个字都是方块，所以从 macOS 系统目录借字体；别的系统上找不到字体就跳过。
const _fontPath = '/System/Library/Fonts/Supplemental/Arial Unicode.ttf';
const _monoFontPath = '/System/Library/Fonts/Supplemental/Courier New.ttf';
const _shot = ValueKey('ui-gallery-shot');

void main() {
  final dir = Platform.environment['SHUN_UI_GALLERY'];
  final skip = dir == null
      ? '设了 SHUN_UI_GALLERY 才跑'
      : ([_fontPath, _monoFontPath].every((path) => File(path).existsSync())
          ? null
          : '没有图库所需的 macOS 字体');

  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() {
    final secrets = <String, String>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async {
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
        case 'deleteAll':
          secrets.clear();
          return null;
        case 'readAll':
          return Map<String, String>.of(secrets);
        case 'containsKey':
          return secrets.containsKey(key);
        default:
          return null;
      }
    });
    final language = ShunLocalizations.language;
    ShunLocalizations.use('zh-CN');
    addTearDown(() => ShunLocalizations.use(language));
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'shun',
      packageName: 'top.xdwa.shun',
      version: '1.4.7',
      buildNumber: '30',
      buildSignature: '',
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, null);
  });

  Future<void> loadFonts(WidgetTester tester) => tester.runAsync(() async {
        final text = FontLoader('Gallery')
          ..addFont(File(_fontPath)
              .readAsBytes()
              .then((bytes) => ByteData.sublistView(bytes)));
        await text.load();
        final monospace = FontLoader('monospace')
          ..addFont(File(_monoFontPath)
              .readAsBytes()
              .then((bytes) => ByteData.sublistView(bytes)));
        await monospace.load();
        final root = Platform.environment['FLUTTER_ROOT'] ??
            '/opt/homebrew/share/flutter';
        final icons = FontLoader('MaterialIcons')
          ..addFont(File(
                  '$root/bin/cache/artifacts/material_fonts/'
                  'MaterialIcons-Regular.otf')
              .readAsBytes()
              .then((bytes) => ByteData.sublistView(bytes)));
        await icons.load();
      });

  ThemeData theme(Brightness brightness, String id) {
    final base = ShunTheme.build(brightness, id);
    return base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'Gallery'),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'Gallery'),
    );
  }

  // 保留旧的深色截图文件名，浅色对应文件加 -light；新场景名同时记录视口/语言/字号。
  for (final brightness in [Brightness.dark, Brightness.light]) {
    group(brightness.name, () {
      Future<ProviderContainer> pumpPage(
        WidgetTester tester,
        Widget home, {
        double width = 412,
        double height = 1100,
        List<HostProfile> hosts = const [],
        SessionState sessions = const SessionState(),
      }) async {
        await loadFonts(tester);
        final paths = (await tester.runAsync(UiGalleryPaths.create))!;
        paths.install();
        addTearDown(() => tester.runAsync(paths.dispose));
        tester.view.physicalSize = Size(width * 2, height * 2);
        tester.view.devicePixelRatio = 2;
        tester.view.viewInsets = FakeViewPadding.zero;
        tester.platformDispatcher.textScaleFactorTestValue = 1;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        // flterm 的 idle 任务不等待不存在的真实帧时钟；与现有终端测试保持一致。
        final strategy = tester.binding.schedulingStrategy;
        tester.binding.schedulingStrategy =
            ({required int priority, required SchedulerBinding scheduler}) =>
                true;
        addTearDown(() => tester.binding.schedulingStrategy = strategy);

        final id = brightness == Brightness.dark ? 'midnight' : 'snow';
        final repository = await VaultRepository.open();
        await repository.saveSettings(AppSettings(
          themeMode: brightness.name,
          uiThemeId: id,
          language: 'zh-CN',
          terminalFontSize: 14,
        ));
        await repository.saveVault(VaultData.empty().copyWith(
          hosts: hosts,
          customGroups: hosts.isEmpty ? [] : ['开发', '实验'],
        ));
        final container = ProviderContainer(overrides: [
          vaultRepositoryProvider.overrideWithValue(repository),
          catalogCacheRepositoryProvider.overrideWithValue(_NoCatalog()),
          httpClientProvider.overrideWithValue(MockClient(
              (_) async => http.Response('{"tag_name":"v1.4.7"}', 200))),
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
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: theme(brightness, id),
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              builder: (context, child) =>
                  GhosttyDetachedThemeSync(child: child!),
              home: home,
            ),
          ),
        ));
        if (home is HomeShell) {
          // FutureBuilder 会吞掉插件/目录初始化错误；显式等其 Future，不能只看可见首页。
          final loader =
              tester.widget<FutureBuilder<MountableFileTransferService>>(
            find.byWidgetPredicate(
              (widget) => widget is FutureBuilder<MountableFileTransferService>,
              skipOffstage: false,
            ),
          );
          MountableFileTransferService? local;
          Object? loadError;
          StackTrace? loadStack;
          var completed = false;
          unawaited(loader.future!.then<void>((value) {
            local = value;
            completed = true;
          }, onError: (Object error, StackTrace stack) {
            loadError = error;
            loadStack = stack;
            completed = true;
          }));
          // Future 在 FakeAsync 中创建。runAsync 只给真实 IO 时间，pump 才能
          // 执行原 zone 的微任务；直接在 runAsync await 它会永远等不到完成。
          for (var attempt = 0; !completed && attempt < 100; attempt++) {
            await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)));
            await tester.pump();
          }
          expect(completed, isTrue,
              reason: '本机文件服务未在 100 次 IO/pump 轮转内完成初始化');
          if (loadError != null) {
            Error.throwWithStackTrace(loadError!, loadStack!);
          }
          expect(local?.rootPath, '${paths.documentsPath}/shun');
          expect(paths.documentsRequests, greaterThan(0));
          await settle(tester);
          expect(
            find.byKey(const ValueKey('sftp-title-bar'), skipOffstage: false),
            findsOneWidget,
          );
        }
        await settle(tester);
        return container;
      }

      Future<void> save(WidgetTester tester, String name) async {
        await settle(tester);
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

      testWidgets('代理编辑页', skip: skip != null, (tester) async {
        await pumpPage(tester, const ProxyProfileEditor());
        await save(tester, 'proxy-editor');
      });

      testWidgets('新建连接', skip: skip != null, (tester) async {
        await pumpPage(tester, const HostEditor(), height: 1500);
        await save(tester, 'host-editor');
      });

      testWidgets('新建连接：首屏、密钥、凭据、高级、RustDesk', skip: skip != null,
          (tester) async {
        await pumpPage(tester, HostEditor(onOtherType: (_) {}), height: 844);
        await save(tester, 'host-new-first');
        await tester.tap(find.byKey(const ValueKey('login-kind-key')));
        await save(tester, 'host-new-key');
        await tester.tap(find.byKey(const ValueKey('login-kind-credential')));
        await save(tester, 'host-new-credential');
        await tester.tap(find.byKey(const ValueKey('login-kind-password')));
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('host-group')));
        await save(tester, 'host-new-group');
        await tester.tap(find.byKey(const ValueKey('host-group-none')));
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('host-type-more')));
        await save(tester, 'host-new-more');
        await tester
            .tap(find.byKey(const ValueKey('connection-type-RustDesk')));
        await save(tester, 'host-new-rustdesk');
      });

      testWidgets('新建连接：高级展开', skip: skip != null, (tester) async {
        await pumpPage(tester, const HostEditor(), height: 1900);
        await tester.tap(find.byKey(const ValueKey('advanced-all')));
        await save(tester, 'host-new-advanced');
      });

      testWidgets('Tailscale 设置', skip: skip != null, (tester) async {
        await pumpPage(
          tester,
          Scaffold(body: TailscaleSettingsScreen(onDone: (_) {})),
          height: 1500,
        );
        await settle(tester);
        await tester
            .ensureVisible(find.byKey(const ValueKey('ts-settings-advanced')));
        await tester.tap(find.byKey(const ValueKey('ts-settings-advanced')));
        await save(tester, 'tailscale-settings');
      });

      testWidgets('云端备份 WebDAV', skip: skip != null, (tester) async {
        await pumpPage(tester, const CloudBackupScreen(), height: 900);
        await save(tester, 'cloud-backup-webdav');
      });

      testWidgets('云端备份 S3', skip: skip != null, (tester) async {
        await pumpPage(tester, const CloudBackupScreen(), height: 1300);
        await tester.tap(find.text('S3'));
        await save(tester, 'cloud-backup-s3');
      });

      // 设置页很长，整页出图缩小后看不清，所以只出要看的这一段。
      testWidgets('设置页：数据', skip: skip != null, (tester) async {
        await pumpPage(tester, const SettingsScreen(), height: 900);
        final row = find.byKey(const ValueKey('settings-cloud-backup'));
        await tester.scrollUntilVisible(row, 400,
            scrollable: find.byType(Scrollable).first);
        await save(tester, 'settings-data');
      });

      testWidgets('连接首页和终端：空态', skip: skip != null, (tester) async {
        final container = await pumpPage(
          tester,
          const HomeShell(),
          height: 892,
        );
        expect(find.byKey(const ValueKey('home-navigation-bar')),
            findsOneWidget);
        await save(tester, 'connections-empty-412x892-zh-s1');
        container.read(homeTabProvider.notifier).state = 1;
        await settle(tester);
        expect(find.text('没有活动会话'), findsOneWidget);
        await save(tester, 'terminal-empty-412x892-zh-s1');
      });

      testWidgets('连接首页：固定主机和分组', skip: skip != null, (tester) async {
        await pumpPage(tester, const HomeShell(),
            height: 892, hosts: uiGalleryHosts);
        expect(find.text('示例 Web'), findsOneWidget);
        expect(find.text('文件服务器'), findsOneWidget);
        await save(tester, 'connections-populated-412x892-zh-s1');
      });

      testWidgets('终端、按键面板、会话总览', skip: skip != null, (tester) async {
        final container = await pumpPage(
          tester,
          const HomeShell(),
          height: 892,
          hosts: uiGalleryHosts,
          sessions: uiGallerySessions(),
        );
        container.read(homeTabProvider.notifier).state = 1;
        await settle(tester);
        expect(find.byType(GhosttyTerminalView), findsOneWidget);
        await save(tester, 'terminal-active-412x892-zh-s1');

        await tester.tap(find.byKey(const ValueKey('terminal-action-more')));
        await settle(tester);
        await tester.tap(
            find.byKey(const ValueKey('terminal-action-session-overview')));
        await settle(tester);
        expect(find.byType(SessionOverview), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(SessionOverview),
            matching: find.byType(GhosttyTerminalView),
          ),
          findsNothing,
          reason: '总览只能用内存文字预览',
        );
        await save(tester, 'session-overview-412x892-zh-s1');

        await tester.tap(find.byKey(const ValueKey('overview-close')));
        await settle(tester);
        await tester.tap(
            find.byKey(const ValueKey('terminal-action-input-panel')));
        await settle(tester);
        expect(find.byKey(const ValueKey('terminal-input-panel')),
            findsOneWidget);
        await save(tester, 'terminal-input-panel-412x892-zh-s1');
      });

      testWidgets('SFTP：内存本机目录、双栏和单栏', skip: skip != null, (tester) async {
        await pumpPage(
          tester,
          Scaffold(
            body: SftpScreen(localService: Future.value(UiGalleryFiles())),
          ),
          height: 892,
        );
        expect(find.text('README.md'), findsNWidgets(2));
        await save(tester, 'sftp-local-dual-412x892-zh-s1');
        await tester.tap(find.byKey(const ValueKey('sftp-pane-mode-toggle')));
        await settle(tester);
        expect(find.text('README.md'), findsOneWidget);
        await save(tester, 'sftp-local-single-412x892-zh-s1');
      });

      testWidgets('SFTP：宽屏双栏、不同目录', skip: skip != null, (tester) async {
        await pumpPage(
          tester,
          Scaffold(
            body: SftpScreen(localService: Future.value(UiGalleryFiles())),
          ),
          width: 800,
          height: 600,
        );
        await tester.tap(find.descendant(
          of: find.byKey(const ValueKey('sftp-right-pane')),
          matching: find.text('docs'),
        ));
        await settle(tester);
        expect(find.text('guide.md'), findsOneWidget);
        expect(find.text('README.md'), findsOneWidget);
        await save(tester, 'sftp-local-dual-800x600-zh-s1');
      });
    });
  }
}

/// 真仓库要读写文件，而测试里的假时钟等不到真文件 IO，页面会停在加载中。
class _NoCatalog extends CatalogCacheRepository {
  _NoCatalog() : super(() async => Directory.systemTemp);

  @override
  Future<CatalogCache?> load(String catalogId) async => null;
  @override
  Future<List<CatalogCache>> loadAll() async => const [];
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
