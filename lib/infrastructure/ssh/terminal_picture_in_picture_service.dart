import 'dart:async';

import 'package:flutter/services.dart';

class TerminalPictureInPictureService {
  const TerminalPictureInPictureService._();

  static const _channel = MethodChannel(
    'app.netcatty.mobile/picture_in_picture',
  );
  static final _stateChanges = StreamController<bool>.broadcast();
  static var _initialized = false;
  static var _active = false;
  static int? _lastUpdateSignature;

  static bool get active => _active;
  static Stream<bool> get stateChanges {
    _initialize();
    return _stateChanges.stream;
  }

  static void _initialize() {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'stateChanged') return;
      final arguments = call.arguments;
      final active = arguments is Map && arguments['active'] == true;
      _setActive(active);
    });
  }

  static Future<bool> isSupported() async {
    _initialize();
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> enter({
    required String title,
    required String text,
    required bool connected,
    required int backgroundColor,
    required int foregroundColor,
    required int accentColor,
  }) async {
    _initialize();
    _lastUpdateSignature = Object.hash(
      title,
      text,
      connected,
      backgroundColor,
      foregroundColor,
      accentColor,
    );
    try {
      final entered = await _channel.invokeMethod<bool>('enter', {
            'title': title,
            'text': text,
            'connected': connected,
            'backgroundColor': backgroundColor,
            'foregroundColor': foregroundColor,
            'accentColor': accentColor,
            'aspectWidth': 16,
            'aspectHeight': 9,
          }) ??
          false;
      if (entered) _setActive(true);
      return entered;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> update({
    required String title,
    required String text,
    required bool connected,
    required int backgroundColor,
    required int foregroundColor,
    required int accentColor,
  }) async {
    if (!_active) return;
    final signature = Object.hash(
      title,
      text,
      connected,
      backgroundColor,
      foregroundColor,
      accentColor,
    );
    if (_lastUpdateSignature == signature) return;
    _lastUpdateSignature = signature;
    try {
      await _channel.invokeMethod<void>('update', {
        'title': title,
        'text': text,
        'connected': connected,
        'backgroundColor': backgroundColor,
        'foregroundColor': foregroundColor,
        'accentColor': accentColor,
      });
    } on MissingPluginException {
      // Picture in Picture is optional outside Android and iOS.
    } on PlatformException {
      // A stopped native PiP session may race with the final terminal update.
    }
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // No-op on unsupported platforms and in widget tests.
    } on PlatformException {
      // The system may already have dismissed Picture in Picture.
    } finally {
      _lastUpdateSignature = null;
      _setActive(false);
    }
  }

  static void _setActive(bool active) {
    if (_active == active) return;
    _active = active;
    _stateChanges.add(active);
  }
}
