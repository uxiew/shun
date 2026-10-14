import 'dart:convert';

/// Synthetic values only. A per-run token prevents a stale APK from touching
/// another run's data; the host must also authorize this token in app storage.
class R39Fixture {
  R39Fixture(String raw) {
    final value = jsonDecode(raw);
    if (value is! Map ||
        value['runId'] is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(value['runId'] as String) ||
        value['fixtureSigner'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(value['fixtureSigner'] as String)) {
      throw const FormatException('Invalid R39 fixture configuration');
    }
    runId = value['runId'] as String;
    fixtureSigner = value['fixtureSigner'] as String;
  }

  late final String runId;
  late final String fixtureSigner;
  static const owner = 'r39-legacy-host';
  static const link = 'r39-rd-link';
  static const binding = 'r39-uu-binding';
  static const catalog = 'r39-catalog';
  static const device = 'r39-device';
  String get peer => 'r39-${runId.substring(0, 10)}';
  String get oldOpaque => 'r39-old-$runId';
  String get newOpaque => 'r39-new-$runId';
  String get nonce => 'r39-$runId';
  String get state => base64Url.encode([
        for (var i = 0; i < runId.length; i += 2)
          int.parse(runId.substring(i, i + 2), radix: 16),
      ]).replaceAll('=', '');
  Uri get callback => Uri(
        scheme: 'shun-uuremote',
        host: 'callback',
        path: '/bind',
        queryParameters: {
          'state': state,
          'nonce': nonce,
          'anonymous_device_id': newOpaque,
        },
      );
  List<String> get sensitiveValues =>
      [peer, oldOpaque, newOpaque, nonce, state];
}
