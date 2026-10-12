import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../domain/ai_cli_launch.dart';

enum _State { waiting, confirmed, failed }

/// Owns only the launch prelude protocol, not the SSH transport or terminal.
/// Removes one confirmation marker across arbitrary packet splits, preserves
/// all other bytes, and drops late output after failure. The caller owns the
/// deadline/cancellation and must call [fail] before releasing its streams.
class AiCliLaunchHandshake {
  AiCliLaunchHandshake({required this.onConfirmed, required this.onOutput});

  static const maxPreludeBytes = 8192;
  final void Function() onConfirmed;
  final void Function(Uint8List) onOutput;
  final _ready = Completer<void>();
  final _prelude = BytesBuilder(copy: false);
  var _state = _State.waiting;

  Future<void> get ready => _ready.future;

  void add(Uint8List bytes) {
    if (_state == _State.failed) return;
    if (_state == _State.confirmed) {
      onOutput(bytes);
      return;
    }
    _prelude.add(bytes);
    final raw = _prelude.toBytes();
    final index = latin1.decode(raw).indexOf(AiCliLaunchSpec.readyMarker);
    final end = index + AiCliLaunchSpec.readyMarker.length;
    // Limit the prelude including the marker, not the following CLI output.
    // A marker after an oversized banner must not bypass the bound.
    if ((index >= 0 && end > maxPreludeBytes) ||
        (index < 0 && raw.length > maxPreludeBytes)) {
      fail();
      return;
    }
    if (index < 0) return;
    _prelude.clear();
    _state = _State.confirmed;
    onConfirmed();
    _ready.complete();
    if (index > 0) onOutput(Uint8List.sublistView(raw, 0, index));
    if (end < raw.length) onOutput(Uint8List.sublistView(raw, end));
  }

  /// Only these wrapper exits, before confirmation, prove preflight rejection.
  /// CLI exit codes after confirmation never reclassify a successful handshake.
  void finish(int? exitCode) => fail(exitCode == 125 || exitCode == 126
      ? AiCliLaunchRejectedException(exitCode!)
      : const AiCliLaunchUnknownException());

  void fail([Object error = const AiCliLaunchUnknownException()]) {
    if (_state != _State.waiting) return;
    _state = _State.failed;
    _prelude.clear();
    _ready.completeError(error);
  }
}
