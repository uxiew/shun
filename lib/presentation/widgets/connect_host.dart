import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/home_navigation.dart';
import '../../application/session_controller.dart';
import '../../application/vault_controller.dart';
import '../../domain/models/host.dart';
import '../localization/localized_widgets.dart';
import 'connection_prompts.dart';
import 'first_login_dialog.dart';

/// 从列表里点一台主机去连：保险库页和 Tailscale 目录页共用（R26），两边表现一样。
/// 还没配好登录的（Tailscale 导入时不统一填用户名和密码）先问，写回这一台再连；然后切到终端页。
Future<void> connectHostFromList(
  BuildContext context,
  WidgetRef ref,
  HostProfile host,
) async {
  if (needsFirstLogin(host)) {
    final login = await askFirstLogin(context, host);
    if (login == null || !context.mounted) return;
    final updated = HostProfile({
      ...host.data,
      'username': login.username,
      if (login.password != null) 'password': login.password,
    });
    await ref.read(vaultControllerProvider.notifier).upsertHost(updated);
    if (!context.mounted) return;
    host = updated;
  }
  // 两个回调在连接当中才用到：先取好，跳到终端页后 context 可能已经不在了。
  final verify = hostKeyVerifier(context);
  final ask = keyboardInteractivePrompt(context);
  final messenger = ScaffoldMessenger.of(context);
  ref.read(homeTabProvider.notifier).state = 1;
  try {
    final connected = await ref
        .read(sessionControllerProvider.notifier)
        .connect(host, verify, keyboardInteractive: ask);
    // 用户点了「终止连接」时 connect 正常返回 false，这时不能说已连接。
    if (connected) {
      messenger.showSnackBar(SnackBar(content: LText('${host.label} 已连接')));
    }
  } catch (error) {
    // 连接失败页已经把原因、下一步写全了，再弹一条一样的提示条只是重复（docs/dev/ui-text.md）。
    // 没走到失败页的（比如还没开始连就被拒）才在这里说。
    final shown = ref.read(sessionControllerProvider).pendingConnections.any(
        (p) =>
            p.host.id == host.id && p.phase == PendingConnectionPhase.failed);
    if (!shown) {
      messenger.showSnackBar(SnackBar(content: LText('连接失败：$error')));
    }
  }
}
