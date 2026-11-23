import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shun/domain/models/settings.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/widgets/sftp_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/prism_test_host.dart';

Finder key(String id) => find.byKey(ValueKey(id));

Future<void> openEditor(
  WidgetTester tester, {
  required String name,
  required String content,
  Future<void> Function(String)? onSave,
  Size size = const Size(390, 800),
  ThemeData? theme,
  double textScale = 1,
}) async {
  SharedPreferences.setMockInitialValues({});
  final repo = await VaultRepository.open();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(ProviderScope(
    overrides: [vaultRepositoryProvider.overrideWithValue(repo)],
    child: MaterialApp(
      theme: theme,
      localizationsDelegates: prismTestDelegates,
      builder: prismTestBuilder,
      initialRoute: '/editor',
      routes: {
        '/': (_) => const Scaffold(body: Text('files')),
        '/editor': (_) => SftpEditor(
            name: name, content: content, onSave: onSave ?? (_) async {}),
      },
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final scale in [1.0, 1.8]) {
      testWidgets('gutter follows actual $platform layout at scale $scale',
          (tester) async {
        final content =
            '${List.filled(8, 'long code 中文 👩‍💻 with spaces ').join()}\r\n\n'
            'const value = "another long line of highlighted code";\nlast\n';
        await openEditor(tester,
            name: 'sample.dart',
            content: content,
            textScale: scale,
            theme: ThemeData(
                platform: platform,
                textTheme:
                    const TextTheme(bodyLarge: TextStyle(letterSpacing: 1.4))));

        void verify() {
          final gutter = tester.renderObject<RenderEditorLineNumbers>(
              find.byType(EditorLineNumbers));
          final RenderEditable editable = tester
              .state<EditableTextState>(find.byType(EditableText))
              .renderEditable;
          final text = tester
              .widget<EditableText>(find.byType(EditableText))
              .controller
              .text;
          final origin = MatrixUtils.transformPoint(
              editable.getTransformTo(gutter), Offset.zero);
          final first =
              editable.getLocalRectForCaret(const TextPosition(offset: 0)).top;
          var offset = 0;
          final lines = text.split('\n');
          expect(gutter.lineOffsets.keys,
              List.generate(lines.length, (i) => i + 1));
          for (var i = 0; i < lines.length; i++) {
            final caret =
                editable.getLocalRectForCaret(TextPosition(offset: offset));
            expect(gutter.lineOffsets[i + 1],
                closeTo(origin.dy + caret.top - first, 0.01));
            offset += lines[i].length + 1;
          }
          expect(tester.takeException(), isNull);
        }

        verify(); // Includes accidental wrapping from inherited letter spacing.
        await tester.tap(find.byKey(const ValueKey('editor-wrap-toggle')));
        await tester.pumpAndSettle();
        verify();
        tester.view.physicalSize = const Size(320, 800);
        await tester.pumpAndSettle();
        verify();
        await tester.enterText(find.byKey(const ValueKey('sftp-editor-field')),
            'new line\n$content');
        await tester.pumpAndSettle();
        verify();
      });
    }
  }
  test('file search supports literal, case, whole-word, regex and limits', () {
    var result = findEditorMatches('Alpha alpha alphabet', 'alpha');
    expect(result.matches.map((e) => '${e.start}:${e.end}'),
        ['0:5', '6:11', '12:17']);
    result =
        findEditorMatches('Alpha alpha alphabet', 'alpha', caseSensitive: true);
    expect(result.matches, [
      const TextRange(start: 6, end: 11),
      const TextRange(start: 12, end: 17)
    ]);
    result = findEditorMatches('Alpha alpha alphabet', 'alpha',
        mode: EditorSearchMode.wholeWord);
    expect(result.matches, hasLength(2));
    expect(
        findEditorMatches('猫 猫咪 猫', '猫', mode: EditorSearchMode.wholeWord)
            .matches,
        hasLength(2));
    result = findEditorMatches('one 12 two 345', r'\d+',
        mode: EditorSearchMode.regularExpression);
    expect(result.matches, [
      const TextRange(start: 4, end: 6),
      const TextRange(start: 11, end: 14)
    ]);
    expect(
        findEditorMatches('text', '[', mode: EditorSearchMode.regularExpression)
            .error,
        '正则表达式无效');
    result = findEditorMatches('aaaa', 'a', limit: 2);
    expect(result.matches, hasLength(2));
    expect(result.truncated, isTrue);
    expect(
        findEditorMatches('aaa', r'.*?',
                mode: EditorSearchMode.regularExpression)
            .matches,
        isEmpty);
  });

  test('line labels preserve logical numbering across visual wraps', () {
    const style = TextStyle(fontFamily: 'monospace', fontSize: 14, height: 1.5);
    const text =
        'this is a deliberately long first source line that must wrap\nsecond';
    expect(buildEditorLineLabels(text, style, TextScaler.noScaling), '1\n2');

    final wrapped = buildEditorLineLabels(
      text,
      style,
      TextScaler.noScaling,
      wrapWidth: 90,
    ).split('\n');
    expect(wrapped.first, '1');
    expect(wrapped.last, '2');
    expect(wrapped.where((label) => label == '1'), hasLength(1));
    expect(wrapped.where((label) => label == '2'), hasLength(1));
    expect(wrapped.where((label) => label.isEmpty), isNotEmpty);

    final enlarged = buildEditorLineLabels(
      text,
      style.copyWith(fontSize: 28),
      TextScaler.noScaling,
      wrapWidth: 90,
    ).split('\n');
    expect(enlarged.length, greaterThan(wrapped.length));
    expect(
        editorVisualRowForOffset(
          text,
          text.indexOf('second'),
          style,
          TextScaler.noScaling,
          wrapWidth: 90,
        ),
        wrapped.length - 1);
  });

  testWidgets(
      'editor searches, navigates, changes match mode and reports errors',
      (tester) async {
    await openEditor(tester, name: 'sample.txt', content: 'foo\nbar foo\nFOO');
    await tester.tap(find.byKey(const ValueKey('editor-search-toggle')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(
        find.byKey(const ValueKey('editor-search-field')), 'foo');
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('1 / 3'), findsOneWidget);
    TextSelection selection() => tester
        .widget<TextField>(key('sftp-editor-field'))
        .controller!
        .selection;
    expect(selection(), const TextSelection(baseOffset: 0, extentOffset: 3));
    await tester.tap(key('editor-search-next'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('2 / 3'), findsOneWidget);
    expect(selection(), const TextSelection(baseOffset: 8, extentOffset: 11));
    await tester.tap(key('editor-search-previous'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(selection(), const TextSelection(baseOffset: 0, extentOffset: 3));
    await tester.tap(find.byKey(const ValueKey('editor-search-case')));
    await tester.pumpAndSettle();
    expect(find.text('1 / 2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('editor-search-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('正则表达式').last);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('editor-search-field')), '[');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('正则表达式无效'), findsOneWidget);
    expect(
        tester
            .getSemantics(key('editor-search-next'))
            .flagsCollection
            .isEnabled,
        Tristate.isFalse);
    await tester.tap(key('editor-search-clear'));
    await tester.pumpAndSettle();
    expect(find.text('0 / 0'), findsOneWidget);
    await tester.tap(key('editor-search-close'));
    await tester.pumpAndSettle();
    expect(key('editor-search-field'), findsNothing);
  });

  test('highlight preference persists and defaults on', () {
    expect(AppSettings.fromJson({}).sftpSyntaxHighlight, isTrue);
    final value = const AppSettings().copyWith(sftpSyntaxHighlight: false);
    expect(AppSettings.fromJson(value.toJson()).sftpSyntaxHighlight, isFalse);
  });

  testWidgets(
      'a pending save blocks exit and saves only the submitted revision',
      (tester) async {
    final writes = <String>[];
    final pending = Completer<void>();
    await openEditor(tester, name: 'file.txt', content: 'original',
        onSave: (text) {
      writes.add(text);
      return pending.future;
    });
    final field = key('sftp-editor-field');
    final save = key('editor-save');
    await tester.enterText(field, 'first');
    await tester.tap(save);
    await tester.tap(save);
    await tester.pump();
    final busy = tester.getSemantics(save);
    expect(busy.label, contains('处理中'));
    expect(busy.flagsCollection.isEnabled, Tristate.isFalse);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(field, findsOneWidget);
    expect(key('editor-discard'), findsNothing);
    await tester.enterText(field, 'second');
    pending.complete();
    await tester.pumpAndSettle();
    expect(writes, ['first']);
    expect(find.text('* file.txt'), findsOneWidget);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(writes, ['first', 'second']);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('files'), findsOneWidget);
  });

  testWidgets('search keeps the editor keys and reading order', (tester) async {
    await openEditor(tester, name: 'text.txt', content: 'one two one');
    await tester.tap(key('editor-search-toggle'));
    await tester.pumpAndSettle();
    await tester.enterText(key('editor-search-field'), 'one');
    await tester.pumpAndSettle();
    const originalKeys = [
      'editor-search-field',
      'editor-search-mode',
      'editor-search-case',
      'editor-search-count',
      'editor-zoom-area',
      'editor-line-numbers',
      'sftp-editor-field',
      'editor-wrap-toggle',
      'editor-search-toggle',
    ];
    expect(
        tester.allWidgets
            .map((w) => w.key)
            .whereType<ValueKey<String>>()
            .map((k) => k.value)
            .where(originalKeys.contains),
        originalKeys);
    final labels = tester.semantics
        .simulatedAccessibilityTraversal()
        .map((node) => node.tooltip.isEmpty ? node.label : node.tooltip);
    expect(
        labels,
        containsAllInOrder([
          '关闭',
          'text.txt',
          '自动换行',
          '在文件中搜索',
          '撤销',
          '重做',
          '保存',
          '搜索打开的文件',
          '清除',
          '关闭搜索',
          contains('普通文本'),
          '区分大小写',
          '1 / 2',
          '上一个匹配',
          '下一个匹配',
        ]));
  });

  testWidgets('search remains usable above a narrow keyboard at large text',
      (tester) async {
    await openEditor(tester,
        name: 'long-filename-with-extension.txt',
        content: 'cat cats cat',
        size: const Size(360, 640),
        textScale: 2);
    await tester.tap(key('editor-search-toggle'));
    tester.view.viewInsets = const FakeViewPadding(bottom: 250);
    await tester.pumpAndSettle();
    await tester.enterText(key('editor-search-field'), 'cat');
    await tester.ensureVisible(key('editor-search-mode'));
    await tester.tap(key('editor-search-mode'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全词匹配').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(key('editor-search-next'));
    await tester.tap(key('editor-search-next'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    expect(tester.getSize(key('editor-zoom-area')).height, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('toolbar undoes and redoes edits', (tester) async {
    await openEditor(tester, name: 'file.txt', content: 'initial');
    final field = key('sftp-editor-field');
    String value() => tester.widget<TextField>(field).controller!.text;
    await tester.tap(field);
    await tester.pump(const Duration(seconds: 1));
    await tester.enterText(field, 'edited');
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(key('editor-undo'));
    await tester.pumpAndSettle();
    expect(value(), 'initial');
    await tester.tap(key('editor-redo'));
    await tester.pumpAndSettle();
    expect(value(), 'edited');
  });
  testWidgets('editor preserves text, numbers lines and retains failed saves',
      (tester) async {
    await openEditor(tester,
        name: 'a.json',
        content: '{\n"a": 1\n}',
        onSave: (_) async => throw StateError('save failed'));
    expect(
        tester
            .renderObject<RenderEditorLineNumbers>(
                find.byType(EditorLineNumbers))
            .lineOffsets
            .keys,
        [1, 2, 3]);
    final field = key('sftp-editor-field');
    await tester.enterText(field, '{"a": 2}');
    await tester.tap(key('editor-save'));
    await tester.pumpAndSettle();
    expect(find.text('Bad state: save failed'), findsOneWidget);
    expect(tester.widget<TextField>(field).controller!.text, '{"a": 2}');
    expect(find.text('* a.json'), findsOneWidget);
    expect(
        tester
            .getSemantics(key('editor-save-error'))
            .flagsCollection
            .isLiveRegion,
        isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(key('editor-discard'), findsOneWidget);
    await tester.tap(key('editor-discard-cancel'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, '{"a": 2}');
    await tester.tap(key('editor-close'));
    await tester.pumpAndSettle();
    await tester.tap(key('editor-discard'));
    await tester.pumpAndSettle();
    expect(find.text('files'), findsOneWidget);
  });

  testWidgets(
      'editor is borderless, wraps with logical line labels and pinch zooms',
      (tester) async {
    const content =
        'this is a deliberately very long source line repeated repeated repeated repeated repeated repeated repeated repeated\nsecond';
    await openEditor(tester, name: 'long.txt', content: content);

    RenderEditorLineNumbers gutter() => tester
        .renderObject<RenderEditorLineNumbers>(find.byType(EditorLineNumbers));
    var editor = tester
        .widget<TextField>(find.byKey(const ValueKey('sftp-editor-field')));
    final decoration = editor.decoration!;
    expect(decoration.border, InputBorder.none);
    expect(decoration.enabledBorder, InputBorder.none);
    expect(decoration.focusedBorder, InputBorder.none);
    expect(decoration.filled, isFalse);
    expect(gutter().lineOffsets.keys, [1, 2]);
    final unwrappedSpacing =
        gutter().lineOffsets[2]! - gutter().lineOffsets[1]!;
    expect(
        tester.getSize(find.byKey(const ValueKey('editor-line-numbers'))).width,
        lessThan(40));
    final initialEditorWidth =
        tester.getSize(find.byKey(const ValueKey('sftp-editor-field'))).width;
    final measuredLongestLine = editorLongestLineWidth(
      content,
      const TextStyle(fontFamily: 'monospace', fontSize: 14, height: 1.5),
      TextScaler.noScaling,
    );
    expect(initialEditorWidth, greaterThan(measuredLongestLine + 14));

    await tester.tap(find.byKey(const ValueKey('editor-wrap-toggle')));
    await tester.pumpAndSettle();
    expect(gutter().lineOffsets.keys, [1, 2]);
    expect(gutter().lineOffsets[2]! - gutter().lineOffsets[1]!,
        greaterThan(unwrappedSpacing));

    final zoomArea = find.byKey(const ValueKey('editor-zoom-area'));
    final center = tester.getCenter(zoomArea);
    final first =
        await tester.startGesture(center - const Offset(20, 0), pointer: 1);
    final second =
        await tester.startGesture(center + const Offset(20, 0), pointer: 2);
    await first.moveTo(center - const Offset(50, 0));
    await second.moveTo(center + const Offset(50, 0));
    await tester.pump();
    editor = tester
        .widget<TextField>(find.byKey(const ValueKey('sftp-editor-field')));
    expect(editor.style!.fontSize, greaterThan(14));
    expect(
        tester
            .widget<EditorLineNumbers>(find.byType(EditorLineNumbers))
            .style
            .fontSize,
        editor.style!.fontSize);
    expect(find.byKey(const ValueKey('editor-font-size')), findsOneWidget);
    await first.up();
    await second.up();
    await tester.pump();
    expect(find.byKey(const ValueKey('editor-font-size')), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('highlight toggles colors while preserving exact text',
      (tester) async {
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
      context = c;
      return const SizedBox();
    })));
    final controller =
        CodeTextController(text: '{"key": true}', filename: 'a.json');
    final highlighted =
        controller.buildTextSpan(context: context, withComposing: true);
    expect(highlighted.toPlainText(), controller.text);
    expect(
        highlighted.children!
            .whereType<TextSpan>()
            .any((s) => s.style?.color != null),
        isTrue);
    controller.highlight = false;
    final plain =
        controller.buildTextSpan(context: context, withComposing: true);
    expect(plain.toPlainText(), controller.text);
    expect(plain.children, isNull);
    controller.searchMatches = const [TextRange(start: 2, end: 5)];
    controller.currentSearchIndex = 0;
    final searched =
        controller.buildTextSpan(context: context, withComposing: true);
    expect(searched.toPlainText(), controller.text);
    expect(
        searched.children!
            .whereType<TextSpan>()
            .any((span) => span.style?.backgroundColor != null),
        isTrue);
    controller.dispose();
  });
}
