import 'package:flutter/material.dart';

import '../../application/session_controller.dart';
import '../../domain/host_identity.dart';
import '../../domain/models/host.dart';
import '../../domain/plugins/mosh_install_hint.dart';
import '../../infrastructure/ssh/ssh_service.dart';
import '../localization/localized_widgets.dart';
import 'connection_prompts.dart';
import 'connection_transport_sheet.dart';

String _pluginCloseText(ActiveTerminalSession session) {
  final head = localized('将关闭插件会话：');
  final tail = localized('本 App 先关自己这一端，再请插件关，2 秒内等它确认；插件自己连着的东西怎么收尾由插件决定。');
  return '$head${session.host.label}（${session.plugin!.protocol}）。$tail';
}

/// 关一个标签前问一句，写清楚关了以后远端会怎样。终端页的标签条和会话总览共用。
Future<bool> confirmCloseSession(
  BuildContext context,
  ActiveTerminalSession session,
) async {
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.warning_amber_outlined),
          title: LText(
            session.plugin == null
                ? '关闭 SSH 标签页？'
                : session.host.protocol == HostProtocol.plugin
                    ? '关闭插件标签页？'
                    : '关闭 Mosh 标签页？',
          ),
          // 不承诺普通 shell 里的程序还活着（TMX08）：断开时它们通常会收到挂断信号一起结束；
          // tmux 标签只是分离客户端，会话和里面的程序还在。
          // 已经断开的标签什么都不会再发：不能再说「会话留在远端」——恢复时可能已经查明它不在了。
          content: LText(
            switch ((session.tmux, session.connected)) {
              // 插件主机（X12）：本 App 只请插件关会话、2 秒内等它确认；插件那边连着什么、怎么收尾由插件决定。
              _
                  when session.host.protocol == HostProtocol.plugin &&
                      session.connected =>
                _pluginCloseText(session),
              // Mosh-tmux（R42）：mosh-server 退出只带走它里面的 tmux 客户端，会话留在远端。
              _
                  when session.plugin != null &&
                      session.tmux != null &&
                      session.connected =>
                '只分离这个标签的 tmux 客户端：关掉 Mosh 会话后，它里面的 tmux 客户端跟着退出，tmux 会话 '
                    '${session.tmux!.target.displayName}（${session.tmux!.target.sessionId}）和里面的程序留在远端，'
                    '不发送 Ctrl-C，也不结束会话。',
              // Mosh：插件让 mosh-client 按协议通知服务器关闭，远端的 mosh-server 和 shell 随之退出。
              _ when session.plugin != null && session.connected =>
                '将断开 ${session.host.label} 的 Mosh 会话：服务器上这次的 mosh-server 和里面的 shell 会一起退出，'
                    '没在 tmux 之类工具里运行的程序也会结束。',
              (final tmux?, true) => '只分离这个标签的 tmux 客户端：tmux 会话 '
                  '${tmux.target.displayName}（${tmux.target.sessionId}）和里面的程序留在远端，'
                  '不发送 Ctrl-C，也不结束会话。',
              (final tmux?, false) => '这个标签已经断开，关掉只是把它移走。tmux 会话 '
                  '${tmux.target.displayName}（${tmux.target.sessionId}）如果还在，不受影响。',
              (null, true) => '将断开 ${session.host.label} '
                  '(${session.host.username}@${session.host.hostname}) 的当前会话。'
                  '没在 tmux 之类工具里运行的程序，通常会随连接一起结束。',
              (null, false) => '这个标签已经断开，关掉只是把它移走。',
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const LText('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const LText('断开并关闭'),
            ),
          ],
        ),
      ) ??
      false;
}

/// 断开的标签重新连接。终端页的断线卡片和会话总览共用。
///
/// [context] 要活得比这次连接久：它没了，连接途中问指纹、问密码都按拒绝处理（见 connection_prompts.dart）。
Future<void> reconnectSession(
  BuildContext context,
  SessionController controller,
  ActiveTerminalSession session,
) async {
  try {
    await controller.reconnect(
      session.id,
      verifyHostKey: hostKeyVerifier(context),
      keyboardInteractive: keyboardInteractivePrompt(context),
    );
  } on MoshServerMissing catch (error) {
    // 等待卡片里也写了；这里再给出这台服务器的安装命令（用户确认了才去装）。
    if (!context.mounted) return;
    await showMoshInstallHint(
      context,
      hint: error.hint,
      hostId: sourceHostIdOf(session.host),
    );
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: LText('重新连接失败：$error')),
    );
  }
}
