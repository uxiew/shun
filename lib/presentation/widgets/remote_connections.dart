import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../application/rustdesk.dart';
import '../../application/uuremote.dart';
import '../localization/localized_widgets.dart';
import '../screens/rustdesk_screen.dart';
import '../screens/uuremote_screen.dart';
import '../ui/components.dart';
import 'remote_entry_widgets.dart';

class RemoteConnections extends ConsumerWidget {
  const RemoteConnections(
      {super.key, required this.query, required this.visible});
  final String query;
  final bool visible;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rd = ref.watch(rustDeskProvider);
    final uu = ref.watch(uuRemoteProvider);
    if (!visible) return const SizedBox.shrink();
    final search = query.toLowerCase();
    final rows = <Widget>[
      for (final notice in [rd.notice, uu.notice].whereType<String>())
        ShunSectionItem(
          child: Row(
            children: [
              Expanded(child: LText(notice)),
              ShunButton(
                kind: ShunButtonKind.text,
                onPressed: () async {
                  await ref.read(rustDeskProvider.notifier).retryLoad();
                  await ref.read(uuRemoteProvider.notifier).retryLoad();
                },
                label: '重试',
              ),
            ],
          ),
        ),
      for (final entry in rd.entries.where(
        (e) => '${e.label} RustDesk'.toLowerCase().contains(search),
      ))
        RemoteEntryTile(
          entry: entry,
          provider: 'RustDesk',
          onOpen: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => RustDeskHostScreen(hostId: entry.id),
            ),
          ),
        ),
      for (final entry in uu.entries.where(
        (e) => '${e.label} UU'.toLowerCase().contains(search),
      ))
        RemoteEntryTile(
          entry: entry,
          provider: 'UU 远程',
          status: uu.pending?.hostId == entry.id ? '等待 UU 回调' : null,
          onOpen: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => UuRemoteHostScreen(hostId: entry.id),
            ),
          ),
        ),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ShunSection(children: rows),
    );
  }
}
