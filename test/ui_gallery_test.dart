import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/app_lock.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/settings_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/models/settings.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/infrastructure/device_auth.dart';
import 'package:shun/infrastructure/http_client_provider.dart';
import 'package:shun/infrastructure/ssh/sftp_service.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/tailscale/catalog_cache.dart';
import 'package:shun/infrastructure/tailscale/catalog_cache_repository.dart';
import 'package:shun/presentation/home_shell.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';
import 'package:shun/presentation/screens/app_lock_settings_screen.dart';
import 'package:shun/presentation/screens/app_log_screen.dart';
import 'package:shun/presentation/screens/cloud_backup_screen.dart';
import 'package:shun/presentation/screens/hidden_hosts_screen.dart';
import 'package:shun/presentation/screens/known_hosts_screen.dart';
import 'package:shun/presentation/screens/sftp_screen.dart';
import 'package:shun/presentation/screens/settings_screen.dart';
import 'package:shun/presentation/screens/snippets_screen.dart';
import 'package:shun/presentation/screens/tailscale_catalog_screen.dart';
import 'package:shun/presentation/screens/tailscale_settings_screen.dart';
import 'package:shun/presentation/terminal/ghostty_terminal_view.dart';
import 'package:shun/presentation/ui/prism_theme.dart';
import 'package:shun/presentation/ui/shun_ui_host.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/presentation/widgets/connection_probe_sheet.dart';
import 'package:shun/presentation/widgets/custom_background.dart';
import 'package:shun/presentation/widgets/host_editor.dart';
import 'package:shun/presentation/widgets/proxy_profile_editor.dart';
import 'package:shun/presentation/widgets/session_overview.dart';

import 'support/component_gallery.dart';
import 'support/ui_gallery_fixtures.dart';

