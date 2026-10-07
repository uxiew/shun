import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models/settings.dart';
import '../infrastructure/storage/vault_repository.dart';

final settingsControllerProvider =
    StateNotifierProvider<SettingsController, AppSettings>((ref) {
  final controller = SettingsController(ref.watch(vaultRepositoryProvider));
  unawaited(controller.load());
  return controller;
});

class SettingsController extends StateNotifier<AppSettings> {
  SettingsController(this.repository) : super(const AppSettings());
  final VaultRepository repository;

  Future<void> load() async => state = await repository.loadSettings();

  Future<void> update(AppSettings value) async {
    final previous = state;
    state = value;
    try {
      await repository.saveSettings(value);
    } catch (_) {
      state = previous;
      rethrow;
    }
  }

  Future<void> updateTerminalSecureKeyboard(bool enabled) async {
    final persisted = await repository.loadSettings();
    await update(persisted.copyWith(terminalSecureKeyboard: enabled));
  }

  /// 立刻保存，不跟着「保存外观」走：开着的终端马上照新设置处理滑动。
  Future<void> updateTerminalFullscreenSwipe(bool enabled) async {
    final persisted = await repository.loadSettings();
    await update(persisted.copyWith(terminalFullscreenSwipe: enabled));
  }

  /// 终端下面的输入方式（系统键盘 / 按键面板 / 大输入框）。切了就存，下次打开终端照旧。
  Future<void> updateTerminalInputMode(String mode) async {
    if (!supportedTerminalInputModes.contains(mode)) return;
    if (state.terminalInputMode == mode) return;
    final persisted = await repository.loadSettings();
    await update(persisted.copyWith(terminalInputMode: mode));
  }
}
