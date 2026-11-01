import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/models/settings.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/domain/vault_secrets.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/terminal/terminal_input_controller.dart';
import 'package:shun/infrastructure/terminal/terminal_session_adapter.dart';
import 'package:shun/presentation/widgets/terminal_key_button.dart';
import 'package:shun/presentation/widgets/terminal_key_feel_tiles.dart';
import 'package:shun/presentation/widgets/terminal_keys.dart';
import 'package:shun/presentation/widgets/terminal_special_keys.dart';

// R45 按主机的快捷键布局、模板、手感。真 SSH 在设备上测（integration_test/r45_host_keys_test.dart）。

class _Harness {
  final sent = <String>[];
  final special = <TerminalSpecialKey>[];
  final input = TerminalInputController();
  List<String>? savedHostOrder = const ['没存过'];
  var failHostSave = false;
  late _MemoryRepository repository;

  Widget app({
    List<String> order = defaultTerminalQuickKeys,
    bool exactOrder = false,
    List<String>? hostOrder,
    String? hostLabel,
    List<TerminalCustomKey> customKeys = const [],
    double height = 48,
    bool haptics = false,
    Duration repeatInterval = const Duration(milliseconds: 70),
    bool canSaveHost = true,
    bool compact = false,
  }) =>
      ProviderScope(
        overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          home: Scaffold(
            body: TerminalKeyFeel(
              height: height,
              haptics: haptics,
              repeatInterval: repeatInterval,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: TerminalSpecialKeys(
                  order: order,
                  exactOrder: exactOrder,
                  hostOrder: hostOrder,
                  hostLabel: hostLabel,
                  onSaveHostOrder: canSaveHost
                      ? (value) async {
                          if (failHostSave) throw StateError('磁盘满了');
                          savedHostOrder = value;
                        }
                      : null,
                  customKeys: customKeys,
                  onSend: (text, {bool enter = false}) => sent.add(text),
                  onKey: special.add,
                  inputController: input,
                  onAi: null,
                  onPortForward: null,
                  pictureInPicture: false,
                  onPictureInPicture: null,
                  fullscreen: false,
                  onFullscreen: () {},
                  split: false,
                  onSplit: null,
                  compact: compact,
                ),
              ),
            ),
          ),
        ),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Harness h;

  setUp(() {
    h = _Harness()..repository = _MemoryRepository();
  });

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('terminal-action-edit')));
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('terminal-keys-save')));
    await tester.pumpAndSettle();
  }

  void wide(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
  }

  group('模板', () {
    test('每个模板都是能存能显示的键：少一个定义，那个键就悄悄消失了', () {
      for (final id in supportedTerminalQuickKeys) {
        expect(terminalQuickKeySpecs, contains(id), reason: id);
      }
      for (final template in terminalKeyTemplates) {
        expect(template.keys, hasLength(14), reason: template.id);
        expect(template.keys.toSet(), hasLength(14), reason: template.id);
        for (final id in template.keys) {
          expect(supportedTerminalQuickKeys, contains(id), reason: id);
        }
        // ↑ 在 ↓ 正上方：两行各 7 个时同一列。
        expect(
          template.keys.indexOf('arrowDown') - template.keys.indexOf('arrowUp'),
          7,
          reason: template.id,
        );
      }
    });

    test('AI 命令行模板有任务点名要的键', () {
      final ai =
          terminalKeyTemplates.singleWhere((value) => value.id == 'ai-cli');
      expect(ai.keys, containsAll(['escape', 'ctrlC', 'shiftTab', 'slash']));
    });

    test('所有键都走 onKey、onText 或修饰键：没有别的出口（R25）', () {
      for (final entry in terminalQuickKeySpecs.entries) {
        final spec = entry.value;
        final routes = [
          spec.special != null,
          spec.text != null,
          spec.modifier != null
        ];
        expect(routes.where((value) => value), hasLength(1), reason: entry.key);
      }
    });

    testWidgets('选了模板能改：拿掉一个、加一个，存下来就是这一套，拿掉的不会回来', (tester) async {
      wide(tester);
      await tester.pumpWidget(h.app());
      await openSheet(tester);
      await tester.tap(
        find.byKey(const ValueKey('terminal-keys-template-ai-cli')),
      );
      await tester.pumpAndSettle();

      await tester
          .tap(find.byKey(const ValueKey('terminal-key-remove-escape')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('terminal-keys-add')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('terminal-keys-add-tilde')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('terminal-keys-add-tilde')));
      await tester.pumpAndSettle();
      await save(tester);

      final stored = h.repository.stored;
      expect(stored.terminalQuickKeysExact, isTrue);
      expect(stored.terminalQuickKeys, isNot(contains('escape')));
      expect(stored.terminalQuickKeys, contains('shiftTab'));
      expect(stored.terminalQuickKeys.last, 'tilde');
    });

    testWidgets('关掉不保存：什么都没改', (tester) async {
      wide(tester);
      await tester.pumpWidget(h.app());
      await openSheet(tester);
      await tester.tap(
        find.byKey(const ValueKey('terminal-keys-template-windows')),
      );
      await tester.pumpAndSettle();
      Navigator.of(
              tester.element(find.byKey(const ValueKey('terminal-keys-save'))))
          .pop();
      await tester.pumpAndSettle();
      expect(h.repository.saveCount, 0);
      expect(h.savedHostOrder, const ['没存过']);
    });

    testWidgets('横屏也放得下：开关、模板、保存都按得到，不报溢出', (tester) async {
      tester.view.physicalSize = const Size(2400, 1080);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(h.app(hostLabel: 'db-1'));
      await openSheet(tester);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('terminal-keys-host-scope')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('terminal-keys-save')));
      await tester.pumpAndSettle();
      expect(h.savedHostOrder, isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('只剩一个键时不能再拿掉', (tester) async {
      wide(tester);
      await tester.pumpWidget(h.app(order: const ['tab'], exactOrder: true));
      await openSheet(tester);
      final remove = tester.widget<IconButton>(
        find.byKey(const ValueKey('terminal-key-remove-tab')),
      );
      expect(remove.onPressed, isNull);
    });
  });

  group('按主机', () {
    Finder keyLabeled(String label) =>
        find.widgetWithText(TerminalKeyButton, label);

    testWidgets('有专用布局就用它，默认键不补进来', (tester) async {
      wide(tester);
      await tester.pumpWidget(h.app(hostOrder: const ['shiftTab', 'ctrlB']));
      expect(keyLabeled('⇧Tab'), findsOneWidget);
      expect(keyLabeled('Ctrl+B'), findsOneWidget);
      expect(keyLabeled('Esc'), findsNothing);
    });

    testWidgets('专用布局里不认识的键丢掉；全不认识就回到全局，不会一个键都没有', (tester) async {
      wide(tester);
      await tester.pumpWidget(h.app(hostOrder: const ['custom-gone', 'tab']));
      expect(keyLabeled('Tab'), findsOneWidget);
      expect(keyLabeled('Esc'), findsNothing);

      await tester.pumpWidget(h.app(hostOrder: const ['custom-gone']));
      expect(keyLabeled('Esc'), findsOneWidget);
    });

    testWidgets('没在快捷键设置里存过：默认键照旧补在最后；存过：不补', (tester) async {
      wide(tester);
      await tester.pumpWidget(h.app(order: const ['tab']));
      expect(keyLabeled('Esc'), findsOneWidget);
      await tester.pumpWidget(h.app(order: const ['tab'], exactOrder: true));
      await tester.pump();
      expect(keyLabeled('Tab'), findsOneWidget);
      expect(keyLabeled('Esc'), findsNothing);
    });

    testWidgets('存到主机失败：提示没存上，不抛出去', (tester) async {
      wide(tester);
      h.failHostSave = true;
      await tester.pumpWidget(h.app(hostLabel: 'db-1'));
      await openSheet(tester);
      await tester.tap(find.byKey(const ValueKey('terminal-keys-host-scope')));
      await tester.pumpAndSettle();
      await save(tester);
      expect(find.textContaining('快捷键没存上'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('本来就跟全局的主机，存全局布局时不碰保险库', (tester) async {
      wide(tester);
      await tester.pumpWidget(h.app(hostLabel: 'db-1'));
      await openSheet(tester);
      await save(tester);
      expect(h.savedHostOrder, const ['没存过']);
      expect(h.repository.saveCount, 1);
    });

    testWidgets('打开「只给这台主机用」存到主机，全局不动', (tester) async {
      wide(tester);
      await tester.pumpWidget(h.app(hostLabel: 'db-1'));
      await openSheet(tester);
      expect(find.text('db-1'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('terminal-keys-host-scope')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('terminal-keys-template-tmux-vim')),
      );
      await tester.pumpAndSettle();
      await save(tester);

      expect(
        h.savedHostOrder,
        terminalKeyTemplates
            .singleWhere((value) => value.id == 'tmux-vim')
            .keys,
      );
      expect(h.repository.stored.terminalQuickKeys, defaultTerminalQuickKeys);
      expect(h.repository.stored.terminalQuickKeysExact, isFalse);
    });

    testWidgets('关掉「只给这台主机用」：去掉专用布局，列表回到全局', (tester) async {
      wide(tester);
      await tester.pumpWidget(
        h.app(hostLabel: 'db-1', hostOrder: const ['tab']),
      );
      await openSheet(tester);
      await tester.tap(find.byKey(const ValueKey('terminal-keys-host-scope')));
      await tester.pumpAndSettle();
      await save(tester);
      expect(h.savedHostOrder, isNull);
      expect(h.repository.stored.terminalQuickKeys, defaultTerminalQuickKeys);
    });

    testWidgets('没进保险库的临时连接：没有这个开关', (tester) async {
      wide(tester);
      await tester.pumpWidget(h.app(canSaveHost: false, hostLabel: 'x'));
      await openSheet(tester);
      expect(
          find.byKey(const ValueKey('terminal-keys-host-scope')), findsNothing);
    });

    test('布局随主机导出：只有键的 id，没有密码，没有自定义键的内容', () {
      final host = HostProfile({
        'id': 'a',
        'label': 'a',
        'hostname': 'a.example.com',
        'port': 22,
        'username': 'root',
        'authMethod': 'password',
        'password': 'hunter2',
      }).withTerminalKeys(const ['shiftTab', 'custom-1']);
      expect(host.terminalKeys, ['shiftTab', 'custom-1']);
      expect(host.password, 'hunter2');

      final exported = jsonEncode(
        vaultWithoutSecrets(VaultData.empty().copyWith(hosts: [host])).toJson(),
      );
      expect(exported, contains('"terminalKeys":["shiftTab","custom-1"]'));
      expect(exported, isNot(contains('hunter2')));
      // 自定义键的内容在设置里，设置不进保险库：键里存了口令也带不出去。
      expect(VaultData.empty().toJson().keys,
          isNot(contains('terminalCustomKeys')));

      expect(host.withTerminalKeys(null).terminalKeys, isNull);
      expect(
          host.withTerminalKeys(null).data, isNot(contains(terminalKeysKey)));
      expect(host.withTerminalKeys(const []).terminalKeys, isNull);
    });
  });

  group('修饰键和发送', () {
    testWidgets('换布局（切到有专用布局的主机）不向远端发任何东西', (tester) async {
      wide(tester);
      await tester.pumpWidget(h.app());
      await tester.pumpWidget(h.app(hostOrder: const ['ctrlB', 'shiftTab']));
      await tester.pump();
      expect(h.sent, isEmpty);
      expect(h.special, isEmpty);
    });

    testWidgets('按住方向键时换了布局：连发停下，不会变成连发新键', (tester) async {
      wide(tester);
      await tester
          .pumpWidget(h.app(order: const ['arrowUp'], exactOrder: true));
      final gesture = await tester.startGesture(
        tester.getCenter(find.widgetWithText(TerminalKeyButton, '↑')),
      );
      await tester.pump(const Duration(milliseconds: 500));
      final held = h.special.length;
      expect(held, greaterThan(0));

      await tester.pumpWidget(h.app(hostOrder: const ['ctrlB']));
      await tester.pump(const Duration(milliseconds: 500));
      expect(h.special, hasLength(held));
      expect(h.sent, isEmpty);
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('⇧Tab 发 CSI Z，走和别的键同一个出口', (tester) async {
      wide(tester);
      await tester.pumpWidget(h.app(hostOrder: const ['shiftTab']));
      await tester.tap(find.widgetWithText(TerminalKeyButton, '⇧Tab'));
      await tester.pump();
      expect(h.sent, ['\x1b[Z']);
    });
  });

  group('手感', () {
    testWidgets('快捷键高度：行高跟着变', (tester) async {
      wide(tester);
      await tester.pumpWidget(h.app());
      final key = find.widgetWithText(TerminalKeyButton, 'Esc');
      expect(tester.getSize(key).height, 48);
      await tester.pumpWidget(h.app(height: 64));
      await tester.pump();
      expect(tester.getSize(key).height, 64);
    });

    testWidgets('紧凑一行也跟着变：用面板时只有这一行', (tester) async {
      wide(tester);
      await tester.pumpWidget(h.app(compact: true, height: 64));
      await tester.pump();
      final key = find.widgetWithText(TerminalKeyButton, 'Esc');
      expect(tester.getSize(key).height, 64);
    });

    testWidgets('键全加上又调到最高：小屏不溢出，多的在栏里滚', (tester) async {
      tester.view.physicalSize = const Size(945, 1313);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(h.app(
        order: supportedTerminalQuickKeys,
        exactOrder: true,
        height: 64,
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
      final last = find.byType(TerminalKeyButton).last;
      expect(tester.getSize(find.byType(TerminalSpecialKeys)).height,
          lessThan(1313 / 2.625));
      await tester.dragUntilVisible(
        last,
        find.ancestor(of: last, matching: find.byType(Scrollable)).first,
        const Offset(0, -80),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('连发速度：40ms 比 120ms 快', (tester) async {
      wide(tester);
      Future<int> repeats(Duration interval) async {
        h = _Harness()..repository = _MemoryRepository();
        await tester.pumpWidget(h.app(
          order: const ['arrowUp'],
          exactOrder: true,
          repeatInterval: interval,
        ));
        final gesture = await tester.startGesture(
          tester.getCenter(find.widgetWithText(TerminalKeyButton, '↑')),
        );
        await tester.pump(const Duration(milliseconds: 400));
        for (var i = 0; i < 24; i++) {
          await tester.pump(const Duration(milliseconds: 40));
        }
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 1));
        return h.special.length;
      }

      final fast = await repeats(const Duration(milliseconds: 40));
      final slow = await repeats(const Duration(milliseconds: 120));
      expect(fast, 25);
      expect(slow, 9);
    });

    testWidgets('按键震动：默认不震，开了震一下', (tester) async {
      wide(tester);
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            calls.add('${call.arguments}');
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(h.app());
      await tester.tap(find.widgetWithText(TerminalKeyButton, 'Esc'));
      await tester.pump();
      expect(calls, isEmpty);
      await tester.pumpWidget(h.app(haptics: true));
      await tester.tap(find.widgetWithText(TerminalKeyButton, 'Esc'));
      await tester.pump();
      expect(calls, hasLength(1));
    });

    test('设置存取：默认值不改变现在的手感，存了读得回来', () {
      const defaults = AppSettings();
      expect(defaults.terminalKeyHeight, 48);
      expect(defaults.terminalKeyRepeatMs, 70);
      expect(defaults.terminalKeyHaptics, isFalse);
      expect(defaults.terminalQuickKeysExact, isFalse);
      final back = AppSettings.fromJson(jsonDecode(jsonEncode(const AppSettings(
        terminalKeyHeight: 64,
        terminalKeyRepeatMs: 40,
        terminalKeyHaptics: true,
        terminalQuickKeysExact: true,
        terminalQuickKeys: ['ctrlB', 'shiftTab'],
      ).toJson())) as Map<String, dynamic>);
      expect(back.terminalKeyHeight, 64);
      expect(back.terminalKeyRepeatMs, 40);
      expect(back.terminalKeyHaptics, isTrue);
      expect(back.terminalQuickKeysExact, isTrue);
      expect(back.terminalQuickKeys, ['ctrlB', 'shiftTab']);
      // 旧版本存的设置没有这几项。
      expect(AppSettings.fromJson(const {}).terminalKeyHeight, 48);
      expect(AppSettings.fromJson(const {}).terminalQuickKeysExact, isFalse);
    });

    testWidgets('设置页三项改了就存', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [vaultRepositoryProvider.overrideWithValue(h.repository)],
        child: const MaterialApp(
          home: Scaffold(body: TerminalKeyFeelTiles()),
        ),
      ));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('settings-key-height')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('更高').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-key-repeat')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('快').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-key-haptics')));
      await tester.pumpAndSettle();
      expect(h.repository.stored.terminalKeyHeight, 64);
      expect(h.repository.stored.terminalKeyRepeatMs, 40);
      expect(h.repository.stored.terminalKeyHaptics, isTrue);
    });
  });
}

class _MemoryRepository implements VaultRepository {
  AppSettings stored = const AppSettings();
  var saveCount = 0;

  @override
  AppSettings loadSettingsPreview() => stored;

  @override
  Future<AppSettings> loadSettings() async => stored;

  @override
  Future<void> saveSettings(AppSettings settings) async {
    saveCount++;
    stored = settings;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
