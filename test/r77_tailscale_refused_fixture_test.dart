import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/connection_diagnosis.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/tailscale_ssh.dart';
import 'package:shun/infrastructure/ssh/ssh_login_watch.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';

import 'fixtures/docker_fixture.dart';

// R77 / UXR06：「没开 Tailscale SSH」的判断靠普通 sshd 的回复方式，这里拿真 OpenSSH 验。
// 单测的假客户端只能证明分支写对了，证明不了 sshd 真这么回。
// 依赖 tool/fixture-environment，没起 fixture 时 skip。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = DockerFixture.load();
  final skip = fixture == null ? DockerFixture.skipReason : false;

  test('主机选了 Tailscale SSH、服务器是普通 sshd：说没开，给命令', () async {
    final host = HostProfile({
      'id': 'edge',
      'label': 'edge',
      'hostname': fixture!.edgeHost,
      'port': fixture.edgePort,
      'username': fixture.user,
      'protocol': 'ssh',
      sshLoginModeKey: 'tailscale',
    });
    Object? error;
    try {
      final session = await SshService().connect(
        terminal: GhosttyTerminalAdapter(),
        sessionId: 'r77',
        host: host,
        hosts: [host],
        verifyHostKey: (_, __, fingerprint) async =>
            fingerprint == fixture.edgeFingerprint,
      );
      await session.close();
    } catch (e) {
      error = e;
    }
    expect(error, isNotNull, reason: '普通 sshd 不该放行 none');
    final cause = error is RouteHopException ? error.cause : error;
    expect(cause, isA<TailscaleLoginDenied>());
    expect((cause! as TailscaleLoginDenied).refusedNone, isTrue);
    final fix = tailscaleFix(host, error!);
    expect(fix?.text, contains('没开 Tailscale SSH'));
    expect(fix?.command, 'sudo tailscale set --ssh');
    expect(fix?.openApp, isFalse);
  }, skip: skip);
}
