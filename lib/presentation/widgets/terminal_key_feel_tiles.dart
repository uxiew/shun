import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/settings_controller.dart';
import '../../domain/models/settings.dart';
import '../ui/components.dart';

/// 按键手感（R45）：设置页「终端」那一组里的三行。
///
/// 拆成三行交给设置页逐行放进分组（R86）：分组按每一行的位置画首尾圆角和行间细线，
/// 整块包成一个部件的话，三行会被当成一行。单独用时（测试、别处）放 [TerminalKeyFeelTiles]。
List<Widget> terminalKeyFeelRows() => const [
      _KeyHeightRow(),
      _KeyRepeatRow(),
      _KeyHapticsRow(),
    ];

class TerminalKeyFeelTiles extends StatelessWidget {
  const TerminalKeyFeelTiles({super.key});

  @override
  Widget build(BuildContext context) =>
      Column(mainAxisSize: MainAxisSize.min, children: terminalKeyFeelRows());
}

void _edit(WidgetRef ref, AppSettings Function(AppSettings persisted) change) {
  unawaited(ref.read(settingsControllerProvider.notifier).edit(change));
}

class _KeyHeightRow extends ConsumerWidget {
  const _KeyHeightRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final height = ref.watch(
      settingsControllerProvider.select((s) => s.terminalKeyHeight),
    );
    return ShunOptionsRow<double>(
      key: const ValueKey('settings-key-height'),
      title: '快捷键高度',
      value: terminalKeyHeightChoices.containsKey(height)
          ? height
          : defaultTerminalKeyHeight,
      options: [
        for (final MapEntry(:key, :value) in terminalKeyHeightChoices.entries)
          (key, value),
      ],
      onChanged: (value) =>
          _edit(ref, (s) => s.copyWith(terminalKeyHeight: value)),
    );
  }
}

class _KeyRepeatRow extends ConsumerWidget {
  const _KeyRepeatRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repeat = ref.watch(
      settingsControllerProvider.select((s) => s.terminalKeyRepeatMs),
    );
    return ShunOptionsRow<int>(
      key: const ValueKey('settings-key-repeat'),
      title: '方向键长按连发',
      value: terminalKeyRepeatChoices.containsKey(repeat)
          ? repeat
          : defaultTerminalKeyRepeatMs,
      options: [
        for (final MapEntry(:key, :value) in terminalKeyRepeatChoices.entries)
          (key, value),
      ],
      onChanged: (value) =>
          _edit(ref, (s) => s.copyWith(terminalKeyRepeatMs: value)),
    );
  }
}

class _KeyHapticsRow extends ConsumerWidget {
  const _KeyHapticsRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) => ShunSwitchRow(
        key: const ValueKey('settings-key-haptics'),
        title: '按键震动',
        value: ref.watch(
          settingsControllerProvider.select((s) => s.terminalKeyHaptics),
        ),
        onChanged: (value) =>
            _edit(ref, (s) => s.copyWith(terminalKeyHaptics: value)),
      );
}
