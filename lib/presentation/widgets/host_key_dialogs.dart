import 'package:flutter/material.dart';

import '../localization/localized_widgets.dart';

/// 第一次连这台主机：展示指纹让用户核对。返回 true 表示接受并记住。
Future<bool> confirmNewHostKey(
  BuildContext context, {
  required String hostname,
  required int port,
  required String algorithm,
  required String fingerprint,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.verified_user_outlined),
        title: const LText('确认服务器指纹'),
        content: LSelectableText(
          '$hostname:$port\n$algorithm\n$fingerprint\n\n首次连接前请与管理员核对。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const LText('拒绝'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const LText('接受并记住'),
          ),
        ],
      ),
    ) ??
    false;

/// 指纹和上次记住的不一样：连接已被阻止，这里只告知并给出后续做法（SEC02）。
///
/// 没有「确认更新继续连」的按钮：一点就过等于没拦。用户核对后若确认是正常换钥，
/// 可以删除旧指纹，然后重新连接，那时按首次连接重新核对。返回 true 表示用户选择删除旧指纹。
Future<bool> showChangedHostKey(
  BuildContext context, {
  required String hostname,
  required int port,
  required String algorithm,
  required String fingerprint,
  required String oldFingerprint,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.gpp_bad_outlined, color: Colors.redAccent),
        title: const LText('服务器指纹已变化，已阻止连接'),
        content: LSelectableText(
          '$hostname:$port\n$algorithm\n'
          '现在：$fingerprint\n以前：$oldFingerprint\n\n'
          '可能是服务器重装，也可能是有人在冒充这台服务器。请先向管理员核对新指纹。'
          '确认是正常更换后，删除旧指纹再重新连接，届时会按首次连接让你重新核对。',
        ),
        actions: [
          TextButton(
            key: const ValueKey('delete-old-host-key'),
            onPressed: () => Navigator.pop(context, true),
            child: const LText('删除旧指纹'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, false),
            child: const LText('关闭'),
          ),
        ],
      ),
    ) ??
    false;
