import 'package:flutter/material.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../localization/localized_widgets.dart';
import '../ui/components.dart';

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
        content: _FingerprintContent(
          details: '$hostname:$port\n$algorithm\n$fingerprint',
          notice: '首次连接前请与管理员核对。',
        ),
        actions: [
          ShunButton(
            key: const ValueKey('host-key-reject'),
            kind: ShunButtonKind.text,
            onPressed: () => Navigator.pop(context, false),
            label: '拒绝',
          ),
          ShunButton(
            key: const ValueKey('host-key-accept'),
            onPressed: () => Navigator.pop(context, true),
            label: '接受并记住',
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
        icon: Icon(
          Icons.gpp_bad_outlined,
          color: Theme.of(context).colorScheme.error,
        ),
        title: const LText('服务器指纹已变化，已阻止连接'),
        content: _FingerprintContent(
          details: '$hostname:$port\n$algorithm\n'
              '现在：$fingerprint\n以前：$oldFingerprint',
          notice: '可能是服务器重装，也可能是有人在冒充这台服务器。请先向管理员核对新指纹。'
              '确认是正常更换后，删除旧指纹再重新连接，届时会按首次连接让你重新核对。',
        ),
        actions: [
          ShunButton(
            key: const ValueKey('delete-old-host-key'),
            kind: ShunButtonKind.text,
            onPressed: () => Navigator.pop(context, true),
            label: '删除旧指纹',
          ),
          ShunButton(
            key: const ValueKey('host-key-close'),
            onPressed: () => Navigator.pop(context, false),
            label: '关闭',
          ),
        ],
      ),
    ) ??
    false;

class _FingerprintContent extends StatelessWidget {
  const _FingerprintContent({required this.details, required this.notice});

  final String details;
  final String notice;

  @override
  Widget build(BuildContext context) {
    final colors = prism.Theme.of(context).colorScheme;
    final bodyStyle = Theme.of(context).textTheme.bodyMedium;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: ShapeDecoration(
              color: prism.SurfaceLevel.floatingOf(colors).next.colorOf(colors),
              shape: prism.AppShape.md,
            ),
            child: LSelectableText(
              details,
              style: bodyStyle?.copyWith(
                fontFamily: 'monospace',
                fontFamilyFallback: [
                  if (bodyStyle.fontFamily case final String family) family,
                  ...?bodyStyle.fontFamilyFallback,
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          LSelectableText(notice),
        ],
      ),
    );
  }
}
