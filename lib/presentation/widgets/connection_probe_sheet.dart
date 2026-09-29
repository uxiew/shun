import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/connection_diagnosis.dart';
import '../../application/session_controller.dart';
import '../../domain/connection_route.dart';
import '../../domain/models/host.dart';
import '../../infrastructure/ssh/ssh_service.dart';
import '../localization/localized_widgets.dart';
import 'route_legs_view.dart';

/// 测试连接：按编辑器里当前（可能还没保存）的配置，走一遍和正式连接完全相同的路线和指纹核对，
/// 逐段显示走到了哪一步；登录后只检查远端终端（PTY），不打开 shell、不执行启动命令（R10）。
class ConnectionProbeSheet extends ConsumerStatefulWidget {
  const ConnectionProbeSheet({
    super.key,
    required this.host,
    required this.plan,
    required this.verifyHostKey,
    this.keyboardInteractive,
  });

  final HostProfile host;
  final RoutePlan plan;
  final HostKeyVerifier verifyHostKey;
  final KeyboardInteractiveHandler? keyboardInteractive;

  @override
  ConsumerState<ConnectionProbeSheet> createState() =>
      _ConnectionProbeSheetState();
}

enum _ProbeState { running, succeeded, failed, cancelled }

class _ConnectionProbeSheetState extends ConsumerState<ConnectionProbeSheet> {
  final _stages = <ConnectionStage>[];
  late final ConnectionAttempt _attempt;
  _ProbeState _state = _ProbeState.running;
  ProbeOutcome? _outcome;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _attempt = ConnectionAttempt(onStage: (stage) {
      if (mounted) setState(() => _stages.add(stage));
    });
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      final outcome = await ref.read(sshServiceProvider).probe(
            host: widget.host,
            routePlan: widget.plan,
            verifyHostKey: widget.verifyHostKey,
            keyboardInteractive: widget.keyboardInteractive,
            attempt: _attempt,
          );
      if (!mounted) return;
      setState(() {
        _outcome = outcome;
        _state = _ProbeState.succeeded;
      });
    } on ConnectionCancelledException {
      if (mounted) setState(() => _state = _ProbeState.cancelled);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _state = _ProbeState.failed;
      });
    }
  }

  @override
  void dispose() {
    _attempt.cancel(); // 关掉弹层就停：已建好的连接立刻关掉
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final running = _state == _ProbeState.running;
    return SafeArea(
      child: SingleChildScrollView(
        key: const ValueKey('connection-probe-sheet'),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            LText('测试连接', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            LText(
              '按当前填写的配置走一遍：会核对指纹、登录，然后只检查远端终端，不打开 shell，不执行启动命令。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            RouteLegsView(plan: widget.plan, dense: true),
            const Divider(height: 28),
            for (var index = 0; index < _stages.length; index++)
              _StageRow(
                stage: _stages[index],
                status: index < _stages.length - 1
                    ? _StageStatus.done
                    : switch (_state) {
                        _ProbeState.running => _StageStatus.running,
                        _ProbeState.succeeded => _StageStatus.done,
                        _ProbeState.failed => _StageStatus.failed,
                        _ProbeState.cancelled => _StageStatus.cancelled,
                      },
              ),
            if (_stages.isEmpty && running)
              const _StageRow(stage: null, status: _StageStatus.running),
            const SizedBox(height: 12),
            if (_state == _ProbeState.succeeded)
              _ResultBox(
                key: const ValueKey('probe-succeeded'),
                icon: Icons.check_circle_outline,
                color: scheme.primaryContainer,
                onColor: scheme.onPrimaryContainer,
                text: _outcome?.tty == null
                    ? '已连通。'
                    : '登录成功，远端分配了终端：${_outcome!.tty}。',
              ),
            if (_state == _ProbeState.failed) ...[
              _ResultBox(
                key: const ValueKey('probe-failed'),
                icon: Icons.error_outline,
                color: scheme.errorContainer,
                onColor: scheme.onErrorContainer,
                text: '$_error',
              ),
              if (connectionHint(_error!) != null) ...[
                const SizedBox(height: 8),
                _ResultBox(
                  icon: Icons.lightbulb_outline,
                  color: scheme.secondaryContainer,
                  onColor: scheme.onSecondaryContainer,
                  text: connectionHint(_error!)!,
                ),
              ],
            ],
            if (_state == _ProbeState.cancelled)
              const LText('已停止，已建好的连接都已关掉。'),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: running
                  ? OutlinedButton.icon(
                      key: const ValueKey('probe-cancel'),
                      onPressed: _attempt.cancel,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const LText('停止'),
                    )
                  : FilledButton(
                      onPressed: () => Navigator.pop(context),
                      child: const LText('完成'),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _StageStatus { running, done, failed, cancelled }

class _StageRow extends StatelessWidget {
  const _StageRow({required this.stage, required this.status});

  final ConnectionStage? stage;
  final _StageStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final leading = switch (status) {
      _StageStatus.running => const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      _StageStatus.done => Icon(Icons.check, size: 18, color: scheme.primary),
      _StageStatus.failed => Icon(Icons.close, size: 18, color: scheme.error),
      _StageStatus.cancelled =>
        Icon(Icons.stop, size: 18, color: scheme.onSurfaceVariant),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 10),
          Expanded(child: LText(stage?.describe() ?? '正在准备…')),
        ],
      ),
    );
  }
}

class _ResultBox extends StatelessWidget {
  const _ResultBox({
    super.key,
    required this.icon,
    required this.color,
    required this.onColor,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final Color onColor;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: onColor),
            const SizedBox(width: 8),
            Expanded(
              child: LText(
                text,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: onColor),
              ),
            ),
          ],
        ),
      );
}
