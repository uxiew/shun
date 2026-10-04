import 'package:flterm/src/input/text_input_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TextInputSession', () {
    late TextInputSession handler;
    late List<String> commits;
    late List<int> deletes;
    late List<void> newlines;

    List<MethodCall> recordTextInputCalls() {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.textInput, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.textInput, null);
      });
      return calls;
    }

    List<MethodCall> textInputSetClientCalls(List<MethodCall> calls) {
      return calls
          .where((call) => call.method == 'TextInput.setClient')
          .toList();
    }

    Map<String, Object?> textInputConfig(List<MethodCall> calls) {
      final setClientCall = calls.singleWhere(
        (call) => call.method == 'TextInput.setClient',
      );
      final args = setClientCall.arguments as List<Object?>;
      return args[1]! as Map<String, Object?>;
    }

    Map<String, Object?> textInputUpdateConfig(List<MethodCall> calls) {
      final updateConfigCall = calls.singleWhere(
        (call) => call.method == 'TextInput.updateConfig',
      );
      return updateConfigCall.arguments! as Map<String, Object?>;
    }

    Map<String, Object?> textInputCall(List<MethodCall> calls, String method) {
      final call = calls.singleWhere((call) => call.method == method);
      return call.arguments! as Map<String, Object?>;
    }

    setUp(() {
      handler = TextInputSession()..viewId = 0;
      commits = [];
      deletes = [];
      newlines = [];
      handler.onTextCommitted = commits.add;
      handler.onDelete = deletes.add;
      handler.onNewline = () => newlines.add(null);
    });

    tearDown(() => handler.detach());

    group('updateEditingValueWithDeltas', () {
      test('commits inserted text', () {
        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: 'a',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange.empty,
          ),
        ]);

        expect(commits, ['a']);
      });

      test('commits multi-character insertion', () {
        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: 'hello',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 5),
            composing: TextRange.empty,
          ),
        ]);

        expect(commits, ['hello']);
      });

      test('commits text around newlines', () {
        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: 'a\nb\rc',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 5),
            composing: TextRange.empty,
          ),
        ]);

        expect(commits, ['a', 'b', 'c']);
      });

      test('reports inserted newlines', () {
        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: 'a\nb\rc',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 5),
            composing: TextRange.empty,
          ),
        ]);

        expect(newlines, hasLength(2));
      });

      test('deduplicates newline action after newline insertion', () {
        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: '\n',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange.empty,
          ),
        ]);

        handler.performAction(TextInputAction.newline);

        expect(newlines, hasLength(1));
      });

      test('deduplicates newline insertion after newline action', () {
        handler.performAction(TextInputAction.newline);

        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: '\n',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange.empty,
          ),
        ]);

        expect(newlines, hasLength(1));
      });

      test('deduplicates burst newline insertions after actions', () {
        handler.performAction(TextInputAction.newline);
        handler.performAction(TextInputAction.newline);

        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: '\n',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange.empty,
          ),
        ]);
        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: '\n',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange.empty,
          ),
        ]);

        expect(newlines, hasLength(2));
      });

      test('deduplicates burst newline actions after insertions', () {
        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: '\n',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange.empty,
          ),
        ]);
        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: '\n',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange.empty,
          ),
        ]);

        handler.performAction(TextInputAction.newline);
        handler.performAction(TextInputAction.newline);

        expect(newlines, hasLength(2));
      });

      test('deduplicates grouped newline insertion after actions', () {
        handler.performAction(TextInputAction.newline);
        handler.performAction(TextInputAction.newline);

        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: '\n\n',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 2),
            composing: TextRange.empty,
          ),
        ]);

        expect(newlines, hasLength(2));
      });

      test('deduplicates actions after grouped newline insertion', () {
        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: '\n\r\n',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 3),
            composing: TextRange.empty,
          ),
        ]);

        handler.performAction(TextInputAction.newline);
        handler.performAction(TextInputAction.newline);

        expect(newlines, hasLength(2));
      });

      test('committed text ends pending newline action suppression', () {
        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: '\n',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange.empty,
          ),
        ]);
        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: 'a',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange.empty,
          ),
        ]);

        handler.performAction(TextInputAction.newline);

        expect(newlines, hasLength(2));
      });

      test('committed text ends pending newline delta suppression', () {
        handler.performAction(TextInputAction.newline);
        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: 'a',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange.empty,
          ),
        ]);

        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: '\n',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange.empty,
          ),
        ]);

        expect(newlines, hasLength(2));
      });

      // xwshun: 平台的编辑都相对于编辑区（哨兵开头）算；提交后编辑区留着已发的字（R04 问题 8）。
      test('reports deletion character count', () {
        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: ' ',
            textInserted: 'ab',
            insertionOffset: 1,
            selection: TextSelection.collapsed(offset: 3),
            composing: TextRange.empty,
          ),
        ]);
        commits.clear();

        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaDeletion(
            oldText: ' ab',
            deletedRange: TextRange(start: 2, end: 3),
            selection: TextSelection.collapsed(offset: 2),
            composing: TextRange.empty,
          ),
        ]);

        expect(deletes, [1]);
        expect(commits, isEmpty);
      });

      test('reports multi-character deletion count', () {
        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: ' ',
            textInserted: 'abc',
            insertionOffset: 1,
            selection: TextSelection.collapsed(offset: 4),
            composing: TextRange.empty,
          ),
        ]);
        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaDeletion(
            oldText: ' abc',
            deletedRange: TextRange(start: 1, end: 4),
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange.empty,
          ),
        ]);

        expect(deletes, [3]);
      });

      test('deletion ends pending newline action suppression', () {
        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: '\n',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange.empty,
          ),
        ]);
        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaDeletion(
            oldText: ' ',
            deletedRange: TextRange(start: 0, end: 1),
            selection: TextSelection.collapsed(offset: 0),
            composing: TextRange.empty,
          ),
        ]);

        handler.performAction(TextInputAction.newline);

        expect(newlines, hasLength(2));
      });

      test('deletion ends pending newline delta suppression', () {
        handler.performAction(TextInputAction.newline);
        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaDeletion(
            oldText: ' ',
            deletedRange: TextRange(start: 0, end: 1),
            selection: TextSelection.collapsed(offset: 0),
            composing: TextRange.empty,
          ),
        ]);

        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: '\n',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange.empty,
          ),
        ]);

        expect(newlines, hasLength(2));
      });

      test('does not commit composing insertion', () {
        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: 'n',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange(start: 0, end: 1),
          ),
        ]);

        expect(commits, isEmpty);
      });

      test('does not commit sentinel-only composing insertion', () {
        final preedit = <String>[];
        handler.onPreeditChanged = preedit.add;

        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: ' ',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange(start: 0, end: 1),
          ),
        ]);

        expect(commits, isEmpty);
        expect(preedit, isEmpty);
        expect(handler.hasActiveComposition, isTrue);
      });

      test('commits final composing text', () {
        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: 'n',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange(start: 0, end: 1),
          ),
        ]);

        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaReplacement(
            oldText: 'n',
            replacementText: 'ni',
            replacedRange: TextRange(start: 0, end: 1),
            selection: TextSelection.collapsed(offset: 2),
            composing: TextRange(start: 0, end: 2),
          ),
        ]);

        expect(commits, isEmpty);

        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaReplacement(
            oldText: 'ni',
            replacementText: '\u4f60',
            replacedRange: TextRange(start: 0, end: 2),
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange.empty,
          ),
        ]);

        expect(commits, ['\u4f60']);
      });

      test('commits composing text finalized by non-text update', () {
        final preedit = <String>[];
        handler.onPreeditChanged = preedit.add;

        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: 'ni',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 2),
            composing: TextRange(start: 0, end: 2),
          ),
        ]);

        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaNonTextUpdate(
            oldText: '\u4f60',
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange.empty,
          ),
        ]);

        expect(commits, ['\u4f60']);
        expect(preedit, ['ni', '']);
      });

      test('ignores deletion that clears preedit text before commit', () {
        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: 'ni',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 2),
            composing: TextRange(start: 0, end: 2),
          ),
        ]);

        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaDeletion(
            oldText: 'ni',
            deletedRange: TextRange(start: 0, end: 2),
            selection: TextSelection.collapsed(offset: 0),
            composing: TextRange.empty,
          ),
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: '\u4f60',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange.empty,
          ),
        ]);

        expect(deletes, isEmpty);
        expect(commits, ['\u4f60']);
      });

      test('reports preedit updates', () {
        final preedit = <String>[];
        handler.onPreeditChanged = preedit.add;

        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: 'n',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange(start: 0, end: 1),
          ),
        ]);

        expect(preedit, ['n']);

        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaReplacement(
            oldText: 'n',
            replacementText: 'ni',
            replacedRange: TextRange(start: 0, end: 1),
            selection: TextSelection.collapsed(offset: 2),
            composing: TextRange(start: 0, end: 2),
          ),
        ]);

        expect(preedit, ['n', 'ni']);
      });

      test('reports empty preedit text after commit', () {
        final preedit = <String>[];
        handler.onPreeditChanged = preedit.add;

        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: 'a',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange(start: 0, end: 1),
          ),
        ]);

        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaReplacement(
            oldText: 'a',
            replacementText: 'A',
            replacedRange: TextRange(start: 0, end: 1),
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange.empty,
          ),
        ]);

        expect(preedit, ['a', '']);
      });

      test('commits non-composing replacement text', () {
        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: 'ab',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 2),
            composing: TextRange.empty,
          ),
        ]);
        commits.clear();

        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaReplacement(
            oldText: 'ab',
            replacementText: 'cd',
            replacedRange: TextRange(start: 0, end: 2),
            selection: TextSelection.collapsed(offset: 2),
            composing: TextRange.empty,
          ),
        ]);

        expect(commits, ['cd']);
      });

      test('ignores non-text updates', () {
        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaNonTextUpdate(
            oldText: '',
            selection: TextSelection.collapsed(offset: 0),
            composing: TextRange.empty,
          ),
        ]);

        expect(commits, isEmpty);
        expect(deletes, isEmpty);
        expect(newlines, isEmpty);
      });
    });

    group('updateEditingValue', () {
      test('commits finalized composing text', () {
        final preedit = <String>[];
        handler.onPreeditChanged = preedit.add;

        handler.updateEditingValue(
          const TextEditingValue(
            text: ' ni',
            selection: TextSelection.collapsed(offset: 3),
            composing: TextRange(start: 1, end: 3),
          ),
        );

        expect(commits, isEmpty);
        expect(preedit, ['ni']);

        handler.updateEditingValue(
          const TextEditingValue(
            text: ' \u4f60',
            selection: TextSelection.collapsed(offset: 2),
          ),
        );

        expect(commits, ['\u4f60']);
        expect(preedit, ['ni', '']);
      });

      test('keeps platform text input attached after candidate commit', () {
        final calls = recordTextInputCalls();
        handler.ensureAttached();
        calls.clear();

        handler.updateEditingValue(
          const TextEditingValue(
            text: ' ni',
            selection: TextSelection.collapsed(offset: 3),
            composing: TextRange(start: 1, end: 3),
          ),
        );
        handler.updateEditingValue(
          const TextEditingValue(
            text: ' \u4f60',
            selection: TextSelection.collapsed(offset: 2),
          ),
        );

        expect(
          calls.where((call) => call.method == 'TextInput.clearClient'),
          isEmpty,
        );
        expect(calls.where((call) => call.method == 'TextInput.hide'), isEmpty);
      });

      test('strips sentinel from composing text', () {
        final preedit = <String>[];
        handler.onPreeditChanged = preedit.add;

        handler.updateEditingValue(
          const TextEditingValue(
            text: ' ni',
            selection: TextSelection.collapsed(offset: 3),
            composing: TextRange(start: 0, end: 3),
          ),
        );

        expect(preedit, ['ni']);
      });

      test('tracks sentinel-only composing range as active composition', () {
        final preedit = <String>[];
        handler.onPreeditChanged = preedit.add;

        handler.updateEditingValue(
          const TextEditingValue(
            text: ' ',
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange(start: 0, end: 1),
          ),
        );

        expect(handler.hasActiveComposition, isTrue);
        expect(preedit, isEmpty);
        expect(commits, isEmpty);
      });

      test(
        'preserves committed leading and trailing spaces after sentinel',
        () {
          handler.updateEditingValue(
            const TextEditingValue(
              text: '  a ',
              selection: TextSelection.collapsed(offset: 4),
            ),
          );

          expect(commits, [' a ']);
        },
      );
    });

    group('performAction', () {
      test('fires onNewline for newline action', () {
        handler.performAction(TextInputAction.newline);

        expect(newlines, hasLength(1));
      });
    });

    group('consumeCommittedCompositionEdit', () {
      test('returns true after a committed composition', () {
        handler.updateEditingValue(
          const TextEditingValue(
            text: ' ni',
            selection: TextSelection.collapsed(offset: 3),
            composing: TextRange(start: 1, end: 3),
          ),
        );
        handler.updateEditingValue(
          const TextEditingValue(
            text: ' \u4f60',
            selection: TextSelection.collapsed(offset: 2),
          ),
        );

        final consumed = handler.consumeCommittedCompositionEdit();

        expect(consumed, isTrue);
      });

      test('returns false before a composition commits', () {
        final consumed = handler.consumeCommittedCompositionEdit();

        expect(consumed, isFalse);
      });

      test('does not detach text input', () {
        final calls = recordTextInputCalls();
        handler.ensureAttached();
        handler.updateEditingValue(
          const TextEditingValue(
            text: ' \u4f60',
            selection: TextSelection.collapsed(offset: 2),
          ),
        );
        calls.clear();

        handler.consumeCommittedCompositionEdit();

        expect(
          calls.where((call) => call.method == 'TextInput.clearClient'),
          isEmpty,
        );
        expect(calls.where((call) => call.method == 'TextInput.hide'), isEmpty);
        expect(handler.isAttached, isTrue);
      });

      test('suppresses the next deletion delta', () {
        handler.updateEditingValue(
          const TextEditingValue(
            text: ' \u4f60',
            selection: TextSelection.collapsed(offset: 2),
          ),
        );
        handler.consumeCommittedCompositionEdit();

        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaDeletion(
            oldText: '\u4f60',
            deletedRange: TextRange(start: 0, end: 1),
            selection: TextSelection.collapsed(offset: 0),
            composing: TextRange.empty,
          ),
        ]);

        expect(deletes, isEmpty);
      });

      test('suppresses only one deletion delta', () {
        handler.updateEditingValue(
          const TextEditingValue(
            text: ' \u4f60',
            selection: TextSelection.collapsed(offset: 2),
          ),
        );
        handler.consumeCommittedCompositionEdit();
        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaDeletion(
            oldText: ' \u4f60',
            deletedRange: TextRange(start: 1, end: 2),
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange.empty,
          ),
        ]);

        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaDeletion(
            oldText: ' ',
            deletedRange: TextRange(start: 0, end: 1),
            selection: TextSelection.collapsed(offset: 0),
            composing: TextRange.empty,
          ),
        ]);

        expect(deletes, [1]);
      });

      test('expires suppression after a non-text delta', () {
        handler.updateEditingValue(
          const TextEditingValue(
            text: ' \u4f60',
            selection: TextSelection.collapsed(offset: 2),
          ),
        );
        handler.consumeCommittedCompositionEdit();
        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaNonTextUpdate(
            oldText: ' \u4f60',
            selection: TextSelection.collapsed(offset: 2),
            composing: TextRange.empty,
          ),
        ]);

        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaDeletion(
            oldText: ' \u4f60',
            deletedRange: TextRange(start: 1, end: 2),
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange.empty,
          ),
        ]);

        expect(deletes, [1]);
      });

      test(
        'suppresses deletion after a preceding non-text delta in same batch',
        () {
          handler.updateEditingValue(
            const TextEditingValue(
              text: ' \u4f60',
              selection: TextSelection.collapsed(offset: 2),
            ),
          );
          handler.consumeCommittedCompositionEdit();

          handler.updateEditingValueWithDeltas([
            const TextEditingDeltaNonTextUpdate(
              oldText: ' \u4f60',
              selection: TextSelection.collapsed(offset: 2),
              composing: TextRange.empty,
            ),
            const TextEditingDeltaDeletion(
              oldText: ' \u4f60',
              deletedRange: TextRange(start: 1, end: 2),
              selection: TextSelection.collapsed(offset: 1),
              composing: TextRange.empty,
            ),
          ]);

          expect(deletes, isEmpty);
        },
      );

      test('expires suppression after a no-op editing update', () {
        handler.updateEditingValue(
          const TextEditingValue(
            text: ' \u4f60',
            selection: TextSelection.collapsed(offset: 2),
          ),
        );
        handler.consumeCommittedCompositionEdit();
        handler.updateEditingValue(
          const TextEditingValue(
            text: ' \u4f60',
            selection: TextSelection.collapsed(offset: 2),
          ),
        );

        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaDeletion(
            oldText: ' \u4f60',
            deletedRange: TextRange(start: 1, end: 2),
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange.empty,
          ),
        ]);

        expect(deletes, [1]);
      });

      test('keeps pending edit after an empty composing update', () {
        handler.updateEditingValue(
          const TextEditingValue(
            text: ' ni',
            selection: TextSelection.collapsed(offset: 3),
            composing: TextRange(start: 1, end: 3),
          ),
        );
        handler.updateEditingValue(
          const TextEditingValue(
            text: ' \u4f60',
            selection: TextSelection.collapsed(offset: 2),
          ),
        );
        handler.updateEditingValue(
          const TextEditingValue(
            text: ' \u4f60',
            selection: TextSelection.collapsed(offset: 2),
            composing: TextRange(start: 0, end: 1),
          ),
        );

        final consumed = handler.consumeCommittedCompositionEdit();

        expect(consumed, isTrue);
      });

      test('returns false after a canceled composition', () {
        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: 'n',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange(start: 0, end: 1),
          ),
        ]);
        handler.updateEditingValueWithDeltas([
          const TextEditingDeltaReplacement(
            oldText: 'n',
            replacementText: '',
            replacedRange: TextRange(start: 0, end: 1),
            selection: TextSelection.collapsed(offset: 0),
            composing: TextRange.empty,
          ),
        ]);

        final consumed = handler.consumeCommittedCompositionEdit();

        expect(consumed, isFalse);
      });
    });

    group('onFocusReceived', () {
      test('returns false', () {
        final acquiredFocus = handler.onFocusReceived();

        expect(acquiredFocus, isFalse);
      });
    });

    group('hide', () {
      test('clears preedit text', () {
        final preedit = <String>[];
        handler.onPreeditChanged = preedit.add;
        handler.updateEditingValue(
          const TextEditingValue(
            text: ' ni',
            selection: TextSelection.collapsed(offset: 3),
            composing: TextRange(start: 1, end: 3),
          ),
        );
        preedit.clear();

        handler.hide();

        expect(preedit, ['']);
      });
    });

    group('show', () {
      test('reuses an active connection', () {
        final calls = recordTextInputCalls();

        handler.show();
        handler.show();

        expect(textInputSetClientCalls(calls), hasLength(1));
      });
    });

    group('ensureAttached', () {
      test('throws when no Flutter view is set', () {
        final client = TextInputSession();
        addTearDown(client.detach);

        expect(
          client.ensureAttached,
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'Text input requires an owning Flutter view before attachment.',
            ),
          ),
        );
      });

      test('attaches without showing the keyboard', () {
        final calls = recordTextInputCalls();

        handler.ensureAttached();

        expect(textInputSetClientCalls(calls), hasLength(1));
        expect(calls.where((call) => call.method == 'TextInput.show'), isEmpty);
      });

      test('reuses an active connection', () {
        final calls = recordTextInputCalls();

        handler.ensureAttached();
        handler.ensureAttached();

        expect(textInputSetClientCalls(calls), hasLength(1));
      });

      test('preserves keyboard appearance when omitted', () {
        final calls = recordTextInputCalls();
        handler.ensureAttached(keyboardAppearance: Brightness.light);
        calls.clear();

        handler.ensureAttached();

        expect(
          textInputUpdateConfig(calls)['keyboardAppearance'],
          Brightness.light.toString(),
        );
      });

      test('reopens a connection orphaned by another client', () {
        final calls = recordTextInputCalls();
        handler.ensureAttached();
        final other = TextInputSession()..viewId = 0;
        addTearDown(other.detach);
        other.ensureAttached();
        calls.clear();

        handler.ensureAttached();

        expect(textInputSetClientCalls(calls), hasLength(1));
      });

      test('clears visible preedit when reopening an orphaned connection', () {
        final preedit = <String>[];
        handler.onPreeditChanged = preedit.add;
        handler.ensureAttached();
        handler.updateEditingValue(
          const TextEditingValue(
            text: ' ni',
            selection: TextSelection.collapsed(offset: 3),
            composing: TextRange(start: 1, end: 3),
          ),
        );
        final other = TextInputSession()..viewId = 0;
        addTearDown(other.detach);
        other.ensureAttached();
        preedit.clear();

        handler.ensureAttached();

        expect(preedit, ['']);
      });

      test('uses terminal text input traits', () {
        final calls = recordTextInputCalls();

        handler.ensureAttached(keyboardAppearance: Brightness.light);

        final config = textInputConfig(calls);
        expect(config['autocorrect'], isFalse);
        expect(config['enableSuggestions'], isFalse);
        expect(
          config['smartDashesType'],
          SmartDashesType.disabled.index.toString(),
        );
        expect(
          config['smartQuotesType'],
          SmartQuotesType.disabled.index.toString(),
        );
        expect(config['enableInteractiveSelection'], isFalse);
        expect(
          config['textCapitalization'],
          TextCapitalization.none.toString(),
        );
        expect(config['enableIMEPersonalizedLearning'], isFalse);
        expect(config['enableInlinePrediction'], isFalse);
        expect(config['enableDeltaModel'], isTrue);
        // xwshun: multiline 会被 Android 引擎当可见密码框，中文输入法只给英文键盘（R04 问题 4）。
        expect(
          (config['inputType']! as Map<String, Object?>)['name'],
          'TextInputType.emailAddress',
        );
        expect(config['inputAction'], TextInputAction.newline.toString());
        expect(config['keyboardAppearance'], Brightness.light.toString());
        expect(config['autofill'], isNull);
      });
    });

    group('viewId', () {
      test('keeps the active connection when the view is unchanged', () {
        final calls = recordTextInputCalls();
        handler.ensureAttached();
        calls.clear();

        handler.viewId = 0;

        expect(calls, isEmpty);
      });

      test('replaces the active connection when the view changes', () {
        final calls = recordTextInputCalls();
        handler.ensureAttached();
        calls.clear();

        handler.viewId = 1;

        expect(calls.map((call) => call.method), [
          'TextInput.clearClient',
          'TextInput.setClient',
          'TextInput.setEditingState',
        ]);
      });

      test('uses the new view for the replacement connection', () {
        final calls = recordTextInputCalls();
        handler.ensureAttached();
        calls.clear();

        handler.viewId = 1;

        expect(textInputConfig(calls)['viewId'], 1);
      });
    });

    group('keyboardAppearance', () {
      test('updates the active config', () {
        final calls = recordTextInputCalls();
        handler.ensureAttached();
        calls.clear();

        handler.keyboardAppearance = Brightness.light;

        final config = textInputUpdateConfig(calls);
        expect(config['keyboardAppearance'], Brightness.light.toString());
      });
    });

    group('updateGeometry', () {
      test('reports active connection geometry', () {
        final calls = recordTextInputCalls();
        handler.ensureAttached();
        calls.clear();

        handler.updateGeometry(
          editableSize: const Size(80, 40),
          transform: Matrix4.identity()..translateByDouble(12.0, 24.0, 0, 1),
          caretRect: const Rect.fromLTWH(16, 18, 8, 18),
          composingRect: const Rect.fromLTWH(16, 18, 24, 18),
        );

        final editable = textInputCall(
          calls,
          'TextInput.setEditableSizeAndTransform',
        );
        expect(editable['width'], 80.0);
        expect(editable['height'], 40.0);
        expect(editable['transform'], hasLength(16));
        expect(textInputCall(calls, 'TextInput.setCaretRect'), {
          'x': 16.0,
          'y': 18.0,
          'width': 8.0,
          'height': 18.0,
        });
        expect(textInputCall(calls, 'TextInput.setMarkedTextRect'), {
          'x': 16.0,
          'y': 18.0,
          'width': 24.0,
          'height': 18.0,
        });
      });

      test('ignores detached connection geometry', () {
        final calls = recordTextInputCalls();

        handler.updateGeometry(
          editableSize: const Size(80, 40),
          transform: Matrix4.identity(),
          caretRect: const Rect.fromLTWH(16, 18, 8, 18),
          composingRect: const Rect.fromLTWH(16, 18, 24, 18),
        );

        expect(calls, isEmpty);
      });
    });

    group('detach', () {
      test('clears the active connection', () {
        handler.ensureAttached();

        handler.detach();

        expect(handler.isAttached, isFalse);
      });
    });

    // xwshun: R04 问题 4，终端吞掉软键盘的键以后逼平台把光标位置重新告诉输入法。
    group('resyncAfterKeyEdit', () {
      List<Object?> editingStates(List<MethodCall> calls) => [
        for (final call in calls)
          if (call.method == 'TextInput.setEditingState')
            (call.arguments! as Map<String, Object?>)['selectionBase'],
      ];

      test('pushes two different states ending on the sentinel', () {
        final calls = recordTextInputCalls();
        handler.ensureAttached();
        calls.clear();

        handler.resyncAfterKeyEdit();

        expect(editingStates(calls), [0, 1]);
        expect(
          handler.currentTextEditingValue,
          const TextEditingValue(
            text: ' ',
            selection: TextSelection.collapsed(offset: 1),
          ),
        );
      });

      test('does nothing while the IME is composing', () {
        final calls = recordTextInputCalls();
        handler
          ..ensureAttached()
          ..updateEditingValueWithDeltas([
            const TextEditingDeltaInsertion(
              oldText: ' ',
              textInserted: 'n',
              insertionOffset: 1,
              selection: TextSelection.collapsed(offset: 2),
              composing: TextRange(start: 1, end: 2),
            ),
          ]);
        calls.clear();

        handler.resyncAfterKeyEdit();

        expect(editingStates(calls), isEmpty);
      });

      test('does nothing without a connection', () {
        final calls = recordTextInputCalls();

        handler.resyncAfterKeyEdit();

        expect(calls, isEmpty);
      });
    });

    // xwshun: R04 问题 8。提交后编辑区留着已发的字，输入法改写时按差异补发。
    // 用 _FakeIme 按 Android InputConnection 的调用生成编辑（都相对于平台编辑区现在的值），
    // 会话发出的字、退格、回车喂给 _RemoteLine（像 PTY 行编辑那样处理退格），最后核对远端那一行。
    group('xwshun: retained text and diff resend', () {
      late _RemoteLine remote;
      late _FakeIme ime;

      setUp(() {
        remote = _RemoteLine();
        handler
          ..onTextCommitted = (text) {
            commits.add(text);
            remote.type(text);
          }
          ..onDelete = (count) {
            deletes.add(count);
            remote.backspace(count);
          }
          ..onNewline = () {
            newlines.add(null);
            remote.enter();
          };
        ime = _FakeIme(handler);
      });

      test('WeChat voice re-marks committed text without resending it', () {
        // R04 真机日志里微信输入法语音的编辑步骤：每次更新识别结果先结束组字，紧接着把组字区圈回
        // 刚出现的那段字再改。上游在结束组字那一刻提交并清空编辑区，一句话发了 9 次。
        final versions = ['你', '你好，', '你好，你谁', '你好啊，你谁', '你好啊，你是谁？'];
        for (final version in versions) {
          if (handler.currentTextEditingValue.text.length > 1) {
            ime.setComposingRegion(
              1,
              handler.currentTextEditingValue.text.length,
            );
          }
          ime
            ..setComposingText(version)
            ..finishComposingText();
          expect(remote.current, version);
        }
        // 只删真改了的字：「，你谁」→「啊，你谁」删 3 个，「你谁」→「你是谁？」删 1 个。
        expect(deletes, [3, 1]);
        expect(commits, ['你', '好，', '你谁', '啊，你谁', '是谁？']);

        // 最后一版停在组字区：和已发相同的部分留在远端，没确定的只显示不发。
        final preedit = <String>[];
        handler.onPreeditChanged = preedit.add;
        ime
          ..setComposingRegion(1, handler.currentTextEditingValue.text.length)
          ..setComposingText('你好啊，你是谁？在一');
        expect(remote.current, '你好啊，你是谁？');
        expect(preedit.last, '在一');
        expect(remote.lines, ['你好啊，你是谁？']);
        expect(newlines, isEmpty);
      });

      test('WeChat voice keeps only the final sentence after Enter', () {
        ime
          ..setComposingText('你在')
          ..finishComposingText()
          ..setComposingRegion(1, 3)
          ..setComposingText('你在干嘛')
          ..finishComposingText();
        handler.performAction(TextInputAction.newline);

        expect(remote.lines, ['你在干嘛', '']);
      });

      test('pinyin candidate commits once and backspace deletes it', () {
        for (final pinyin in ['n', 'ni', 'nih', 'niha', 'nihao']) {
          ime.setComposingText(pinyin);
        }
        expect(commits, isEmpty);

        ime.commitText('你好');
        expect(commits, ['你好']);

        ime.deleteSurroundingText(1);
        expect(deletes, [1]);
        expect(remote.current, '你');
      });

      test('pinyin typed then fully deleted sends nothing', () {
        for (final pinyin in ['c', 'ce', 'ces', 'cesh', 'ceshi']) {
          ime.setComposingText(pinyin);
        }
        for (final pinyin in ['cesh', 'ces', 'ce', 'c', '']) {
          ime.setComposingText(pinyin);
        }
        ime.finishComposingText();

        expect(commits, isEmpty);
        expect(deletes, isEmpty);

        ime.deleteSurroundingText(1);
        expect(deletes, [1]);
      });

      test('mixed pinyin and latin commit in order', () {
        ime
          ..setComposingText('zhong')
          ..commitText('中')
          ..setComposingText('git')
          ..commitText('git');

        expect(commits, ['中', 'git']);
        expect(remote.current, '中git');
      });

      test('composing Enter commits the letters then a newline', () {
        ime
          ..setComposingText('ls')
          ..commitText('ls');
        handler.performAction(TextInputAction.newline);

        expect(commits, ['ls']);
        expect(remote.lines, ['ls', '']);
      });

      test('late newline delta after the Enter action does not resend', () {
        // 有的输入法先报回车动作，再补一个换行编辑；那个编辑是按它自己还留着字的编辑区算的，
        // 这边就算在回车时清了编辑区，它也还没看到。
        ime.commitText('ls');
        final imeView = handler.currentTextEditingValue;
        handler.performAction(TextInputAction.newline);
        ime.commitText('\n', on: imeView);

        expect(commits, ['ls']);
        expect(newlines, hasLength(1));
        expect(handler.currentTextEditingValue.text, ' ');
      });

      test('newline delta then Enter action sends one newline', () {
        ime
          ..commitText('ls')
          ..commitText('\n');
        handler.performAction(TextInputAction.newline);

        expect(commits, ['ls']);
        expect(newlines, hasLength(1));
      });

      test(
        'IME rewriting committed text sends backspaces and the new tail',
        () {
          ime
            ..commitText('ab')
            ..replace(1, 3, 'ac');

          expect(deletes, [1]);
          expect(commits, ['ab', 'c']);
          expect(remote.current, 'ac');
        },
      );

      test('emoji deletion sends one backspace per code point', () {
        ime
          ..commitText('a👍')
          ..deleteSurroundingText(2);

        expect(deletes, [1]);
        expect(remote.current, 'a');
      });

      test('backspace on the empty editor deletes one remote character', () {
        remote.type('ls');
        ime
          ..deleteSurroundingText(1)
          ..deleteSurroundingText(1);

        expect(deletes, [1, 1]);
        expect(remote.current, '');
        expect(handler.currentTextEditingValue.text, ' ');
      });

      test('IME replacing the sentinel mid-composition does not retype', () {
        // 输入法把哨兵连同已发的字整段换掉，前面一个字定了、后面接着组字。之后每次组字更新，
        // 已经补发过的「x」都不能再删了重发。
        ime
          ..commitText('ab')
          ..replace(0, 3, 'xz', composing: const TextRange(start: 1, end: 2))
          ..setComposingText('zy')
          ..setComposingText('zyw')
          ..finishComposingText();

        expect(deletes, [2]);
        expect(commits, ['ab', 'x', 'zyw']);
        expect(remote.current, 'xzyw');
        expect(handler.currentTextEditingValue.text, ' ');
      });

      test('discardRetainedText forgets committed text', () {
        final calls = recordTextInputCalls();
        handler.ensureAttached();
        ime.commitText('abc');
        calls.clear();

        handler.discardRetainedText();

        expect(handler.currentTextEditingValue.text, ' ');
        expect(
          calls.where((call) => call.method == 'TextInput.setEditingState'),
          hasLength(1),
        );
        // 远端那一行的字是别的路改的，之后的退格只按次数发。
        ime.deleteSurroundingText(1);
        expect(deletes, [1]);
        expect(commits, ['abc']);
      });

      test('discardRetainedText is a no-op on a clean editor', () {
        final calls = recordTextInputCalls();
        handler.ensureAttached();
        calls.clear();

        handler.discardRetainedText();

        expect(calls, isEmpty);
      });

      test('discardRetainedText waits for the composition to end', () {
        handler.ensureAttached();
        ime.setComposingText('ni');

        handler.discardRetainedText();
        expect(handler.currentTextEditingValue.text, ' ni');

        ime.commitText('你');
        expect(commits, ['你']);
        expect(handler.currentTextEditingValue.text, ' ');
      });

      test(
        'discard requested from a commit callback runs after the commit',
        () {
          handler.ensureAttached();
          handler.onTextCommitted = (text) {
            commits.add(text);
            handler.discardRetainedText();
          };

          ime.commitText('c');

          expect(commits, ['c']);
          expect(handler.currentTextEditingValue.text, ' ');
        },
      );

      test('very long retained text is cleared when idle', () {
        handler.ensureAttached();
        ime.commitText('a' * 5000);

        expect(commits.single, hasLength(5000));
        expect(handler.currentTextEditingValue.text, ' ');
      });

      test('committed text stays in the editor for the IME', () {
        handler.ensureAttached();
        ime.commitText('你好');

        expect(handler.currentTextEditingValue.text, ' 你好');
      });
    });
  });
}

