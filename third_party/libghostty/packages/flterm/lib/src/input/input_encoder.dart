import 'package:libghostty/libghostty.dart';

import '../foundation.dart';
import 'input_message.dart';

/// Owns the reusable terminal resources that encode normalized input.
///
/// It translates renderer-neutral key and pointer values into terminal bytes
/// without owning Flutter focus, gesture, or text-input lifecycle. Reusing the
/// native events and encoders avoids allocations on input hot paths.
final class InputEncoder {
  final Terminal _terminal;
  final _keyEvent = KeyEvent();
  final _mouseEvent = MouseEvent();
  final _keyEncoder = KeyEncoder();
  final _mouseEncoder = MouseEncoder();

  InputEncoder(this._terminal);

  void dispose() {
    _keyEvent.dispose();
    _mouseEvent.dispose();
    _keyEncoder.dispose();
    _mouseEncoder.dispose();
  }

  String encodeKey(KeyInput input) {
    if (!input.composing && input.action != .release) {
      if (_legacyControlSequence(input.key, input.mods) case final sequence?) {
        return sequence;
      }
    }
    _keyEvent
      ..key = input.key
      ..mods = input.mods
      ..action = input.action
      ..utf8 = input.character
      ..composing = input.composing
      ..consumedMods = input.consumedMods
      ..unshiftedCodepoint = input.unshiftedCodepoint;
    return _encodeKeyEvent();
  }

  String encodeKeyPress(Key key, {required Mods mods}) {
    if (_legacyControlSequence(key, mods) case final sequence?) return sequence;
    final codepoint = unshiftedCodepointForKey(key);
    _keyEvent
      ..key = key
      ..mods = mods
      ..action = .press
      ..consumedMods = const .none()
      ..unshiftedCodepoint = codepoint
      ..utf8 = codepoint > 0 ? String.fromCharCode(codepoint) : null
      ..composing = false;
    return _encodeKeyEvent();
  }

  String encodeMouse(MouseInput input, {required SurfaceGeometry? geometry}) {
    _mouseEvent
      ..action = input.action
      ..mods = input.mods;
    _setMousePosition(input.pixelX, input.pixelY, geometry);
    if (input.button case final button?) {
      _mouseEvent.button = button;
    } else {
      _mouseEvent.clearButton();
    }
    _mouseEncoder.sync(_terminal);
    _mouseEncoder.setAnyButtonPressed(pressed: input.anyButtonPressed);
    return _mouseEncoder.encode(_mouseEvent);
  }

  String encodeScrollButton(
    ScrollInput input, {
    required MouseButton button,
    required SurfaceGeometry? geometry,
  }) {
    var x = input.pixelX;
    var y = input.pixelY;
    if (geometry != null) {
      final width = geometry.cols * geometry.cellWidth;
      final height = geometry.rows * geometry.cellHeight;
      final edge = 1 / geometry.devicePixelRatio;
      x = x.clamp(0.0, width > edge ? width - edge : 0.0);
      y = y.clamp(0.0, height > edge ? height - edge : 0.0);
    }
    _mouseEvent
      ..action = .press
      ..button = button
      ..mods = input.mods;
    _setMousePosition(x, y, geometry);
    _mouseEncoder.sync(_terminal);
    _mouseEncoder.setAnyButtonPressed(pressed: false);
    return _mouseEncoder.encode(_mouseEvent);
  }

  void updateGeometry(SurfaceGeometry geometry) {
    _mouseEncoder.setSize(
      MouseEncoderSize(
        screenWidth: geometry.screenWidth,
        screenHeight: geometry.screenHeight,
        cellWidth: geometry.cellWidthPx,
        cellHeight: geometry.cellHeightPx,
        paddingLeft: geometry.paddingLeftPx,
        paddingRight: geometry.paddingRightPx,
        paddingTop: geometry.paddingTopPx,
        paddingBottom: geometry.paddingBottomPx,
      ),
    );
  }

  /// xwshun: Ctrl+I、Ctrl+M、Ctrl+[ 在传统键盘编码下发 Tab、回车、ESC，和 xterm、xterm2 一样。
  ///
  /// Ghostty 照 fixterms 故意把这三个编成 CSI u（Ctrl+I 是 `ESC [ 105 ; 5 u`），没开扩展键盘协议的
  /// bash、vim 不认，屏幕上冒出 `5u`；Android 硬件键盘的按键事件又不带字符，连 CSI u 那条路都进不去，
  /// 实测什么都不发（R19）。远端开了 kitty 键盘协议时照 Ghostty 原样编：那时程序要的正是分清 Ctrl+I 和 Tab。
  /// Shift、Super 一起按着的不管（Ghostty 本来就编成 CSI u，好让程序分清 Ctrl+Shift+M）；Alt 按着时
  /// 和 Ghostty 别的 Ctrl 组合一样前面加 ESC。
  String? _legacyControlSequence(Key key, Mods mods) {
    if (!mods.hasCtrl || mods.hasShift || mods.hasSuper) return null;
    final control = switch (key) {
      .i => '\t',
      .m => '\r',
      .bracketLeft => '\x1b',
      _ => null,
    };
    if (control == null || !_terminal.kittyKeyboardFlags.isDisabled) {
      return null;
    }
    return mods.hasAlt ? '\x1b$control' : control;
  }

  String _encodeKeyEvent() {
    _keyEncoder.sync(_terminal);
    return _keyEncoder.encode(_keyEvent);
  }

  void _setMousePosition(double x, double y, SurfaceGeometry? geometry) {
    if (geometry == null) {
      _mouseEvent.setPosition(x: x, y: y);
      return;
    }
    _mouseEvent.setPosition(
      x: x * geometry.devicePixelRatio + geometry.paddingLeftPx,
      y: y * geometry.devicePixelRatio + geometry.paddingTopPx,
    );
  }
}
