import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/models/system_management.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/ssh/system_management_service.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:shun/presentation/widgets/system_management/sudo_prompt.dart';

/// 按命令开头给结果的假服务器：记下每条发出去的命令和 stdin。
class _FakeServer {
  final sent = <(String, String?)>[];
  bool sudoNeedsPassword = false;

  Future<({String stdout, String stderr, int? exitCode})> run(
    ActiveTerminalSession session,
    String command,
    String? stdinText,
  ) async {
    sent.add((command, stdinText));
    if (command.startsWith('sudo -n ')) {
      return sudoNeedsPassword
          ? (stdout: '', stderr: 'sudo: a password is required', exitCode: 1)
          : (stdout: '', stderr: '', exitCode: 0);
    }
    if (command.startsWith('sudo -S ')) {
      return stdinText == 'right\n'
          ? (stdout: '', stderr: '', exitCode: 0)
          : (stdout: '', stderr: 'Sorry, try again.', exitCode: 1);
    }
    if (command.startsWith('docker ')) {
      return (
        stdout: '',
        stderr: 'permission denied while trying to connect to the Docker '
            'daemon socket at unix:///var/run/docker.sock',
        exitCode: 1,
      );
    }
    return (
      stdout: '',
      stderr: 'Failed to restart nginx.service: Access denied',
      exitCode: 1,
    );
  }

  bool get sentSudo => sent.any((value) => value.$1.contains('sudo'));
}

const _nginx = RemoteService(
  name: 'nginx.service',
  description: '',
  state: RemoteServiceState.running,
  enabled: true,
  manager: ServiceManager.systemd,
);

void main() {
  late _FakeServer server;
  late SystemManagementService service;
  late ActiveTerminalSession session;

  setUp(() {
    server = _FakeServer();
    service = SystemManagementService(runCommand: server.run);
    session = ActiveTerminalSession(
      id: 'sudo-test',
      host: HostProfile({
        'id': 'sudo-test',
        'hostname': 'example.invalid',
        'username': 'tester',
      }),
      terminal: GhosttyTerminalAdapter(),
      verifyHostKey: (_, __, ___) async => true,
      keyboardInteractive: null,
    );
  });
  tearDown(() => session.close());

  test('权限不够时不自己试 sudo，先问用户', () async {
    await expectLater(
      service.serviceAction(session, _nginx, RemoteServiceAction.restart),
      throwsA(isA<ServiceSudoPasswordRequired>()
          .having((e) => e.passwordOptional, 'passwordOptional', isTrue)),
    );
    await expectLater(
      service.listDockerContainers(session),
      throwsA(isA<DockerSudoPasswordRequired>()
          .having((e) => e.passwordOptional, 'passwordOptional', isTrue)),
    );
    await expectLater(
      service.listCaddySites(
        session,
        const CaddyStatus(installed: true, configPath: '/etc/caddy/Caddyfile'),
      ),
      throwsA(isA<CaddySudoPasswordRequired>()
          .having((e) => e.passwordOptional, 'passwordOptional', isTrue)),
    );
    expect(server.sentSudo, isFalse, reason: '${server.sent}');
  });

  test('用户同意且没填密码：试 sudo -n', () async {
    await expectLater(
      service.serviceAction(session, _nginx, RemoteServiceAction.restart),
      throwsA(isA<ServiceSudoPasswordRequired>()),
    );
    service.setServiceSudoPassword(session, '');
    await service.serviceAction(session, _nginx, RemoteServiceAction.restart);
    expect(server.sent.last, ('sudo -n systemctl restart nginx.service', null));
  });

  test('免密 sudo 不行：再要密码，密码从 stdin 交给 sudo -S', () async {
    server.sudoNeedsPassword = true;
    service.setServiceSudoPassword(session, '');
    await expectLater(
      service.serviceAction(session, _nginx, RemoteServiceAction.restart),
      throwsA(isA<ServiceSudoPasswordRequired>()
          .having((e) => e.passwordOptional, 'passwordOptional', isFalse)),
    );
    service.setServiceSudoPassword(session, 'right');
    await service.serviceAction(session, _nginx, RemoteServiceAction.restart);
    expect(
      server.sent.last,
      ("sudo -S -p '' systemctl restart nginx.service", 'right\n'),
    );
  });

  test('同意只管自己那一处：同意了系统服务用 sudo，Docker 还是要问', () async {
    service.setServiceSudoPassword(session, '');
    await expectLater(
      service.listDockerContainers(session),
      throwsA(isA<DockerSudoPasswordRequired>()
          .having((e) => e.passwordOptional, 'passwordOptional', isTrue)),
    );
    expect(server.sentSudo, isFalse, reason: '${server.sent}');
  });

  Future<BuildContext> pumpContext(WidgetTester tester) async {
    late BuildContext captured;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        captured = context;
        return const SizedBox();
      }),
    ));
    return captured;
  }

  testWidgets('确认框：第一次密码可留空，点「用 sudo 继续」才重试', (tester) async {
    final context = await pumpContext(tester);
    final granted = <String>[];
    var calls = 0;
    final result = runWithSudo(
      context,
      () async {
        if (calls++ == 0) {
          throw const ServiceSudoPasswordRequired('要用 sudo 再试吗？',
              passwordOptional: true);
        }
        return 'done';
      },
      granted.add,
    );
    await tester.pumpAndSettle();
    expect(find.text('用 sudo 再试？'), findsOneWidget);
    expect(calls, 1);
    await tester.tap(find.byKey(const ValueKey('sudo-continue')));
    await tester.pumpAndSettle();
    expect(await result, 'done');
    expect(granted, ['']);
    expect(calls, 2);
  });

  testWidgets('确认框：要密码时空着点不动；取消抛 SudoDeclined，不重试', (tester) async {
    final context = await pumpContext(tester);
    final granted = <String>[];
    var calls = 0;
    Object? failure;
    final result = () async {
      try {
        await runWithSudo<void>(
          context,
          () async {
            calls++;
            throw const DockerSudoPasswordRequired('sudo 需要密码');
          },
          granted.add,
        );
      } on SudoDeclined catch (error) {
        failure = error;
      }
    }();
    await tester.pumpAndSettle();
    expect(find.text('需要 sudo 密码'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sudo-continue')));
    await tester.pumpAndSettle();
    expect(find.text('需要 sudo 密码'), findsOneWidget, reason: '没填密码不关框');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await result;
    expect(failure, isA<SudoDeclined>());
    expect(granted, isEmpty);
    expect(calls, 1);
  });
}