/// xwshun: 按 Android InputConnection 的调用生成平台编辑。每次都从会话现在的编辑区算起，
/// 会话清空编辑区（setEditingState）后，输入法看到的也是清空后的样子。
final class _FakeIme {
  _FakeIme(this.session);

  final TextInputSession session;

  TextEditingValue get _value => session.currentTextEditingValue;

  TextRange _target(TextEditingValue value) {
    final composing = value.composing;
    if (composing.isValid &&
        !composing.isCollapsed &&
        composing.end <= value.text.length) {
      return composing;
    }
    final cursor = value.selection.baseOffset.clamp(0, value.text.length);
    return TextRange.collapsed(cursor);
  }

  void setComposingText(String text) => _write(
    text,
    composing: (start) => TextRange(start: start, end: start + text.length),
  );

  /// [on] 是输入法以为的编辑区（它还没收到这边的清空时，和会话现在的值不一样）。
  void commitText(String text, {TextEditingValue? on}) =>
      _write(text, composing: (_) => .empty, on: on);

  void finishComposingText() => _send(
    TextEditingDeltaNonTextUpdate(
      oldText: _value.text,
      selection: _value.selection,
      composing: .empty,
    ),
  );

  void setComposingRegion(int start, int end) => _send(
    TextEditingDeltaNonTextUpdate(
      oldText: _value.text,
      selection: _value.selection,
      composing: TextRange(start: start, end: end),
    ),
  );

