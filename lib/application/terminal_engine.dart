import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../infrastructure/terminal/terminal_session_adapter.dart';
import '../infrastructure/terminal/xterm_terminal_adapter.dart';

typedef TerminalAdapterFactory = TerminalSessionAdapter Function();

/// 新标签用哪个终端引擎。现在只有旧引擎 xterm2；R17 把 Ghostty 设成默认时改这里（docs/06 E 步），
/// 连接层、会话控制器、终端页都不用跟着改。
TerminalSessionAdapter defaultTerminalAdapter() => XtermTerminalAdapter();

final terminalAdapterFactoryProvider =
    Provider<TerminalAdapterFactory>((ref) => defaultTerminalAdapter);
