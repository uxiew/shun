import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shun/infrastructure/plugins/rustdesk_external.dart';
import 'package:shun/infrastructure/plugins/uuremote_adapter.dart';
import '../integration_test/support/r39_fixture.dart';

void main() {
  final valid = {
    'runId': '0123456789abcdef0123456789abcdef',
    'fixtureSigner': List.filled(64, 'a').join(),
  };
  test('device fixture has a bounded, reproducible callback identity', () {
    final fixture = R39Fixture(jsonEncode(valid));
    expect(fixture.state, hasLength(22));
    expect(fixture.peer.length, lessThanOrEqualTo(16));
    expect(RustDeskPeerId.parse(fixture.peer).value, fixture.peer);
    expect(parseUuCallback(fixture.callback.toString()), isA<UuBindCallback>());
    expect(fixture.callback.queryParameters['nonce'], fixture.nonce);
    expect(fixture.callback.queryParameters['anonymous_device_id'],
        fixture.newOpaque);
    expect(fixture.oldOpaque, isNot(fixture.newOpaque));
  });
  test('device fixture refuses missing or unbounded authorization values', () {
    for (final value in [
      null,
      [],
      {},
      {...valid, 'runId': '../other'},
      {...valid, 'runId': 42},
      {...valid, 'fixtureSigner': 'a' * 63},
      {...valid, 'fixtureSigner': 'Z' * 64},
    ]) {
      expect(() => R39Fixture(jsonEncode(value)), throwsFormatException);
    }
  });
}