/// 当前 UI 基线：真实首页/终端/总览/文件页及原有表单/设置。只出图，不自动比对。
/// 主机/会话和独立 SFTP 列表使用内存 fixture；HomeShell 隐藏的本机服务使用隔离临时目录。
/// 没有远端会话、传输或真机流畅度的验收含义。平时跳过。
/// R83 起经生产 ShunUiHost 出图：Prism 与 Material 两种表示来自同一个语义主题。
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
        // 测试里的平台是 Android：Material 和 Prism 的界面字体族都是 Roboto。
        // 把同一份 Arial Unicode 注册成 Roboto，两种表示都得到真字形；字体文件与 R81 相同。
        final text = FontLoader('Roboto')
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

  // 背景图读文件、解码是真 IO。页面上的 Image 已经在假时钟里开始加载，它的回调排在假时钟的
  // 微任务里：在 runAsync 里 await 同一个加载会互相等死。和下面等本机文件服务一样，
  // 在原 zone 发起预缓存，轮流给真实时间和帧，直到图进了缓存。
  Future<void> precacheBackground(WidgetTester tester) async {
    final background = find.byType(CustomBackgroundImage);
    if (background.evaluate().isEmpty) return;
    final path = tester
        .widget<CustomBackgroundImage>(background)
        .settings
        .customBackgroundPath;
    var loaded = false;
    Object? error;
    unawaited(
      precacheImage(
        FileImage(File(path)),
        tester.element(background),
        onError: (exception, _) => error = exception,
      ).then((_) => loaded = true),
    );
    for (var attempt = 0; !loaded && attempt < 200; attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(loaded, isTrue, reason: '背景图没在 200 轮 IO/pump 内加载完');
    expect(error, isNull);
    await tester.pump();
    // 不只在树上，还要真画出来：没解码完时这里是 null，截图里就没有背景。
    final painted = tester.renderObject<RenderImage>(
      find.descendant(of: background, matching: find.byType(RawImage)),
    );
    expect(painted.image, isNotNull, reason: '背景图已解码但没画上');
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
        String? backgroundScope,
        String viewMode = 'grid',
        List<CatalogCache> catalogs = const [],
        double textScale = 1,
        SshService? ssh,
      }) async {
        await loadFonts(tester);
        final paths = (await tester.runAsync(UiGalleryPaths.create))!;
        paths.install();
        addTearDown(() => tester.runAsync(paths.dispose));
        String? backgroundFile;
        if (backgroundScope != null) {
          backgroundFile = (await tester.runAsync(
            () => _writeBackground(paths, width, height),
          ))!;
        }
        tester.view.physicalSize = Size(width * 2, height * 2);
        tester.view.devicePixelRatio = 2;
        tester.view.viewInsets = FakeViewPadding.zero;
        tester.platformDispatcher.textScaleFactorTestValue = textScale;
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
          // 用户存下的背景是受管目录里的文件引用；不透明度取默认的 35%。
          customBackgroundEnabled: backgroundFile != null,
          customBackgroundPath: backgroundFile == null
              ? ''
              : 'shun-background:$_backgroundName',
          customBackgroundScope: backgroundScope ?? 'global',
          serverViewMode: viewMode,
        ));
        await repository.saveVault(VaultData.empty().copyWith(
          hosts: hosts,
          customGroups: hosts.isEmpty ? [] : ['开发', '实验'],
        ));
        final container = ProviderContainer(overrides: [
          vaultRepositoryProvider.overrideWithValue(repository),
          appLockControllerProvider.overrideWith((ref) => AppLockController(
                auth: _NoDeviceAuth(),
                settings: const AppSettings(),
                hasConnectedTerminal: () => false,
              )),
          catalogCacheRepositoryProvider
              .overrideWithValue(_GalleryCatalog(catalogs)),
          if (ssh != null) sshServiceProvider.overrideWithValue(ssh),
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
            child: ShunUiHost(
              navigatorKey: GlobalKey<NavigatorState>(),
              theme: ShunUiTheme.resolve(Brightness.light, id),
              darkTheme: ShunUiTheme.resolve(Brightness.dark, id),
              themeMode: brightness == Brightness.dark
                  ? ThemeMode.dark
                  : ThemeMode.light,
              locale: const Locale('zh', 'CN'),
              home: home,
            ),
          ),
        ));
        if (backgroundFile != null) {
          // 设置读入要解析背景路径：轮流给真实时间和帧，直到读到的是这张图。
          for (var attempt = 0;
              container.read(settingsControllerProvider).customBackgroundPath !=
                      backgroundFile &&
                  attempt < 100;
              attempt++) {
            await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)));
            await tester.pump();
          }
          expect(container.read(settingsControllerProvider).customBackgroundPath,
              backgroundFile);
          // 读到设置后 HomeShell 要再建一帧，背景图才在树上。
          await tester.pump();
          await precacheBackground(tester);
        }
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

      // R84 公共控件：正常、禁用、处理中、校验失败、帮助，外加非模态面板开着时背后的页面。
      // 宽 390：分段那一行和 Tailscale 面板内容区一样宽，「MagicDNS 名称」应是一行原字号。
      testWidgets('公共控件', skip: skip != null, (tester) async {
        await pumpPage(tester, const ComponentGallery(),
            width: 390, height: 1800);
        await save(tester, 'components-390x1800-zh-s1');
        await tester.tap(find.byKey(const ValueKey('gallery-open-panel')));
        await save(tester, 'components-panel-390x1800-zh-s1');
      });

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

      // R88 主机表单：其余分支、编辑已有主机、键盘弹出、大字号、密钥面板、测试连接。
      testWidgets('新建连接：Mosh、Telnet、Tailscale 登录', skip: skip != null,
          (tester) async {
        await pumpPage(tester, HostEditor(onOtherType: (_) {}), height: 844);
        await tester.tap(find.byKey(const ValueKey('host-type-Mosh')));
        await save(tester, 'host-new-mosh-412x844-zh-s1');
        await tester.tap(find.byKey(const ValueKey('host-type-Telnet')));
        await save(tester, 'host-new-telnet-412x844-zh-s1');
        await tester.tap(find.byKey(const ValueKey('host-type-SSH')));
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('login-kind-tailscale')));
        await save(tester, 'host-new-tailscale-412x844-zh-s1');
        await tester.tap(find.byKey(const ValueKey('login-kind-key')));
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('host-key')));
        await save(tester, 'host-new-key-sheet-412x844-zh-s1');
      });

      testWidgets('编辑连接：带跳板、标签、置顶，高级展开', skip: skip != null, (tester) async {
        await pumpPage(
          tester,
          HostEditor(host: uiGalleryEditedHost, onDelete: () async => false),
          height: 2300,
          hosts: [uiGalleryJumpHost, uiGalleryEditedHost],
        );
        await save(tester, 'host-edit-412x2300-zh-s1');
        await tester.tap(find.byKey(const ValueKey('advanced-all')));
        await save(tester, 'host-edit-advanced-412x2300-zh-s1');
      });

      testWidgets('新建连接：键盘弹出时底栏在键盘上方', skip: skip != null, (tester) async {
        await pumpPage(tester, HostEditor(onOtherType: (_) {}), height: 844);
        await tester
            .showKeyboard(find.widgetWithText(TextFormField, '主机名 / IP'));
        tester.view.viewInsets = const FakeViewPadding(bottom: 600);
        await save(tester, 'host-new-keyboard-412x844-zh-s1');
      });

      for (final scale in const [1.3, 2.0]) {
        testWidgets('新建连接：字号 $scale 倍', skip: skip != null, (tester) async {
          await pumpPage(tester, HostEditor(onOtherType: (_) {}),
              height: 844, textScale: scale);
          final name = scale == 2.0 ? 's20' : 's13';
          await save(tester, 'host-new-412x844-zh-$name');
        });
      }

      for (final fail in const [false, true]) {
        testWidgets('测试连接：${fail ? '失败' : '成功'}', skip: skip != null,
            (tester) async {
          final host = uiGalleryHosts.first;
          await pumpPage(
            tester,
            Scaffold(
              body: ConnectionProbeSheet(
                host: host,
                plan: resolveRoutePlan(host,
                    hosts: const [], proxyProfiles: const []),
                verifyHostKey: (_, __, ___) async => true,
              ),
            ),
            height: 844,
            ssh: UiGalleryProbe(fail: fail),
          );
          expect(
              find.byKey(ValueKey(fail ? 'probe-failed' : 'probe-succeeded')),
              findsOneWidget);
          await save(
              tester, 'probe-${fail ? 'failed' : 'succeeded'}-412x844-zh-s1');
        });
      }

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
      // R86 设置组的二级页：和设置页同一套分组卡片。都是空数据下的样子。
      for (final (name, page) in const [
        ('app-lock', AppLockSettingsScreen()),
        ('known-hosts', KnownHostsScreen()),
        ('hidden-hosts', HiddenHostsScreen()),
        ('app-log', AppLogScreen()),
        ('snippets', SnippetsScreen()),
      ]) {
        testWidgets('设置二级页：$name', skip: skip != null, (tester) async {
          await pumpPage(tester, page, height: 892);
          await save(tester, 'settings-$name-412x892-zh-s1');
        });
      }

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

      // R87 连接首页：列表、树形两种视图，带两个 Tailscale 来源（见 uiGalleryCatalogs）。
      // 网格视图就是上面的 connections-populated。
      for (final view in const ['list', 'tree']) {
        testWidgets('连接首页：$view 视图和 Tailscale 分节', skip: skip != null,
            (tester) async {
          await pumpPage(tester, const HomeShell(),
              height: 1500,
              hosts: [...uiGalleryHosts, ...uiGalleryCatalogHosts],
              viewMode: view,
              catalogs: uiGalleryCatalogs());
          expect(find.byKey(const ValueKey('vault-catalog-gallery-work')),
              findsOneWidget);
          await save(tester, 'connections-$view-412x1500-zh-s1');
        });
      }

      testWidgets('连接首页：搜到目录设备、搜不到、分组', skip: skip != null,
          (tester) async {
        await pumpPage(tester, const HomeShell(),
            height: 892,
            hosts: [...uiGalleryHosts, ...uiGalleryCatalogHosts],
            viewMode: 'list',
            catalogs: uiGalleryCatalogs());
        final search = find.byKey(const ValueKey('vault-search'));
        await tester.enterText(search, '100.64.0.2');
        await settle(tester);
        expect(find.byKey(const ValueKey('vault-catalog-device-gallery-home-2')),
            findsOneWidget);
        await save(tester, 'connections-search-device-412x892-zh-s1');
        await tester.enterText(search, 'nothing-like-this');
        await settle(tester);
        expect(find.text('没有匹配的主机'), findsOneWidget);
        await save(tester, 'connections-search-none-412x892-zh-s1');
        await tester.enterText(search, '');
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('vault-group-chip-开发')));
        await save(tester, 'connections-group-412x892-zh-s1');
      });

      testWidgets('连接首页：主机都隐藏了', skip: skip != null, (tester) async {
        await pumpPage(tester, const HomeShell(), height: 892, hosts: [
          for (final host in uiGalleryHosts)
            HostProfile({...host.data, hiddenHostKey: true}),
        ]);
        expect(find.byKey(const ValueKey('vault-open-hidden')), findsOneWidget);
        await save(tester, 'connections-all-hidden-412x892-zh-s1');
      });

      testWidgets('Tailscale 目录：来源列表', skip: skip != null, (tester) async {
        await pumpPage(tester, const TailscaleCatalogScreen(),
            height: 892,
            hosts: uiGalleryCatalogHosts,
            catalogs: uiGalleryCatalogs());
        await save(tester, 'tailscale-catalog-412x892-zh-s1');
      });

      testWidgets('Tailscale 目录：旧且读取失败的来源', skip: skip != null,
          (tester) async {
        await pumpPage(
            tester, const CatalogSourceScreen(catalogId: 'gallery-work'),
            height: 892,
            hosts: uiGalleryCatalogHosts,
            catalogs: uiGalleryCatalogs());
        await save(tester, 'tailscale-catalog-work-412x892-zh-s1');
      });

      // R85 主导航外壳：横屏和平板。底栏是 Prism 的 NavigationBar，五个入口都在。
      for (final (name, width, height) in const [
        ('landscape-892x412', 892.0, 412.0),
        ('tablet-1280x800', 1280.0, 800.0),
      ]) {
        testWidgets('主导航：$name', skip: skip != null, (tester) async {
          final container = await pumpPage(
            tester,
            const HomeShell(),
            width: width,
            height: height,
            hosts: uiGalleryHosts,
            sessions: uiGallerySessions(),
          );
          await save(tester, 'shell-connections-$name-zh-s1');
          container.read(homeTabProvider.notifier).state = 1;
          await settle(tester);
          expect(find.byType(GhosttyTerminalView), findsOneWidget);
          await save(tester, 'shell-terminal-$name-zh-s1');
        });
      }

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

      // R83：同一个语义主题下的外观设置、弹层和自定义背景。
      testWidgets('设置页：外观与主题选择面板', skip: skip != null, (tester) async {
        await pumpPage(tester, const SettingsScreen(), height: 892);
        await save(tester, 'settings-appearance-412x892-zh-s1');
        await tester.tap(find.text('界面主题'));
        await save(tester, 'theme-picker-412x892-zh-s1');
      });

      testWidgets('连接首页：主机操作面板与详情弹窗', skip: skip != null,
          (tester) async {
        await pumpPage(tester, const HomeShell(),
            height: 892, hosts: uiGalleryHosts);
        await tester
            .tap(find.byKey(const ValueKey('vault-host-menu-gallery-web')));
        await save(tester, 'host-actions-412x892-zh-s1');
        // 点遮罩收起面板（不点任何操作），再点卡片看详情弹窗；弹窗里不点连接。
        await tester.tapAt(const Offset(206, 40));
        await settle(tester);
        await tester.tap(find.text('示例 Web'));
        await save(tester, 'host-details-412x892-zh-s1');
        expect(find.byType(AlertDialog), findsOneWidget);
      });

      testWidgets('自定义背景：全局的连接页、仅终端的终端页', skip: skip != null,
          (tester) async {
        await pumpPage(tester, const HomeShell(),
            height: 892, hosts: uiGalleryHosts, backgroundScope: 'global');
        expect(find.byType(CustomBackgroundImage), findsOneWidget);
        await precacheBackground(tester);
        await save(tester, 'connections-background-412x892-zh-s1');
      });

      testWidgets('自定义背景：仅终端', skip: skip != null, (tester) async {
        final container = await pumpPage(
          tester,
          const HomeShell(),
          height: 892,
          hosts: uiGalleryHosts,
          sessions: uiGallerySessions(),
          backgroundScope: 'terminal',
        );
        expect(find.byType(CustomBackgroundImage), findsNothing,
            reason: '仅终端的背景不铺到连接页');
        container.read(homeTabProvider.notifier).state = 1;
        await settle(tester);
        expect(find.byType(CustomBackgroundImage), findsOneWidget);
        await precacheBackground(tester);
        await save(tester, 'terminal-background-412x892-zh-s1');
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

const _backgroundName = 'background-gallery.png';

/// 自定义背景的可读性夹具：高对比的条纹和色块，故意比一般照片更花；放进受管目录。
Future<String> _writeBackground(
  UiGalleryPaths paths,
  double width,
  double height,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final size = Size(width, height);
  canvas.drawRect(
    Offset.zero & size,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        Offset(width, height),
        const [Color(0xFFFFD54F), Color(0xFF26C6DA), Color(0xFF7E57C2)],
        const [0, 0.5, 1],
      ),
  );
  final stripe = Paint()..color = const Color(0xFF101010);
  for (var x = -height; x < width; x += 48) {
    canvas.drawPath(
      Path()
        ..moveTo(x, 0)
        ..lineTo(x + 18, 0)
        ..lineTo(x + 18 + height, height)
        ..lineTo(x + height, height)
        ..close(),
      stripe,
    );
  }
  final image = await recorder.endRecording().toImage(
        width.round(),
        height.round(),
      );
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final directory = Directory('${paths.supportPath}/custom-backgrounds');
  await directory.create(recursive: true);
  final file = File('${directory.path}/$_backgroundName');
  await file.writeAsBytes(png!.buffer.asUint8List());
  return file.absolute.path;
}

class _NoDeviceAuth implements DeviceAuth {
  @override
  set onActivityPaused(void Function(bool ownActivity)? callback) {}

  @override
  Future<bool> isDeviceSecure() async => false;

  @override
  Future<DeviceAuthOutcome> authenticate({
    required String title,
    String? description,
    required bool pinOnly,
    required bool allowWeak,
  }) async =>
      const DeviceAuthOutcome(DeviceAuthResult.unavailable);

  @override
  Future<void> setProtectRecents(bool enabled) async {}
}

/// 真仓库要读写文件，而测试里的假时钟等不到真文件 IO，页面会停在加载中。只读。
class _GalleryCatalog extends CatalogCacheRepository {
  _GalleryCatalog(this.caches) : super(() async => Directory.systemTemp);

  final List<CatalogCache> caches;

  @override
  Future<CatalogCache?> load(String catalogId) async =>
      caches.where((cache) => cache.catalogId == catalogId).firstOrNull;
  @override
  Future<List<CatalogCache>> loadAll() async => caches;
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
