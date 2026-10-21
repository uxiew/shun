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
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/app.dart';
import 'package:shun/application/fork_features.dart';
import 'package:shun/application/sensitive_screen.dart';
import 'package:shun/infrastructure/http_client_provider.dart';
import 'package:shun/infrastructure/ssh/system_management_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/window_security.dart';
import 'package:shun/presentation/widgets/connection_prompts.dart';
import 'package:shun/presentation/widgets/host_editor.dart';
import 'package:shun/presentation/widgets/keychain_sheet.dart';
import 'package:shun/presentation/widgets/proxy_profile_editor.dart';
import 'package:shun/presentation/widgets/secret_content.dart';
import 'package:shun/presentation/widgets/system_management/sudo_prompt.dart';

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

  testWidgets('整个 App：云同步卡片只在设置页显示时防；设置开关拨了马上生效、存下来；切到终端页放开', (tester) async {
    // 设置页 await PackageInfo，不 mock 会抛 MissingPluginException。
    PackageInfo.setMockInitialValues(
      appName: 'shun',
      packageName: 'top.xdwa.shun',
      version: '1.4.7',
      buildNumber: '26',
      buildSignature: '',
    );
    // 设置页是懒加载 ListView：拉高窗口让云同步卡片和「安全」一节一次建出来。
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
    expect(window.calls, isEmpty, reason: '冷启动停在主机页，设置页在 IndexedStack 里挂着没显示');

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump(const Duration(seconds: 1));
    expect(window.calls, [true]);

    final allow =
        find.byKey(const ValueKey('settings-allow-sensitive-screenshots'));
    await tester.tap(allow);
    await tester.pump(const Duration(seconds: 1));
    expect(window.calls, [true, false]);
    expect((await repository.loadSettings()).allowSensitiveScreenshots, isTrue);
    await tester.tap(allow);
    await tester.pump(const Duration(seconds: 1));
    expect(window.calls, [true, false, true]);

    await tester.tap(find.byIcon(Icons.terminal_outlined));
    await tester.pump(const Duration(seconds: 1));
    expect(window.calls, [true, false, true, false]);
  });

  group('接上了的页面', () {
    EditableText field(WidgetTester tester, String label) =>
        tester.widget<EditableText>(find.descendant(
          of: find.ancestor(
            of: find.text(label),
            matching: find.byType(TextField),
          ),
          matching: find.byType(EditableText),
        ));

    void expectNoLearning(EditableText text) {
      expect(text.enableIMEPersonalizedLearning, isFalse);
      expect(text.enableSuggestions, isFalse);
      expect(text.autocorrect, isFalse);
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
          (file.path.replaceAll(r'\', '/'), file.readAsStringSync()),
    ];

    test('每个打码输入框都关了输入法学习、联想和自动更正', () {
      final problems = <String>[];
      for (final (path, source) in sources) {
        for (final match in _arg('obscureText').allMatches(source)) {
          final call = _fieldCall(source, match.start);
          if (call == null) {
            problems.add('$path: obscureText 不在 TextField/TextFormField 里');
            continue;
          }
          // 只有「打码时才是秘密」的框（Tailscale 目录的通用对话框）可以写成取反。
          final obscured = match.group(1)!.trim();
          for (final name in const [
            'enableIMEPersonalizedLearning',
            'enableSuggestions',
            'autocorrect',
          ]) {
            final value = _arg(name).firstMatch(call)?.group(1)?.trim();
            if (value != 'false' && value != '!$obscured') {
              problems.add('$path: obscureText: $obscured 的框 $name 是 $value');
            }
          }
        }
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    });

    test('有打码输入框的文件都用了 SecretContent', () {
      // 只在别处被包着的组件：写清楚是谁包的。
      const coveredElsewhere = {
        'lib/presentation/widgets/github_manual_config.dart':
            '只用在设置页的云同步卡片里，那张卡片整个包着',
      };
      final missing = [
        for (final (path, source) in sources)
          if (source.contains('obscureText:') &&
              !source.contains('SecretContent(') &&
              !coveredElsewhere.containsKey(path))
            path,
      ];
      expect(missing, isEmpty);
    });
  });
}

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

/// 命名参数的值：到逗号、换行或右括号为止。
RegExp _arg(String name) => RegExp('\\b$name:\\s*([^,\\n)]+)');

/// [at] 所在的那个 TextField(...) / TextFormField(...) 调用的整段源码；不在里面时为 null。
/// 往前找最近的构造调用，再往后配括号，跳过字符串里的括号。
String? _fieldCall(String source, int at) {
  final starts = RegExp(r'\b(?:TextField|TextFormField)\(')
      .allMatches(source.substring(0, at))
      .toList();
  if (starts.isEmpty) return null;
  final open = starts.last.end - 1;
  var depth = 0;
  String? quote;
  for (var i = open; i < source.length; i++) {
    final c = source[i];
    if (quote != null) {
      if (c == r'\') {
        i++;
      } else if (c == quote) {
        quote = null;
      }
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
    } else if (c == '(') {
      depth++;
    } else if (c == ')' && --depth == 0) {
      return i > at ? source.substring(open, i + 1) : null;
    }
  }
  return null;
}
