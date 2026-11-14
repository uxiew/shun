import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/app_lock.dart';
import 'package:shun/application/sensitive_screen.dart';
import 'package:shun/domain/models/settings.dart';
import 'package:shun/infrastructure/device_auth.dart';
import 'package:shun/infrastructure/window_security.dart';
import 'package:shun/presentation/ui/non_modal_panel.dart';
import 'package:shun/presentation/ui/prism_theme.dart';
import 'package:shun/presentation/ui/shun_ui_host.dart';
import 'package:shun/presentation/widgets/form_gap.dart';
import 'package:shun/presentation/widgets/hint.dart';

import 'support/component_gallery.dart';

/// UIM05：R84 公共控件的正常、禁用、处理中、校验失败、焦点和帮助状态，非模态面板与普通确认。
/// 走生产 ShunUiHost（Prism 主题、文案都在），按 key、读屏语义和真实点击断言，不按控件类型。
/// 扫描器那一半在 test/ui_rules_bypass_test.dart、test/secret_content_test.dart。
void main() {
  late ProviderContainer container;
  final realGuard = SensitiveScreenGuard.instance;
  late _RecordingWindow window;

  setUp(() {
    container = ProviderContainer(overrides: [
      appLockControllerProvider.overrideWith((ref) => AppLockController(
            auth: _NoDeviceAuth(),
            settings: const AppSettings(),
            hasConnectedTerminal: () => false,
          )),
    ]);
    window = _RecordingWindow();
    SensitiveScreenGuard.instance = SensitiveScreenGuard(window);
  });
  tearDown(() {
    container.dispose();
    SensitiveScreenGuard.instance = realGuard;
  });

  Future<ComponentGalleryState> pump(
    WidgetTester tester, {
    double width = 390,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = Size(width * 2, 1800 * 2);
    tester.view.devicePixelRatio = 2;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: ShunUiHost(
        navigatorKey: GlobalKey<NavigatorState>(),
        theme: ShunUiTheme.resolve(Brightness.light, 'snow'),
        darkTheme: ShunUiTheme.resolve(Brightness.dark, 'midnight'),
        themeMode: ThemeMode.light,
        locale: const Locale('zh', 'CN'),
        home: const ComponentGallery(),
      ),
    ));
    await settle(tester);
    return tester.state<ComponentGalleryState>(find.byType(ComponentGallery));
  }

  Finder key(String value) => find.byKey(ValueKey(value));

  group('按钮', () {
    testWidgets('正常点一次算一次；处理中、禁用点不动，读屏听得出', (tester) async {
      final handle = tester.ensureSemantics();
      final gallery = await pump(tester);

      await tester.tap(key('gallery-save'));
      await tester.pump();
      expect(gallery.taps['save'], 1);

      gallery.setBusy(true);
      await tester.pump();
      await tester.tap(key('gallery-save'), warnIfMissed: false);
      await tester.tap(key('gallery-save'), warnIfMissed: false);
      await tester.pump();
      expect(gallery.taps['save'], 1, reason: '处理中连点不重复提交');
      final busy = tester.getSemantics(key('gallery-save'));
      expect(busy.label, contains('处理中'));
      expect(busy.label, contains('保存'));
      expect(busy.flagsCollection.isEnabled, Tristate.isFalse);

      gallery.setBusy(false);
      await tester.pump();
      expect(tester.getSemantics(key('gallery-save')).label,
          isNot(contains('处理中')));
      await tester.tap(key('gallery-save'));
      await tester.pump();
      expect(gallery.taps['save'], 2, reason: '忙完恢复可点');

      await tester.tap(key('gallery-busy'), warnIfMissed: false);
      await tester.tap(key('gallery-disabled'), warnIfMissed: false);
      await tester.pump();
      expect(gallery.taps['busy'], isNull);
      final disabled = tester.getSemantics(key('gallery-disabled'));
      expect(disabled.flagsCollection.isEnabled, Tristate.isFalse);
      handle.dispose();
    });

    testWidgets('键盘：Tab 能走到按钮，回车触发；禁用、处理中的跳过', (tester) async {
      final gallery = await pump(tester);
      final visited = <String>[];
      for (var i = 0; i < 6; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final focused = FocusManager.instance.primaryFocus?.context;
        final owner = focused == null
            ? null
            : find
                .ancestor(
                  of: find.byElementPredicate((e) => identical(e, focused)),
                  matching: find.byWidgetPredicate((w) =>
                      w.key is ValueKey<String> &&
                      (w.key! as ValueKey<String>)
                          .value
                          .startsWith('gallery-')),
                )
                .evaluate()
                .firstOrNull
                ?.widget
                .key;
        if (owner case ValueKey<String>(:final value)) visited.add(value);
        if (owner == const ValueKey('gallery-save')) {
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pump();
        }
      }
      expect(visited, contains('gallery-save'));
      expect(visited, isNot(contains('gallery-busy')));
      expect(visited, isNot(contains('gallery-disabled')));
      expect(gallery.taps['save'], 1, reason: '回车等于点一下');
    });
  });

  group('秘密输入框', () {
    testWidgets('校验失败写在框下面、读屏念得到；禁用的点不进去；相邻两框隔 FormGap', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester);
      expect(window.calls, [true], reason: '框在屏幕上，窗口防截屏');

      final error = key('gallery-secret-error');
      expect(find.descendant(of: error, matching: find.text('必填')),
          findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('必填')), findsWidgets);
      expect(
          find.descendant(
              of: key('gallery-secret'), matching: find.text('已加密保存')),
          findsOneWidget);

      final top = tester.getRect(key('gallery-secret'));
      final below = tester.getRect(error);
      expect(below.top - top.bottom, greaterThanOrEqualTo(formFieldGap),
          reason: '$top / $below');

      final disabled = key('gallery-secret-disabled');
      await tester.tap(disabled, warnIfMissed: false);
      await tester.pump();
      final text = tester.widget<EditableText>(
          find.descendant(of: disabled, matching: find.byType(EditableText)));
      expect(text.focusNode.hasFocus, isFalse);
      await tester.tap(
          find.descendant(of: disabled, matching: find.byTooltip('显示密码')),
          warnIfMissed: false);
      await tester.pump();
      expect(
          tester
              .widget<EditableText>(find.descendant(
                  of: disabled, matching: find.byType(EditableText)))
              .obscureText,
          isTrue,
          reason: '禁用时眼睛按钮也不响应，不会切成明文');
      handle.dispose();
    });

    testWidgets('点进去拿到键盘焦点，Tab 走到下一个框', (tester) async {
      await pump(tester);
      await tester.tap(key('gallery-secret'));
      await tester.pump();
      EditableText field(String id) => tester.widget<EditableText>(
          find.descendant(of: key(id), matching: find.byType(EditableText)));
      expect(field('gallery-secret').focusNode.hasFocus, isTrue);
      // 先到眼睛按钮，再到下一个框。
      for (var i = 0;
          i < 3 && !field('gallery-secret-error').focusNode.hasFocus;
          i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(field('gallery-secret-error').focusNode.hasFocus, isTrue);
    });
  });

  group('列表行与帮助', () {
    testWidgets('行、ⓘ、开关是三个读屏节点；点 ⓘ 不触发整行；ⓘ 48dp', (tester) async {
      final handle = tester.ensureSemantics();
      final gallery = await pump(tester);
      final row = tester.getSemantics(key('gallery-row'));
      expect(row.label, '状态同步, 每 5 分钟');
      expect(row.flagsCollection.isButton, isTrue);

      final hint = find.byTooltip(hintLabel('状态同步'));
      final hintNode = tester.getSemantics(hint);
      final switchNode = tester.getSemantics(key('gallery-row-switch'));
      expect({row.id, hintNode.id, switchNode.id}, hasLength(3));
      final size = tester.getSize(hint);
      expect(size.width, greaterThanOrEqualTo(48), reason: '$size');
      expect(size.height, greaterThanOrEqualTo(48), reason: '$size');

      await tester.tap(hint);
      await settle(tester);
      expect(find.text('后台定时读一次设备在线状态。'), findsOneWidget);
      expect(gallery.taps['row'], isNull);
      await tester.tap(find.text('知道了'));
      await settle(tester);

      await tester.tap(key('gallery-row-switch'));
      await tester.pump();
      expect(gallery.notify, isFalse);
      expect(gallery.taps['row'], isNull);

      await tester.tap(find.text('状态同步').first);
      await tester.pump();
      expect(gallery.taps['row'], 1);

      await tester.tap(key('gallery-row-disabled'));
      await tester.pump();
      expect(gallery.taps['row-disabled'], isNull);
      final disabled = tester.getSemantics(key('gallery-row-disabled'));
      expect(disabled.flagsCollection.isEnabled, Tristate.isFalse);
      handle.dispose();
    });
  });

  group('分段选择', () {
    // R83 记下的：正文 15 号后 Tailscale「用设备的哪个地址」三段里「MagicDNS 名称」折成两行。
    // 面板里内容区宽 390 - 2×24 = 342dp，和图库这一行一样宽。
    testWidgets('「MagicDNS 名称」原字号一行放下，不靠缩字；等分时放不下', (tester) async {
      await pump(tester);
      final label = find.text('MagicDNS 名称');
      final local = tester.getSize(label);
      final painted = tester.getRect(label);
      expect(painted.width / local.width, closeTo(1, 0.001),
          reason: '被 FittedBox 缩小了');
      final paragraph = tester.renderObject<RenderParagraph>(label);
      expect(paragraph.didExceedMaxLines, isFalse);
      final row = tester.getRect(key('gallery-seg-fqdn')).width +
          tester.getRect(key('gallery-seg-ipv4')).width +
          tester.getRect(key('gallery-seg-ipv6')).width;
      // 校准：等分时每段内容区只有 row/3 - 8，放不下这段字（原缺陷能复现）。
      expect(local.width, greaterThan(row / 3 - 8));
      expect(tester.getSize(key('gallery-seg-fqdn')).height,
          greaterThanOrEqualTo(42));
    });

    testWidgets('点已选中的那段也回调（「更多」靠它），读屏标出选中', (tester) async {
      final handle = tester.ensureSemantics();
      final gallery = await pump(tester);
      await tester.tap(key('gallery-seg-ipv4'));
      await tester.pump();
      expect(gallery.taps['seg-ipv4'], 1);
      await tester.tap(key('gallery-seg-fqdn'));
      await tester.pump();
      expect(gallery.address, 'fqdn');
      expect(
          tester
              .getSemantics(key('gallery-seg-fqdn'))
              .flagsCollection
              .isSelected,
          Tristate.isTrue);
      expect(
          tester
              .getSemantics(key('gallery-seg-ipv4'))
              .flagsCollection
              .isSelected,
          Tristate.isFalse);
      handle.dispose();
    });

    testWidgets('窄屏、大字号：等分缩字兜底，不溢出', (tester) async {
      await pump(tester, width: 320, textScale: 2);
      expect(tester.takeException(), isNull);
      expect(find.text('MagicDNS 名称'), findsOneWidget);
    });
  });

  group('面板', () {
    testWidgets('非模态面板：不新增遮罩，背后的按钮真点得到；返回键关掉返回 null', (tester) async {
      final gallery = await pump(tester);
      final barriers = find.byType(ModalBarrier).evaluate().length;

      await tester.tap(key('gallery-open-panel'));
      await settle(tester);
      expect(find.byKey(nonModalPanelKey), findsOneWidget);
      expect(find.byType(ModalBarrier).evaluate().length, barriers,
          reason: '面板没加遮罩');

      // 命中测试落在背后的按钮上，不是被什么透明层接走。
      final target = key('gallery-background');
      final center = tester.getCenter(target);
      final path = tester.hitTestOnBinding(center);
      final button = tester.renderObject(target);
      expect(
          path.path.any((entry) => identical(entry.target, button)) ||
              path.path.any((entry) =>
                  entry.target is RenderObject &&
                  _isDescendant(entry.target as RenderObject, button)),
          isTrue);
      await tester.tap(target);
      await tester.pump();
      expect(gallery.taps['background'], 1);
      expect(find.byKey(nonModalPanelKey), findsOneWidget, reason: '点背后不关面板');

      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.byKey(nonModalPanelKey), findsNothing);
      expect(gallery.panelResult, isNull);
    });

    testWidgets('面板里点保存：关掉并把结果交回；再开一个先关旧的', (tester) async {
      final gallery = await pump(tester);
      await tester.tap(key('gallery-open-panel'));
      await settle(tester);
      await tester.tap(key('gallery-panel-done'));
      await settle(tester);
      expect(gallery.panelResult, 'saved');
      expect(find.byKey(nonModalPanelKey), findsNothing);

      await tester.tap(key('gallery-open-panel'));
      await settle(tester);
      await tester.tap(key('gallery-open-panel'));
      await settle(tester);
      expect(find.byKey(nonModalPanelKey), findsOneWidget);
      expect(gallery.panelResult, isNull, reason: '旧的那次被顶掉，返回 null');
    });

    testWidgets('普通确认仍是模态：开着时背后点不到', (tester) async {
      final gallery = await pump(tester);
      final barriers = find.byType(ModalBarrier).evaluate().length;
      await tester.tap(key('gallery-confirm'));
      await settle(tester);
      expect(
          find.byType(ModalBarrier).evaluate().length, greaterThan(barriers));
      await tester.tap(key('gallery-background'), warnIfMissed: false);
      await tester.pump();
      expect(gallery.taps['background'], isNull);
      await tester.tap(key('gallery-confirm-no'));
      await settle(tester);
      expect(gallery.confirmed, isFalse);
    });
  });
}

/// 图库里有一直在转的「处理中」，pumpAndSettle 等不到静止：固定推 1 秒，弹窗、面板动画都走完。
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

bool _isDescendant(RenderObject node, RenderObject ancestor) {
  RenderObject? current = node;
  while (current != null) {
    if (identical(current, ancestor)) return true;
    current = current.parent;
  }
  return false;
}

class _RecordingWindow implements WindowSecurity {
  final calls = <bool>[];

  @override
  Future<void> setSecure(bool secure) async => calls.add(secure);
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
