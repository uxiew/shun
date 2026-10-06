import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/terminal_link.dart';
import '../localization/localized_widgets.dart';
import 'tailscale_check_card.dart' show externalLinkLauncherProvider;

/// 点了终端里的链接（R19，SEC08、TER08）：只弹这个框，不直接打开。
///
/// 先把实际要去的域名放大写出来，再给完整地址；能交给浏览器的只有 http/https，
/// 其余只能复制。拖动、长按选字都不会走到这里（flterm 只在点按抬起、位置没变时报链接）。
Future<void> showTerminalLinkSheet(
  BuildContext context, {
  required String shownText,
  required String address,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => TerminalLinkSheet(
        link: TerminalLinkReview.of(shownText: shownText, address: address),
      ),
    );

class TerminalLinkSheet extends ConsumerWidget {
  const TerminalLinkSheet({super.key, required this.link});

  final TerminalLinkReview link;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const LText('终端里的链接（来自远端输出）'),
          const SizedBox(height: 8),
          if (link.host.isNotEmpty)
            Text(
              link.host,
              key: const ValueKey('terminal-link-host'),
              style: theme.textTheme.titleLarge,
            ),
          SelectableText(
            link.address,
            key: const ValueKey('terminal-link-address'),
            maxLines: 6,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
          const SizedBox(height: 8),
          if (link.textDiffers)
            _Warning(
              key: const ValueKey('terminal-link-text-differs'),
              text: '屏幕上显示的文字和实际地址不一样：',
              detail: link.shownText,
            ),
          if (link.nonAsciiHost)
            const _Warning(
              key: ValueKey('terminal-link-non-ascii'),
              text: '域名里有非英文字符，可能是仿冒知名网站的域名。',
            ),
          if (link.refusal case final refusal?)
            _Warning(
              key: const ValueKey('terminal-link-refused'),
              text: '不能打开：',
              detail: localized(refusal),
              color: scheme.error,
            ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            children: [
              TextButton(
                key: const ValueKey('terminal-link-cancel'),
                onPressed: () => Navigator.pop(context),
                child: const LText('取消'),
              ),
              OutlinedButton(
                key: const ValueKey('terminal-link-copy'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: link.address));
                  if (context.mounted) Navigator.pop(context);
                },
                child: const LText('复制链接'),
              ),
              if (link.canOpen)
                FilledButton(
                  key: const ValueKey('terminal-link-open'),
                  onPressed: () async {
                    final launch = ref.read(externalLinkLauncherProvider);
                    Navigator.pop(context);
                    await launch(link.uri!);
                  },
                  child: const LText('用浏览器打开'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning({super.key, required this.text, this.detail, this.color});

  final String text;
  final String? detail;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final foreground = color ?? Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_outlined, size: 18, color: foreground),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LText(text, style: TextStyle(color: foreground)),
                if (detail != null)
                  Text(detail!, style: TextStyle(color: foreground)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
