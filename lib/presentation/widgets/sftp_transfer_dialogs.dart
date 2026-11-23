import 'package:flutter/material.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../infrastructure/ssh/sftp_service.dart';
import '../localization/localized_widgets.dart';
import '../ui/components.dart';

// 文件页传输前要用户拿主意的两件事（R24）：替不替换同名文件、续不续传上次的半截。
// 都不替用户猜——猜错一次就是覆盖掉别人的文件，或者拼出一个坏文件。

/// 目标位置已有同名文件：替换要用户点头。
Future<bool> confirmReplaceDialog(
    BuildContext context, String name, FileStamp existing) async {
  final details = [
    if (existing.size != null) formatBytes(existing.size!),
    if (existing.modifiedSeconds != null)
      DateTime.fromMillisecondsSinceEpoch(existing.modifiedSeconds! * 1000)
          .toLocal()
          .toString()
          .substring(0, 19),
  ].join(' · ');
  final warning = localized('这里已经有同名文件。替换后原来的内容就没了，无法撤销。');
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const LText('替换同名文件？'),
      scrollable: true,
      content: _TransferNotice(
        file: '$name${details.isEmpty ? '' : '\n$details'}',
        note: warning,
      ),
      actions: [
        ShunButton(
          key: const ValueKey('sftp-replace-cancel'),
          kind: ShunButtonKind.text,
          label: '取消',
          onPressed: () => Navigator.pop(context, false),
        ),
        ShunButton(
          key: const ValueKey('sftp-replace-confirm'),
          label: '替换',
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    ),
  );
  return ok == true;
}

/// 上次没传完的临时文件还在：问续传还是从头传。返回 null 表示取消；没有可续的临时文件时不问、返回 false。
///
/// 临时文件只按名字认，认不出是不是这个文件传的：续错了，前半截是别的文件，结果就坏了。
/// 所以显眼的按钮是「从头传」。
Future<bool?> askResumeDialog(
  BuildContext context,
  FileTransferService target,
  String partialPath,
  String name,
  int total,
) async {
  final sent = await target.fileSize(partialPath);
  if (sent == null || sent <= 0 || sent > total || !context.mounted) {
    return false;
  }
  final note = localized('这个文件名上次没传完，已传的部分还在。续传会接着它往后写，只有确定是同一个文件时才选；不确定就从头传。');
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const LText('上次没传完'),
      scrollable: true,
      content: _TransferNotice(
        file: '$name\n${formatBytes(sent)} / ${formatBytes(total)}',
        note: note,
      ),
      actions: [
        ShunButton(
          key: const ValueKey('sftp-resume-cancel'),
          kind: ShunButtonKind.text,
          label: '取消',
          onPressed: () => Navigator.pop(context),
        ),
        ShunButton(
          key: const ValueKey('sftp-resume-continue'),
          kind: ShunButtonKind.text,
          label: '续传',
          onPressed: () => Navigator.pop(context, true),
        ),
        ShunButton(
          key: const ValueKey('sftp-resume-restart'),
          label: '从头传',
          onPressed: () => Navigator.pop(context, false),
        ),
      ],
    ),
  );
}

class _TransferNotice extends StatelessWidget {
  const _TransferNotice({required this.file, required this.note});

  final String file;
  final String note;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          prism.SurfaceScope(
            level: prism.SurfaceLevel.floatingOf(
                prism.Theme.of(context).colorScheme),
            child: prism.generateGroup([
              ShunSectionItem(
                padding: const EdgeInsets.all(12),
                child: Text(file,
                    style: prism.AppTextStyle.subheadline
                        .of(context, emphasized: true)),
              )
            ]),
          ),
          const SizedBox(height: 12),
          Text(note),
        ],
      );
}

/// 给人看的字节数：B / KB / MB / GB，保留一位小数。
String formatBytes(int value) => value < 1024
    ? '$value B'
    : value < 1024 * 1024
        ? '${(value / 1024).toStringAsFixed(1)} KB'
        : value < 1024 * 1024 * 1024
            ? '${(value / 1024 / 1024).toStringAsFixed(1)} MB'
            : '${(value / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
