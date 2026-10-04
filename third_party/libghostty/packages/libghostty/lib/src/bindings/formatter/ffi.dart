import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../../generated/libghostty.g.dart' hide String;
import '../../generated/libghostty_enums.g.dart';
import '../../types/types.dart';
import '../result_helpers.dart';
import '../types.dart';
import 'formatter.dart';

final class FfiFormatterBindings implements FormatterBindings {
  var _formatBuffer = calloc<Uint8>(4096);
  var _formatBufferCapacity = 4096;
  final _written = calloc<Size>();

  FfiFormatterBindings();

  @override
  String formatterFormat(LibGhosttyHandle formatter) {
    var result = ghostty_formatter_format_buf(
      Pointer.fromAddress(formatter.value),
      _formatBuffer,
      _formatBufferCapacity,
      _written,
    );
    if (result == .outOfSpace) {
      _growFormatBuffer(_written.value);
      result = ghostty_formatter_format_buf(
        Pointer.fromAddress(formatter.value),
        _formatBuffer,
        _formatBufferCapacity,
        _written,
      );
    }
    checkResultCode(result.value, operation: 'ghostty_formatter_format_buf');
    final length = _written.value;
    return length == 0 ? '' : utf8.decode(_formatBuffer.asTypedList(length));
  }

  @override
  void formatterFree(LibGhosttyHandle formatter) {
    ghostty_formatter_free(Pointer.fromAddress(formatter.value));
  }

  @override
  LibGhosttyHandle formatterTerminalNew(
    LibGhosttyHandle terminal,
    FormatterFormat format, {
    bool unwrap = false,
    bool trim = false,
    FormatterExtra extra = const FormatterExtra(),
    RawSelection? selection,
  }) {
    return using((arena) {
      final out = arena<Pointer<FormatterImpl>>();
      final options = arena<FormatterTerminalOptions>();
      options.ref
        ..size = sizeOf<FormatterTerminalOptions>()
        ..emitAsInt = format.value
        ..unwrap = unwrap
        ..trim = trim;
      options.ref.extra
        ..size = sizeOf<FormatterTerminalExtra>()
        ..palette = extra.palette
        ..modes = extra.modes
        ..scrolling_region = extra.scrollingRegion
        ..tabstops = extra.tabstops
        ..pwd = extra.pwd
        ..keyboard = extra.keyboard;
      options.ref.extra.screen
        ..size = sizeOf<FormatterScreenExtra>()
        ..cursor = extra.cursor
        ..style = extra.style
        ..hyperlink = extra.hyperlink
        ..protection = extra.protection
        ..kitty_keyboard = extra.kittyKeyboard
        ..charsets = extra.charsets;

      if (selection == null) {
        options.ref.selection = nullptr;
      } else {
        final selected = arena<Selection>();
        _writeSelection(selected.ref, selection);
        options.ref.selection = selected;
      }

      final result = ghostty_formatter_terminal_new(
        nullptr,
        out,
        Pointer.fromAddress(terminal.value),
        options.ref,
      );
      checkResultCode(
        result.value,
        operation: 'ghostty_formatter_terminal_new',
      );
      return .fromAddress(out.value.address);
    });
  }

  void _growFormatBuffer(int required) {
    if (required <= _formatBufferCapacity) return;
    final replacement = calloc<Uint8>(required);
    calloc.free(_formatBuffer);
    _formatBuffer = replacement;
    _formatBufferCapacity = required;
  }

  static void _writeGridRef(GridRef target, RawGridRef value) {
    target
      ..size = sizeOf<GridRef>()
      ..node = Pointer<Void>.fromAddress(value.node)
      ..x = value.x
      ..y = value.y;
  }

  static void _writeSelection(Selection target, RawSelection selection) {
    target
      ..size = sizeOf<Selection>()
      ..rectangle = selection.rectangle;
    _writeGridRef(target.start, selection.start);
    _writeGridRef(target.end, selection.end);
  }
}
