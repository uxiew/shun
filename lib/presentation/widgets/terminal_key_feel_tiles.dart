import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/settings_controller.dart';
import '../../domain/models/settings.dart';
import '../localization/localized_widgets.dart';

/// 按键手感（R45）：设置页「终端」那一组里的三项。
class TerminalKeyFeelTiles extends ConsumerWidget {
  const TerminalKeyFeelTiles({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    void edit(AppSettings Function(AppSettings persisted) change) {
      unawaited(ref.read(settingsControllerProvider.notifier).edit(change));
    }

    return Column(
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const LText('快捷键高度'),
          trailing: DropdownButton<double>(
            key: const ValueKey('settings-key-height'),
            value: terminalKeyHeightChoices.containsKey(
              settings.terminalKeyHeight,
            )
                ? settings.terminalKeyHeight
                : defaultTerminalKeyHeight,
            underline: const SizedBox.shrink(),
            items: [
              for (final MapEntry(:key, :value)
                  in terminalKeyHeightChoices.entries)
                DropdownMenuItem(value: key, child: LText(value)),
            ],
            onChanged: (value) {
              if (value == null) return;
              edit((s) => s.copyWith(terminalKeyHeight: value));
            },
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const LText('方向键长按连发'),
          trailing: DropdownButton<int>(
            key: const ValueKey('settings-key-repeat'),
            value: terminalKeyRepeatChoices.containsKey(
              settings.terminalKeyRepeatMs,
            )
                ? settings.terminalKeyRepeatMs
                : defaultTerminalKeyRepeatMs,
            underline: const SizedBox.shrink(),
            items: [
              for (final MapEntry(:key, :value)
                  in terminalKeyRepeatChoices.entries)
                DropdownMenuItem(value: key, child: LText(value)),
            ],
            onChanged: (value) {
              if (value == null) return;
              edit((s) => s.copyWith(terminalKeyRepeatMs: value));
            },
          ),
        ),
        SwitchListTile(
          key: const ValueKey('settings-key-haptics'),
          contentPadding: EdgeInsets.zero,
          title: const LText('按键震动'),
          value: settings.terminalKeyHaptics,
          onChanged: (value) =>
              edit((s) => s.copyWith(terminalKeyHaptics: value)),
        ),
      ],
    );
  }
}
