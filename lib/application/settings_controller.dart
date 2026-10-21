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

  /// 一次改一项就存（R25 起设置页没有「保存」按钮）。以存盘的为底再改，不拿内存里可能还没
  /// 加载完的 [state] 去盖。按先后顺序一条一条存：两个开关点得快时，并发的话后存的那条
  /// 读到的是前一条存之前的文件，会把前一条改的盖回去。存失败时 [state] 退回原样并抛出。
  Future<void> edit(AppSettings Function(AppSettings persisted) change) {
    final next = _edits.then((_) async {
      final persisted = await repository.loadSettings();
      await update(change(persisted));
    });
    // 前一条失败不拦着后一条；失败只交给调用的人。
    _edits = next.catchError((_) {});
    return next;
  }

  var _edits = Future<void>.value();

  Future<void> updateTerminalSecureKeyboard(bool enabled) =>
      edit((s) => s.copyWith(terminalSecureKeyboard: enabled));

  /// 开着的终端马上照新设置处理滑动。
  Future<void> updateTerminalFullscreenSwipe(bool enabled) =>
      edit((s) => s.copyWith(terminalFullscreenSwipe: enabled));

  /// 开着的敏感页面马上按新设置加上或去掉防截屏（R44）。
  Future<void> updateAllowSensitiveScreenshots(bool allowed) =>
      edit((s) => s.copyWith(allowSensitiveScreenshots: allowed));

  /// 终端下面的输入方式（系统键盘 / 按键面板 / 大输入框）。切了就存，下次打开终端照旧。
  Future<void> updateTerminalInputMode(String mode) async {
    if (!supportedTerminalInputModes.contains(mode)) return;
    if (state.terminalInputMode == mode) return;
    await edit((s) => s.copyWith(terminalInputMode: mode));
  }
}
