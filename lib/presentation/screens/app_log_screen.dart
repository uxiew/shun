import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/app_log.dart';
import '../../application/connection_events.dart';
import '../../application/vault_controller.dart';
import '../localization/localized_widgets.dart';
import '../widgets/connection_event_text.dart';
import '../widgets/connection_event_tile.dart';
import '../widgets/hint.dart';

/// 日志页（R26 F24）：崩溃、出错、备份（[AppLog]）和连接（[ConnectionEventLog]，R25）合在一起，新的在上。
///
/// 只读本机记录，不连任何东西：打开它不会去探主机，也不会触发重连。名字按保险库现在的查（记录里只有 ID），导出不查名字。
/// 给了 [hostId] 只看这一台的连接（主机 ⋮ 菜单、连接失败页进来），不给是整份日志（设置里进来）。
class AppLogScreen extends ConsumerStatefulWidget {
  const AppLogScreen({super.key, this.hostId});

  final String? hostId;

  @override
  ConsumerState<AppLogScreen> createState() => _AppLogScreenState();
}

enum _Filter { all, crash, error, connection, sync }

const _logHint =
    '只存在这部手机上，不上传、不进备份。地址、用户名、令牌写进来之前就换成了「<IP>」这类记号。崩溃、出错、备份留 14 天，连接留 7 天。';

String _filterLabel(_Filter filter) => switch (filter) {
      _Filter.all => '全部',
      _Filter.crash => '崩溃',
      _Filter.error => '出错',
      _Filter.connection => '连接',
      _Filter.sync => '备份',
    };

_Filter _filterOf(AppLogKind kind) => switch (kind) {
      AppLogKind.crash => _Filter.crash,
      AppLogKind.error => _Filter.error,
      AppLogKind.sync => _Filter.sync,
    };

/// 一行：要么是日志条目，要么是连接事件。
class _Row {
  _Row.app(AppLogEntry this.entry)
      : at = entry.at,
        filter = _filterOf(entry.kind),
        event = null;
  _Row.connection(ConnectionEvent this.event)
      : at = event.at,
        filter = _Filter.connection,
        entry = null;

  final DateTime at;
  final _Filter filter;
  final AppLogEntry? entry;
  final ConnectionEvent? event;
}

class _AppLogScreenState extends ConsumerState<AppLogScreen> {
  var _filter = _Filter.all;

  @override
  void initState() {
    super.initState();
    // 过了保留期的在这时删：不在后台定时扫。
    unawaited(ref.read(appLogProvider.notifier).prune());
    unawaited(ref.read(connectionEventLogProvider.notifier).prune());
  }

  List<_Row> _rows(List<AppLogEntry> entries, List<ConnectionEvent> events) => [
        for (final entry in entries) _Row.app(entry),
        for (final event in events) _Row.connection(event),
      ]..sort((a, b) => b.at.compareTo(a.at));

