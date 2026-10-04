import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models/settings.dart';
import '../infrastructure/terminal/ghostty_terminal_adapter.dart';
import '../infrastructure/terminal/terminal_session_adapter.dart';
import '../infrastructure/terminal/xterm_terminal_adapter.dart';
import 'settings_controller.dart';

typedef TerminalAdapterFactory = TerminalSessionAdapter Function();

/// 默认引擎的名字（和 xterm2 适配器的 engine 一致）。终端标签只给非默认引擎标名字。
const defaultTerminalEngineName = 'xterm2';

/// 按设置里的引擎建一个终端。Ghostty 建不起来时抛 [TerminalEngineUnavailableException]，
/// 不偷偷换成 xterm2：用户以为自己在用 Ghostty，出了问题却查不到（docs/06：UI 显示实际引擎与错误）。
TerminalSessionAdapter newTerminalAdapter(String engine) => switch (engine) {
      terminalEngineGhostty => GhosttyTerminalAdapter(),
      _ => XtermTerminalAdapter(),
    };

TerminalSessionAdapter defaultTerminalAdapter() =>
    newTerminalAdapter(const AppSettings().terminalEngine);

/// 新标签用哪个终端引擎。每次建终端时才读设置，所以改了设置只影响之后新开的终端；
/// provider 本身不 watch 设置，改设置不会让会话控制器重建、把开着的会话都关掉。
final terminalAdapterFactoryProvider = Provider<TerminalAdapterFactory>(
  (ref) => () =>
      newTerminalAdapter(ref.read(settingsControllerProvider).terminalEngine),
);
