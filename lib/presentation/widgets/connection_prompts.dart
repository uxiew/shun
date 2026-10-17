import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/host_trust.dart';
import '../../application/vault_controller.dart';
import '../../domain/models/host.dart';
import '../../infrastructure/ssh/ssh_service.dart';
import '../localization/localized_widgets.dart';
import 'host_key_dialogs.dart';

/// 连接时要问用户的两件事：指纹核对、键盘交互登录。主机列表开连接、终端页「重新连接」（R22）都用这一套，
/// 规则在 application/host_trust.dart，这里只提供弹窗和保存。
///
/// [context] 所在的页面没了（[BuildContext.mounted] 为 false）时一律按拒绝处理：指纹不放行，问答返回 null。
///
/// 保险库从建回调时取到的 [ProviderContainer] 读，不用调用方的 `ref`：回调常常在弹出它的菜单关掉以后才被调用
///（「用 Mosh 另开一个」「安装 mosh」都是先收菜单再连），那时菜单的 ref 一用就抛 StateError，
/// dartssh2 当成核对失败断开，用户看到的是「登录完成前连接被对方关闭」（R42 在模拟器上撞到过）。
/// 要在菜单关掉后还能弹指纹框，[context] 就传弹出菜单的那一层（如 `Navigator.of(context).context`）。
HostKeyVerifier hostKeyVerifier(BuildContext context) {
  final container = ProviderScope.containerOf(context, listen: false);
  return (HostProfile host, String algorithm, String fingerprint) async {
    final vault = container.read(vaultControllerProvider).data;
    if (vault == null) return false;
    return verifyHostKeyWithKnownHosts(
      knownHosts: (vault.extras['knownHosts'] as List? ?? const [])
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .toList(),
      hostname: host.hostname,
      port: host.port,
      keyType: algorithm,
      fingerprint: fingerprint,
      confirmNew: () async =>
          context.mounted &&
          await confirmNewHostKey(
            context,
            hostname: host.hostname,
            port: host.port,
            algorithm: algorithm,
            fingerprint: fingerprint,
          ),
      onChanged: (oldFingerprint) async =>
          context.mounted &&
          await showChangedHostKey(
            context,
            hostname: host.hostname,
            port: host.port,
            algorithm: algorithm,
            fingerprint: fingerprint,
            oldFingerprint: oldFingerprint,
          ),
      save: (knownHosts) async {
        final latest = container.read(vaultControllerProvider).data ?? vault;
        await container.read(vaultControllerProvider.notifier).replace(
              latest.copyWith(
                extras: {...latest.extras, 'knownHosts': knownHosts},
              ),
            );
      },
    );
  };
}

KeyboardInteractiveHandler keyboardInteractivePrompt(BuildContext context) =>
    (String name, String instruction,
        List<({bool echo, String text})> prompts) async {
      if (!context.mounted) return null;
      final controllers = prompts.map((_) => TextEditingController()).toList();
      return showDialog<List<String>>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: LText(name.isEmpty ? '交互式认证' : name),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (instruction.isNotEmpty) ...[
                  LText(instruction),
                  const SizedBox(height: 12),
                ],
                for (var index = 0; index < prompts.length; index++) ...[
                  TextField(
                    controller: controllers[index],
                    obscureText: !prompts[index].echo,
                    autofocus: index == 0,
                    decoration:
                        LInputDecoration(labelText: prompts[index].text),
                  ),
                  const SizedBox(height: 10),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const LText('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                controllers.map((value) => value.text).toList(),
              ),
              child: const LText('继续'),
            ),
          ],
        ),
      );
    };
