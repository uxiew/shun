import 'package:flutter/material.dart';
import 'package:shun/presentation/localization/localized_widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../application/port_forward_controller.dart';
import '../../application/session_controller.dart';
import '../../infrastructure/ssh/ssh_service.dart';
import '../ui/components.dart';
import 'choice_segments.dart';
import 'form_gap.dart';

class PortForwardSheet extends ConsumerStatefulWidget {
  const PortForwardSheet({super.key, required this.session});
  final ActiveTerminalSession session;

  @override
  ConsumerState<PortForwardSheet> createState() => _PortForwardSheetState();
}

class _PortForwardSheetState extends ConsumerState<PortForwardSheet> {
  final localPort = TextEditingController(text: '8080');
  final remoteHost = TextEditingController(text: '127.0.0.1');
  final remotePort = TextEditingController(text: '80');
  var kind = ForwardKind.local;
  var busy = false;
  String? startError;

  @override
  void dispose() {
    localPort.dispose();
    remoteHost.dispose();
    remotePort.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final forwards = ref.watch(portForwardControllerProvider);
    // 标签断线、恢复成新连接时会话列表会变：跟着重画，面板开着时断了也能马上变成不可用。
    ref.watch(sessionControllerProvider);
    final client = widget.session.sshClient;
    final live = widget.session.connected && client != null && !client.isClosed;
    final running = forwards.where((item) => item.running).toList();
    final stopped = forwards.where((item) => !item.running).toList();
    return Padding(
      key: const ValueKey('port-forward-sheet'),
      padding: EdgeInsets.fromLTRB(
        16,
        18,
        16,
        MediaQuery.viewInsetsOf(context).bottom + 18,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Semantics(
                  header: true,
                  child: LText('端口转发',
                      style: prism.AppTextStyle.title2
                          .of(context, emphasized: true)),
                ),
                ShunPill(localizedOf(context, widget.session.host.label)),
              ],
            ),
            if (!live) ...[
              const SizedBox(height: 10),
              LText(
                key: const ValueKey('port-forward-disconnected'),
                '连接已断开，开不了新转发。重新连接后再从新连接打开。',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 12),
            ChoiceSegments<ForwardKind>(
              segments: const [
                ChoiceSegment(ForwardKind.local, '本地转发',
                    key: ValueKey('port-forward-local')),
                ChoiceSegment(ForwardKind.dynamic, 'SOCKS5',
                    key: ValueKey('port-forward-dynamic')),
              ],
              selected: kind,
              onTap: (value) => setState(() => kind = value),
            ),
            ShunSection(children: [
              ShunSectionItem(
                child: Column(children: [
                  TextField(
                    key: const ValueKey('port-forward-local-port'),
                    controller: localPort,
                    keyboardType: TextInputType.number,
                    decoration: LInputDecoration(labelText: '本地端口（0 为自动）'),
                  ),
                  if (kind == ForwardKind.local) ...[
                    const FormGap(),
                    Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: TextField(
                            key: const ValueKey('port-forward-remote-host'),
                            controller: remoteHost,
                            decoration: LInputDecoration(labelText: '远端主机'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            key: const ValueKey('port-forward-remote-port'),
                            controller: remotePort,
                            keyboardType: TextInputType.number,
                            decoration: LInputDecoration(labelText: '端口'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ]),
              ),
            ]),
            const SizedBox(height: 12),
            if (startError != null) ...[
              Semantics(
                liveRegion: true,
                child: LText(startError!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
              const SizedBox(height: 8),
            ],
            SizedBox(
              width: double.infinity,
              child: ShunButton(
                key: const ValueKey('port-forward-start'),
                onPressed: live ? _start : null,
                busy: busy,
                icon: Icons.play_arrow,
                label: '启动',
              ),
            ),
            if (running.isNotEmpty)
              ShunSection(title: '运行中', children: running.map(_row).toList()),
            if (stopped.isNotEmpty)
              ShunSection(title: '已停止', children: stopped.map(_row).toList()),
          ],
        ),
      ),
    );
  }

  Widget _row(ActivePortForward item) {
    final running = item.running;
    final subtitle = [
      if (item.hostLabel != null) item.hostLabel!,
      if (item.endedReason != null) localized(item.endedReason!),
    ].join(' · ');
    // 只有行尾能停止或去除；无动作的卡片不能是一个「不可用的按钮」。
    return ShunSectionItem(
      key: ValueKey(
          'port-forward-${running ? 'running' : 'stopped'}-${item.id}'),
      padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
      child: Row(children: [
        Icon(
          running ? Icons.swap_horiz : Icons.link_off,
          color: running
              ? prism.Theme.of(context).colorScheme.success
              : prism.Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LText(item.describe()),
              if (subtitle.isNotEmpty)
                LText(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        ShunBarButton(
          key: ValueKey(
              'port-forward-${running ? 'stop' : 'remove'}-${item.id}'),
          tooltip: localized(running ? '停止' : '从列表里去掉'),
          icon: running ? Icons.stop_circle_outlined : Icons.clear,
          onPressed: () =>
              ref.read(portForwardControllerProvider.notifier).stop(item.id),
        ),
      ]),
    );
  }

  Future<void> _start() async {
    if (busy) return;
    setState(() {
      busy = true;
      startError = null;
    });
    String? failure;
    try {
      final controller = ref.read(portForwardControllerProvider.notifier);
      if (kind == ForwardKind.local) {
        await controller.startLocal(
          session: widget.session,
          localPort: int.tryParse(localPort.text) ?? 0,
          remoteHost: remoteHost.text.trim(),
          remotePort: int.tryParse(remotePort.text) ?? 80,
        );
      } else {
        await controller.startDynamic(
          session: widget.session,
          localPort: int.tryParse(localPort.text) ?? 0,
        );
      }
    } catch (error) {
      failure = '$error';
    }
    if (!mounted) return;
    setState(() {
      busy = false;
      startError = failure;
    });
  }
}
