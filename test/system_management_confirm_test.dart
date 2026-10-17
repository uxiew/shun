import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/models/system_management.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/ssh/system_management_service.dart';
import 'package:shun/infrastructure/terminal/ghostty_terminal_adapter.dart';
import 'package:shun/presentation/widgets/system_management/service_manager_panel.dart';

void main() {
  testWidgets('停止、重启服务先确认：取消什么都不发，启动不问', (tester) async {
    final session = ActiveTerminalSession(
      id: 'confirm-test',
      host: HostProfile({
        'id': 'confirm-test',
        'hostname': 'example.invalid',
        'username': 'tester',
      }),
      terminal: GhosttyTerminalAdapter(),
      verifyHostKey: (_, __, ___) async => true,
      keyboardInteractive: null,
    );
    addTearDown(session.close);
    final service = _FakeServiceManager();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ServiceManagerPanel(session: session, service: service),
      ),
    ));
    await tester.pumpAndSettle();

    // 服务卡片默认收着，点名字展开才有按钮。
    await tester.tap(find.text('ssh.service'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('停止'));
    await tester.pumpAndSettle();
    expect(find.text('停止服务？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(service.actions, isEmpty);

    await tester.tap(find.byTooltip('重启').first);
    await tester.pumpAndSettle();
    expect(find.text('重启服务？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '重启'));
    await tester.pumpAndSettle();
    expect(service.actions, [('ssh.service', RemoteServiceAction.restart)]);

    await tester.tap(find.text('cron.service'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('启动'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(service.actions.last, ('cron.service', RemoteServiceAction.start));
  });
}

class _FakeServiceManager extends SystemManagementService {
  final actions = <(String, RemoteServiceAction)>[];

  @override
  Future<ServiceManager> detectServiceManager(
    ActiveTerminalSession session,
  ) async =>
      ServiceManager.systemd;

  @override
  Future<List<RemoteService>> listServices(
    ActiveTerminalSession session,
  ) async =>
      const [
        RemoteService(
          name: 'ssh.service',
          description: '',
          state: RemoteServiceState.running,
          enabled: false,
          manager: ServiceManager.systemd,
        ),
        RemoteService(
          name: 'cron.service',
          description: '',
          state: RemoteServiceState.stopped,
          enabled: true,
          manager: ServiceManager.systemd,
        ),
      ];

  @override
  Future<void> serviceAction(
    ActiveTerminalSession session,
    RemoteService service,
    RemoteServiceAction action,
  ) async {
    actions.add((service.name, action));
  }
}