  @override
  Widget build(BuildContext context) {
    final hostId = widget.hostId;
    final entries =
        hostId == null ? ref.watch(appLogProvider) : const <AppLogEntry>[];
    final allEvents = ref.watch(connectionEventLogProvider);
    final events = hostId == null
        ? allEvents
        : allEvents.where((event) => event.hostId == hostId).toList();
    final vaultHosts = ref.watch(vaultControllerProvider).data?.hosts;
    final hosts = <String, String>{
      if (vaultHosts != null)
        for (final host in vaultHosts) host.id: host.label,
    };
    final all = _rows(entries, events);
    final rows = _filter == _Filter.all
        ? all
        : all.where((row) => row.filter == _filter).toList();
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    return Scaffold(
      appBar: AppBar(
        title: hostId == null
            ? const LText('日志')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const LText('连接日志'),
                  Text(
                    hosts[hostId] ?? localized('已删除的主机'),
                    style: small,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
        actions: [
          HintButton(
            title: '日志',
            message:
                '${localized(_logHint)}\n\n${localized(connectionTimingNote)}',
          ),
          IconButton(
            key: const ValueKey('app-log-export'),
            tooltip: localized('导出'),
            onPressed: all.isEmpty ? null : () => _export(entries, events),
            icon: const Icon(Icons.ios_share),
          ),
          IconButton(
            key: const ValueKey('app-log-clear'),
            tooltip: localized('清除'),
            onPressed: all.isEmpty
                ? null
                : () => _clear(entries.length, events.length),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hostId == null)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Row(
                children: [
                  for (final filter in _Filter.values)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ChoiceChip(
                        key: ValueKey('app-log-filter-${filter.name}'),
                        label: Text(
                          '${localized(_filterLabel(filter))} '
                          '${filter == _Filter.all ? all.length : all.where((r) => r.filter == filter).length}',
                        ),
                        selected: _filter == filter,
                        onSelected: (_) => setState(() => _filter = filter),
                      ),
                    ),
                ],
              ),
            ),
          if (events.isNotEmpty &&
              (hostId != null || _filter == _Filter.connection))
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: LText(
                connectionLogSummary(events),
                key: const ValueKey('connection-log-summary'),
                style: small,
              ),
            ),
          Expanded(
            child: rows.isEmpty
                ? Center(
                    child: LText(
                      hostId == null ? '还没有记录' : '这台主机最近 7 天没有记录',
                      key: const ValueKey('app-log-empty'),
                    ),
                  )
                : ListView.separated(
                    key: const ValueKey('app-log-list'),
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) =>
                        _tile(context, rows[index], hosts, small),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, _Row row, Map<String, String> hosts,
      TextStyle? small) {
    final scheme = Theme.of(context).colorScheme;
    final time = formatConnectionEventTime(row.at);
    if (row.event case final event?) {
      return ConnectionEventTile(
        event: event,
        hostLabel: widget.hostId == null
            ? hosts[event.hostId] ?? localized('已删除的主机')
            : null,
        hopName: (hop) => connectionHopName(
          hop,
          event.hopCount,
          hop < event.hopIds.length ? hosts[event.hopIds[hop]] : null,
        ),
      );
    }
    final entry = row.entry!;
    final (icon, color) = switch (entry.kind) {
      AppLogKind.crash => (Icons.error, scheme.error),
      AppLogKind.error => (Icons.warning_amber, scheme.tertiary),
      AppLogKind.sync => (Icons.sync, scheme.primary),
    };
    final first = entry.detail?.split('\n').first;
    return ListTile(
      key: ValueKey('app-log-entry-${entry.at.millisecondsSinceEpoch}'),
      leading: Icon(icon, color: color),
      title: Text(localized(entry.title)),
      subtitle: Text(
        [
          time,
          if (entry.count > 1)
            localized('{n} 次').replaceAll('{n}', '${entry.count}'),
          if (first != null && first.isNotEmpty) first,
        ].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: small,
      ),
      onTap: () => _details(entry),
    );
  }

  Future<void> _details(AppLogEntry entry) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (context) {
          final text = formatAppLogEntry(entry);
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.7,
            builder: (context, controller) => ListView(
              controller: controller,
              padding: const EdgeInsets.all(16),
              children: [
                Text(localized(entry.title),
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                SelectableText(
                  key: const ValueKey('app-log-details'),
                  text,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('app-log-copy-one'),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: text));
                      if (context.mounted) Navigator.pop(context);
                    },
                    icon: const Icon(Icons.copy),
                    label: const LText('复制这条'),
                  ),
                ),
              ],
            ),
          );
        },
      );

  Future<void> _export(
      List<AppLogEntry> entries, List<ConnectionEvent> events) async {
    final now = DateTime.now();
    // 只看一台时只导出这一台的连接。
    final text = widget.hostId == null
        ? exportAppLog(entries, events, now: now)
        : exportConnectionEvents(events, now: now);
    final copy = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const LText('导出前预览'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const LText('复制的就是下面这些。地址、用户名、令牌已经换成记号，主机只写编号。发给别人之前再看一眼。'),
              const SizedBox(height: 8),
              Flexible(
                child: SingleChildScrollView(
                  child: SelectableText(
                    key: const ValueKey('app-log-export-preview'),
                    text,
                    style:
                        const TextStyle(fontFamily: 'monospace', fontSize: 11),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const LText('取消'),
          ),
          FilledButton.icon(
            key: const ValueKey('app-log-copy'),
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.copy),
            label: const LText('复制到剪贴板'),
          ),
        ],
      ),
    );
    if (copy != true || !mounted) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          localized('已复制 {n} 条记录')
              .replaceAll('{n}', '${entries.length + events.length}'),
        ),
      ),
    );
  }

  Future<void> _clear(int logCount, int connectionCount) async {
    final hostId = widget.hostId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: LText(hostId == null ? '清除全部日志？' : '清除这台主机的连接日志？'),
        content: Text(
          hostId == null
              ? localized('会删掉崩溃、出错、备份 {a} 条和连接 {b} 条，删了找不回来。主机和连着的标签都不动。')
                  .replaceAll('{a}', '$logCount')
                  .replaceAll('{b}', '$connectionCount')
              : localized('会删掉 {n} 条，删了找不回来。主机、连着的标签和保险库都不动。')
                  .replaceAll('{n}', '$connectionCount'),
        ),
        actions: [
          // 取消在前、是默认；删除不是默认动作（UX03）。
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: const LText('取消'),
          ),
          TextButton(
            key: const ValueKey('app-log-clear-confirm'),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const LText('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final connections = ref.read(connectionEventLogProvider.notifier);
    if (hostId == null) {
      await ref.read(appLogProvider.notifier).clearAll();
      await connections.clearAll();
    } else {
      await connections.clearHost(hostId);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: LText('已清除')),
    );
  }
}

/// 一条日志的全文（详情页、复制、导出用同一份）。
String formatAppLogEntry(AppLogEntry entry) {
  var detail = entry.detail ?? '';
  final stack = entry.stack;
  // Java 崩溃的详情第一行就是堆栈第一行（列表里要靠它看出是什么异常），全文里只留堆栈那一份。
  if (stack != null && detail.isNotEmpty) {
    final first = detail.split('\n').first;
    if (stack.startsWith(first)) {
      detail = detail.substring(first.length).trimLeft();
    }
  }
  return [
    '${formatConnectionEventTime(entry.at)} '
        '[${localized(_filterLabel(_filterOf(entry.kind)))}] ${localized(entry.title)}'
        '${entry.count > 1 ? ' ×${entry.count}' : ''}',
    if (detail.isNotEmpty) detail,
    if (stack != null) stack,
  ].join('\n');
}

/// 导出整份日志：崩溃、出错、备份在前（新的在上），连接用 [exportConnectionEvents] 的写法（主机只写编号）。
String exportAppLog(
  List<AppLogEntry> entries,
  List<ConnectionEvent> events, {
  required DateTime now,
}) {
  final newest = [...entries]..sort((a, b) => b.at.compareTo(a.at));
  return [
    'shun ${localized('日志')} · ${formatConnectionEventTime(now)}',
    '',
    '== ${localized('崩溃、出错、备份')}（${newest.length}）',
    for (final entry in newest) '${formatAppLogEntry(entry)}\n',
    '== ${localized('连接')}（${events.length}）',
    if (events.isNotEmpty) exportConnectionEvents(events, now: now),
  ].join('\n');
}