  void deleteSurroundingText(int before) {
    final cursor = _value.selection.baseOffset;
    final start = cursor - before;
    _send(
      TextEditingDeltaDeletion(
        oldText: _value.text,
        deletedRange: TextRange(start: start, end: cursor),
        selection: TextSelection.collapsed(offset: start),
        composing: .empty,
      ),
    );
  }

  void replace(
    int start,
    int end,
    String text, {
    TextRange composing = .empty,
  }) => _send(
    TextEditingDeltaReplacement(
      oldText: _value.text,
      replacementText: text,
      replacedRange: TextRange(start: start, end: end),
      selection: TextSelection.collapsed(offset: start + text.length),
      composing: composing,
    ),
  );

  void _write(
    String text, {
    required TextRange Function(int) composing,
    TextEditingValue? on,
  }) {
    final value = on ?? _value;
    final range = _target(value);
    final selection = TextSelection.collapsed(
      offset: range.start + text.length,
    );
    if (range.isCollapsed) {
      if (text.isEmpty) return;
      _send(
        TextEditingDeltaInsertion(
          oldText: value.text,
          textInserted: text,
          insertionOffset: range.start,
          selection: selection,
          composing: composing(range.start),
        ),
      );
      return;
    }
    _send(
      TextEditingDeltaReplacement(
        oldText: value.text,
        replacementText: text,
        replacedRange: range,
        selection: selection,
        composing: composing(range.start),
      ),
    );
  }

  void _send(TextEditingDelta delta) =>
      session.updateEditingValueWithDeltas([delta]);
}

/// xwshun: 远端 shell 的当前行：退格按字（码点）删，删到行首就不再删。
final class _RemoteLine {
  final lines = <String>[''];

  String get current => lines.last;

  void type(String text) => lines.last += text;

  void backspace(int count) {
    final runes = lines.last.runes.toList();
    final keep = runes.length > count ? runes.length - count : 0;
    lines.last = String.fromCharCodes(runes.take(keep));
  }

  void enter() => lines.add('');
}
