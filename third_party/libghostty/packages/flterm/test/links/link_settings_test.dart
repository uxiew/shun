import 'package:flterm/flterm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LinkSettings', () {
    test('enables all link types by default', () {
      const settings = LinkSettings();

      expect(settings.types, {LinkType.osc8, LinkType.text, LinkType.custom});
      expect(settings.modifier, ActivationModifier.primary);
      expect(settings.rules, isEmpty);
      expect(settings.onActivate, isNull);
    });

    test('compares regex rules by stable configuration', () {
      final first = LinkRule.regex(
        id: 'issue',
        pattern: RegExp(r'ISSUE-(\d+)'),
        priority: 10,
        highlightMode: LinkHighlightMode.always,
      );
      final second = LinkRule.regex(
        id: 'issue',
        pattern: RegExp(r'ISSUE-(\d+)'),
        priority: 10,
        highlightMode: LinkHighlightMode.always,
      );

      expect(first, second);
      expect(first.hashCode, second.hashCode);
    });

    test('compares link types as a set', () {
      const first = LinkSettings(types: {LinkType.osc8, LinkType.text});
      const second = LinkSettings(types: {LinkType.text, LinkType.osc8});

      expect(first, second);
      expect(first.hashCode, second.hashCode);
    });
  });
}
