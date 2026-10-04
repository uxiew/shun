import 'bindings.dart';
import 'formatter/ffi.dart';
import 'key/ffi.dart';
import 'kitty_graphics/ffi.dart';
import 'mouse/ffi.dart';
import 'parser/ffi.dart';
import 'render/ffi.dart';
import 'search/ffi.dart';
import 'selection/ffi.dart';
import 'snapshot/ffi.dart';
import 'system/ffi.dart';
import 'terminal/ffi.dart';
import 'utility/ffi.dart';

/// The eagerly initialized native binding holder.
final bindings = Bindings(
  terminal: FfiTerminalBindings(),
  key: FfiKeyBindings(),
  mouse: const FfiMouseBindings(),
  parser: const FfiParserBindings(),
  formatter: FfiFormatterBindings(),
  utility: const FfiUtilityBindings(),
  render: FfiRenderBindings(),
  snapshot: FfiSnapshotBindings(),
  selection: FfiSelectionBindings(),
  kittyGraphics: FfiKittyGraphicsBindings(),
  system: FfiSystemBindings(),
  search: const FfiSearchBindings(),
);
