import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/app.dart';
import 'package:shun/application/fork_features.dart';
import 'package:shun/application/sensitive_screen.dart';
import 'package:shun/infrastructure/http_client_provider.dart';
import 'package:shun/infrastructure/ssh/system_management_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/window_security.dart';
import 'package:shun/presentation/ui/components.dart';
import 'package:shun/presentation/ui/prism_localizations.dart';
import 'package:shun/presentation/widgets/connection_prompts.dart';
import 'package:shun/presentation/widgets/host_editor.dart';
import 'package:shun/presentation/widgets/keychain_sheet.dart';
import 'package:shun/presentation/widgets/proxy_profile_editor.dart';
import 'package:shun/presentation/widgets/secret_content.dart';
import 'package:shun/presentation/widgets/system_management/sudo_prompt.dart';

import 'support/ui_rules.dart';

// R44 / SEC13 的本机部分：什么时候让窗口防截屏、哪些页面接上了、密码框关没关输入法学习。
// 截屏真的变黑、输入法真的不学，只有设备上看得到（evidence/R44.md）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  final realGuard = SensitiveScreenGuard.instance;
  late _RecordingWindow window;
  late VaultRepository repository;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async => null);
    SharedPreferences.setMockInitialValues({});
    repository = await VaultRepository.open();
    window = _RecordingWindow();
    SensitiveScreenGuard.instance = SensitiveScreenGuard(window);
  });

  tearDown(() => SensitiveScreenGuard.instance = realGuard);

  Future<void> pump(WidgetTester tester, Widget home) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
      child: MaterialApp(home: home),
    ));
    await tester.pumpAndSettle();
  }

  /// 首页一个按钮，点了跑 [open]；返回首页的 context，关页面、开对话框都用它。
  Future<BuildContext> pumpLauncher(
    WidgetTester tester,
    FutureOr<void> Function(BuildContext context) open,
  ) async {
    late BuildContext home;
    await pump(
      tester,
      Builder(builder: (context) {
        home = context;
        return Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => open(context),
              child: const Text('open'),
            ),
          ),
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return home;
  }

  group('什么时候防截屏', () {
    testWidgets('敏感页显示时加上，退出就去掉', (tester) async {
      final home = await pumpLauncher(
        tester,
        (context) => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) =>
              const SecretContent(child: Scaffold(body: Text('editor'))),
        )),
      );
      expect(window.calls, [true]);
      Navigator.of(home).pop();
      await tester.pumpAndSettle();
      expect(window.calls, [true, false]);
    });

    testWidgets('首页 IndexedStack 里没选中的那页不算：设置页挂着不让终端页截不了', (tester) async {
      final tab = ValueNotifier(0);
      addTearDown(tab.dispose);
      await pump(
        tester,
        ValueListenableBuilder<int>(
          valueListenable: tab,
          builder: (_, index, __) => IndexedStack(
            index: index,
            children: const [
              Text('terminal'),
              SecretContent(child: Text('settings with a password field')),
            ],
          ),
        ),
      );
      expect(window.calls, isEmpty);
      tab.value = 1;
      await tester.pump();
      expect(window.calls, [true]);
      tab.value = 0;
      await tester.pump();
      expect(window.calls, [true, false]);
    });

    testWidgets('被不透明的新页面盖住时去掉，对话框盖在上面不去掉', (tester) async {
      late BuildContext editor;
      await pump(
        tester,
        SecretContent(
          child: Builder(builder: (context) {
            editor = context;
            return const Scaffold(body: Text('editor'));
          }),
        ),
      );
      expect(window.calls, [true]);

      unawaited(showDialog<void>(
        context: editor,
        builder: (_) => const AlertDialog(content: Text('confirm')),
      ));
      await tester.pumpAndSettle();
      expect(window.calls, [true], reason: '对话框后面还看得见编辑页');
      Navigator.of(editor).pop();
      await tester.pumpAndSettle();

      unawaited(Navigator.of(editor).push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('proxy list')),
      )));
      await tester.pumpAndSettle();
      expect(window.calls, [true, false]);
      Navigator.of(editor).pop();
      await tester.pumpAndSettle();
      expect(window.calls, [true, false, true]);
    });

    testWidgets('敏感页上再开敏感对话框：共用一次，关了对话框不放开', (tester) async {
      late BuildContext editor;
      await pump(
        tester,
        SecretContent(
          child: Builder(builder: (context) {
            editor = context;
            return const Scaffold(body: Text('editor'));
          }),
        ),
      );
      unawaited(showDialog<void>(
        context: editor,
        builder: (_) =>
            const SecretContent(child: AlertDialog(content: Text('sudo'))),
      ));
      await tester.pumpAndSettle();
      Navigator.of(editor).pop();
      await tester.pumpAndSettle();
      expect(window.calls, [true]);
    });

    testWidgets('不在 ProviderScope 里也照常工作：对话框从哪里弹都行', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: SecretContent(child: Scaffold(body: Text('sudo'))),
      ));
      expect(window.calls, [true]);
    });

    test('允许截屏时一律不加，关回去马上加回', () {
      final guard = SensitiveScreenGuard.instance;
      final page = Object();
      guard.allowScreenshots = true;
      guard.show(page);
      expect(window.calls, isEmpty);
      guard.allowScreenshots = false;
      expect(window.calls, [true]);
      guard.allowScreenshots = true;
      guard.hide(page);
      expect(window.calls, [true, false]);
    });
  });

  testWidgets('整个 App：只有云端备份页防，设置页本身能截；开关拨了存下来，之后这页也不防', (tester) async {
    // 设置页 await PackageInfo，不 mock 会抛 MissingPluginException。
    PackageInfo.setMockInitialValues(
      appName: 'shun',
      packageName: 'top.xdwa.shun',
      version: '1.4.7',
      buildNumber: '26',
      buildSignature: '',
    );
    // 设置页是懒加载 ListView：拉高窗口让「数据」和「安全」两节一次建出来。
    tester.view.physicalSize = const Size(800, 20000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
        httpClientProvider.overrideWithValue(
          MockClient((_) async => http.Response('{}', 200)),
        ),
        forkFeaturesProvider
            .overrideWithValue(const ForkFeatures(cloudSync: true)),
      ],
      child: const ShunApp(),
    ));
    await tester.pump(const Duration(seconds: 1));
    expect(window.calls, isEmpty);

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump(const Duration(seconds: 1));
    expect(window.calls, isEmpty, reason: '云同步表单搬走了，设置页本身没有密码');

    final backup = find.byKey(const ValueKey('settings-cloud-backup'));
    await tester.tap(backup);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(window.calls, [true]);

    await tester.tap(find.byType(BackButton));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(window.calls, [true, false]);

    await tester.tap(
      find.byKey(const ValueKey('settings-allow-sensitive-screenshots')),
    );
    await tester.pump(const Duration(seconds: 1));
    expect((await repository.loadSettings()).allowSensitiveScreenshots, isTrue);
    await tester.tap(backup);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(window.calls, [true, false], reason: '用户说了允许截，这页也不再防');
  });

  group('接上了的页面', () {
    EditableText field(WidgetTester tester, String label) =>
        editableNear(tester, find.text(label));

    void expectNoLearning(EditableText text) {
      expect(text.enableIMEPersonalizedLearning, isFalse);
      expect(text.enableSuggestions, isFalse);
      expect(text.autocorrect, isFalse);
      // 页面上别的打码框（不管是 Material、Prism 还是包装控件画的）也一起查。
      expect(leakingObscuredFields(), isEmpty);
    }

    testWidgets('编辑连接页；密码框切成明文也不让输入法学', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final home = await pumpLauncher(
        tester,
        (context) => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          enableDrag: false,
          builder: (_) => HostEditor(verifyHostKey: (h, a, f) async => true),
        ),
      );
      expect(window.calls, [true]);

      final password = find.text('密码（可选）');
      await tester.scrollUntilVisible(password, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expectNoLearning(field(tester, '密码（可选）'));
      await tester.tap(find.byIcon(Icons.visibility));
      await tester.pump();
      final shown = field(tester, '密码（可选）');
      expect(shown.obscureText, isFalse);
      expectNoLearning(shown);

      Navigator.of(home).pop();
      await tester.pumpAndSettle();
      expect(window.calls, [true, false]);
    });

    testWidgets('编辑代理页', (tester) async {
      final home = await pumpLauncher(
        tester,
        (context) => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => const ProxyProfileEditor(),
        )),
      );
      expect(window.calls, [true]);
      expectNoLearning(field(tester, '代理密码（可选）'));
      Navigator.of(home).pop();
      await tester.pumpAndSettle();
      expect(window.calls, [true, false]);
    });

    testWidgets('登录时的交互式提问，可回显的答案也不让输入法学', (tester) async {
      List<String>? answers = const ['unset'];
      await pumpLauncher(tester, (context) async {
        answers = await keyboardInteractivePrompt(context)('', '', [
          (echo: false, text: 'Password:'),
          (echo: true, text: 'Verification code:'),
        ]);
      });
      expect(window.calls, [true]);
      expectNoLearning(field(tester, 'Password:'));
      expectNoLearning(field(tester, 'Verification code:'));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(answers, isNull);
      expect(window.calls, [true, false]);
    });

    testWidgets('sudo 密码框', (tester) async {
      Object? outcome;
      await pumpLauncher(tester, (context) async {
        try {
          await runWithSudo<void>(
            context,
            () async => throw const DockerSudoPasswordRequired('need sudo'),
            (_) {},
          );
        } on SudoDeclined catch (declined) {
          outcome = declined;
        }
      });
      expect(window.calls, [true]);
      expectNoLearning(field(tester, 'sudo 密码'));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(outcome, isA<SudoDeclined>());
      expect(window.calls, [true, false]);
    });

    testWidgets('导入私钥：填口令的对话框防，密钥列表不防', (tester) async {
      final previous = _swapPicker(_FakePicker(FilePickerResult([
        PlatformFile(
          name: 'id_ed25519',
          size: 64,
          bytes: utf8.encode(
              '-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n'),
        ),
      ])));
      addTearDown(() => _swapPicker(previous));
      await pump(tester, const KeychainSheet());
      expect(window.calls, isEmpty, reason: '列表只有名字和类型');
      await tester.tap(find.text('导入私钥'));
      await tester.pumpAndSettle();
      expect(window.calls, [true]);
      expectNoLearning(field(tester, '口令（可选）'));
      await tester.tapAt(const Offset(4, 4)); // 点遮罩关掉，不导入
      await tester.pumpAndSettle();
      expect(window.calls, [true, false]);
    });
  });

  group('源码里的约定', () {
    final sources = [
      for (final file in Directory('lib').listSync(recursive: true))
        if (file is File && file.path.endsWith('.dart'))
          UiSource(file.path.replaceAll(r'\', '/'), file.readAsStringSync()),
    ];
    // 连同固定版本的 Prism 源码一起发现：哪些类里有打码框、开关关没关、自己包没包 SecretContent。
    final catalog = UiCatalog([...sources, ...prismSources()]);

    test('每个打码输入框都关了输入法学习、联想和自动更正', () {
      final problems = [
        for (final source in sources)
          for (final problem in secretFieldProblems(source.source))
            '${source.path}: $problem',
      ];
      expect(problems, isEmpty, reason: problems.join('\n'));
    });

    test('不用里面有不关学习的打码框的控件（Prism 的 SecretTextFormField 就是）', () {
      final leaky = catalog.leakySecretClasses();
      // 校准：固定版本的 Prism 这个控件确实不关学习。哪天 Prism 改了，这条先失败，再决定能不能用。
      expect(leaky, contains('prism.SecretTextFormField'));
      final calls = catalog.callsTo(leaky);
      expect(calls, isEmpty,
          reason:
              '改用 ShunSecretField（ui/components.dart）：\n${calls.join('\n')}');
    });

    test('有打码输入框的文件都用了 SecretContent', () {
      // 只在别处被包着的组件：写清楚是谁包的。
      const coveredElsewhere = {
        'lib/presentation/widgets/github_manual_config.dart': '只用在云端备份页，那页整个包着',
      };
      final (:secret, :covered) = catalog.secretClasses();
      // 用了自己不包 SecretContent 的秘密控件（含 Prism 的），等于自己写了打码框。
      final bare = secret.difference(covered);
      final missing = [
        for (final source in sources)
          if ((source.source.contains('obscureText:') ||
                  catalog.calls(source, bare)) &&
              !source.source.contains('SecretContent(') &&
              !coveredElsewhere.containsKey(source.path))
            source.path,
      ];
      expect(missing, isEmpty);
    });
  });

  group('运行时：打码框真的不让输入法学（R84）', () {
    Future<void> pumpField(WidgetTester tester, Widget field) => pump(
          tester,
          Scaffold(
              body: Padding(padding: const EdgeInsets.all(16), child: field)),
        );

    testWidgets('ShunSecretField：打码、切明文都关着三个开关，显示时防截屏', (tester) async {
      final controller = TextEditingController(text: 'hunter2');
      addTearDown(controller.dispose);
      await pumpField(
        tester,
        ShunSecretField(
          key: const ValueKey('secret'),
          controller: controller,
          label: '代理密码（可选）',
        ),
      );
      expect(window.calls, [true]);
      var text = editableNear(tester, find.byKey(const ValueKey('secret')));
      expect(text.obscureText, isTrue);
      expectQuiet(text);

      await tester.tap(find.byTooltip('显示密码'));
      await tester.pump();
      text = editableNear(tester, find.byKey(const ValueKey('secret')));
      expect(text.obscureText, isFalse);
      expectQuiet(text);
      expect(find.byTooltip('隐藏密码'), findsOneWidget);
    });

    testWidgets('校准：Prism 的 SecretTextFormField 打码时就让输入法学，查得出来',
        (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await pumpField(
        tester,
        // 它要 Prism 的文案（眼睛按钮的提示）；App 里由 ShunUiHost 提供。
        Builder(
          builder: (context) => Localizations.override(
            context: context,
            delegates: const [ShunPrismLocalizationsDelegate()],
            child:
                Form(child: prism.SecretTextFormField(controller: controller)),
          ),
        ),
      );
      final text = tester.widget<EditableText>(find.byType(EditableText));
      expect(text.obscureText, isTrue);
      expect(leakingObscuredFields(), isNotEmpty);
      expect(window.calls, isEmpty, reason: '它也不会让窗口防截屏');
    });
  });
}

/// [near] 所在那个输入框里的 EditableText：往上找到第一个只含一个 EditableText 的祖先。
/// 不按 TextField 类型找：换成 Prism 或包装控件，也是同一个输入框。
EditableText editableNear(WidgetTester tester, Finder near) {
  for (final ancestor in find
      .ancestor(of: near, matching: find.byWidgetPredicate((_) => true))
      .evaluate()) {
    // 由近到远：第一个只含一个输入框的祖先就是这个框自己。
    final inside = find.descendant(
      of: find.byElementPredicate((element) => identical(element, ancestor)),
      matching: find.byType(EditableText),
    );
    final count = inside.evaluate().length;
    if (count == 1) return tester.widget<EditableText>(inside);
    if (count > 1) break;
  }
  throw StateError('$near 附近没有唯一的输入框');
}

void expectQuiet(EditableText text) {
  expect(text.enableIMEPersonalizedLearning, isFalse);
  expect(text.enableSuggestions, isFalse);
  expect(text.autocorrect, isFalse);
}

/// 当前树上正在打码、却没关输入法学习、联想或自动更正的框。
/// 按 EditableText 查：Material、Prism、包装控件最后都落到它。
List<String> leakingObscuredFields() => [
      for (final element in find.byType(EditableText).evaluate())
        if (element.widget case final EditableText text
            when text.obscureText &&
                (text.enableIMEPersonalizedLearning ||
                    text.enableSuggestions ||
                    text.autocorrect))
          '${text.key ?? element}',
    ];

class _RecordingWindow implements WindowSecurity {
  final calls = <bool>[];

  @override
  Future<void> setSecure(bool secure) async => calls.add(secure);
}

FilePicker? _swapPicker(FilePicker? next) {
  FilePicker? previous;
  try {
    previous = FilePicker.platform;
  } catch (_) {
    // 桌面测试里没注册过平台实现，取不到旧的。
  }
  if (next != null) FilePicker.platform = next;
  return previous;
}

class _FakePicker extends FilePicker {
  _FakePicker(this.result);

  final FilePickerResult result;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async =>
      result;
}
