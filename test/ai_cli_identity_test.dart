import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/ai_cli_identity.dart';
import 'package:shun/domain/host_identity.dart';
import 'package:shun/domain/models/host.dart';

void main() {
  HostProfile host([Map<String, Object?> extra = const {}]) => HostProfile({
        'id': 'saved-host',
        'hostname': 'example.invalid',
        'port': 22,
        'username': 'alice',
        ...extra,
      });
  Map<String, String> env(String name, String value) =>
      {'name': name, 'value': value};
  test('legacy identity and temporary host ancestry remain compatible', () {
    expect(
        aiCliHostScope(host()), '["saved-host","example.invalid",22,"alice"]');
    expect(
        aiCliHostScope(
            host({'id': 'temporary-tab', sourceHostIdKey: 'saved-host'})),
        aiCliHostScope(host()));
    expect(aiCliHostScope(host({'label': 'renamed', 'password': 'rotated'})),
        aiCliHostScope(host()));
    for (final changed in [
      {'id': 'other'},
      {'hostname': 'other.invalid'},
      {'port': 2222},
      {'username': 'bob'}
    ]) {
      expect(aiCliHostScope(host(changed)), isNot(aiCliHostScope(host())));
    }
  });
  test('environment uses effective values independent of order and hides them',
      () {
    final first = aiCliHostScope(host({
      'environmentVariables': [env('B', 'secret'), env('A', 'one')]
    }));
    expect(
        aiCliHostScope(host({
          'environmentVariables': [
            env('A', 'overridden'),
            env('B', 'secret'),
            env('A', 'one')
          ]
        })),
        first);
    expect(first, isNot(contains('secret')));
    expect(
        aiCliHostScope(host({
          'environmentVariables': [env('B', 'secret'), env('A', 'two')]
        })),
        isNot(first));
    expect(aiCliHostScope(host({'environmentVariables': []})),
        aiCliHostScope(host()));
  });
}
