import 'dart:io';

import 'package:dart_mosh/dart_mosh.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosh_dart_probe/fixture.dart';
import 'package:mosh_dart_probe/screen.dart';
import 'package:mosh_dart_probe/udp_relay.dart';

void main() {
  final fixture = MoshFixture.tryLoad();
  final skip = fixture == null ? '没起 ../up.sh' : null;

  test('dart_mosh 和真 mosh-server 1.4.0 能连上、看到输出', () async {
    final out = await fixture!.startServer('printf "hello-%s\\n" mosh; sleep 30');
    final server = MoshServerConfig.parse(out, host: '127.0.0.1');
    final session = await MoshSession.connect(
      server: server,
      cipher: MoshPacketCipher.aesOcb(server.key),
      address: InternetAddress.loopbackIPv4,
      columns: 80,
      rows: 24,
    );
    final screen = Screen(80, 24);
    session.stdout.listen(screen.feed);
    final ok = await waitFor(() => screen.text().contains('hello-mosh'));
    await session.close();
    await fixture.killAllServers();
    expect(ok, isTrue, reason: screen.text());
  }, skip: skip);
}
