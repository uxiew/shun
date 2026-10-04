import 'ffi.dart' if (dart.library.js_interop) 'wasm.dart' as platform;
import 'formatter/formatter.dart';
import 'key/key.dart';
import 'kitty_graphics/kitty_graphics.dart';
import 'mouse/mouse.dart';
import 'parser/parser.dart';
import 'render/render.dart';
import 'search/search.dart';
import 'selection/selection.dart';
import 'snapshot/snapshot.dart';
import 'system/sys.dart';
import 'terminal/terminal.dart';
import 'utility/utility.dart';

export 'wasm/bootstrap.dart'
    if (dart.library.ffi) 'wasm/bootstrap_stub.dart'
    show initializeForWeb;

/// The bindings for the active platform.
Bindings get bindings => platform.bindings;

/// The focused platform bindings used by the public resource wrappers.
///
/// This class only composes module adapters. It does not forward behavior or
/// expose generated declarations.
final class Bindings {
  /// Terminal and terminal-owned operations.
  final TerminalBindings terminal;

  /// Keyboard event and encoder operations.
  final KeyBindings key;

  /// Mouse event and encoder operations.
  final MouseBindings mouse;

  /// OSC and SGR parser operations.
  final ParserBindings parser;

  /// Formatter operations.
  final FormatterBindings formatter;

  /// Stateless utility operations.
  final UtilityBindings utility;

  /// Render-state, row, cell, and grid-reference operations.
  final RenderBindings render;

  /// Terminal snapshot encoding and restoration operations.
  final SnapshotBindings snapshot;

  /// Selection and gesture operations.
  final SelectionBindings selection;

  /// Kitty graphics operations.
  final KittyGraphicsBindings kittyGraphics;

  /// Process-global system operations.
  final SystemBindings system;

  /// Terminal search operations.
  final SearchBindings search;

  const Bindings({
    required this.terminal,
    required this.key,
    required this.mouse,
    required this.parser,
    required this.formatter,
    required this.utility,
    required this.render,
    required this.snapshot,
    required this.selection,
    required this.kittyGraphics,
    required this.system,
    required this.search,
  });
}
