import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/tailscale_catalog_import.dart';
import '../../application/tailscale_catalog_refresh.dart';
import '../../domain/models/host.dart';
import '../../infrastructure/tailscale/catalog_cache.dart';
import '../../infrastructure/tailscale/catalog_cache_repository.dart';
import '../localization/localized_widgets.dart';
import 'catalog_text.dart';

/// 主机编辑器里的「目录来源」：这台主机从哪个目录、哪台设备来，地址还跟不跟随目录，
/// 目录此刻怎么说（R13 验收：来源、刷新时间、路由明确）。
///
/// 目录状态只是目录的说法，不代表能连上——能不能连到、SSH 是否可用，要实际连接才知道（TSC06）。
/// 「断开关联」只在保存时去掉关联字段，主机本身和它的一切设置都留着。
class CatalogSourceSection extends ConsumerStatefulWidget {
  const CatalogSourceSection({
    super.key,
    required this.host,
    required this.currentHostname,
    required this.unlinked,
    required this.onUnlinkChanged,
  });

  final HostProfile host;

  /// 编辑器里此刻填的地址：和上次由目录写入的不一样，就说明用户改过、以后不再跟随。
  final String currentHostname;
  final bool unlinked;
  final ValueChanged<bool> onUnlinkChanged;

  @override
  ConsumerState<CatalogSourceSection> createState() =>
      _CatalogSourceSectionState();
}

class _CatalogSourceSectionState extends ConsumerState<CatalogSourceSection> {
  late final Future<CatalogCache?> _cache = _load();

  Future<CatalogCache?> _load() async {
    final binding = CatalogBinding.of(widget.host);
    if (binding == null) return null;
    try {
      return await ref.read(catalogCacheRepositoryProvider).load(
            binding.catalogId,
          );
    } on Object {
      return null; // 读不了（格式更新、文件坏）就当本机没有这个来源，只影响显示。
    }
  }

  @override
  Widget build(BuildContext context) {
    final binding = CatalogBinding.of(widget.host);
    if (binding == null) return const SizedBox.shrink();
    final small = Theme.of(context).textTheme.bodySmall;
    return FutureBuilder<CatalogCache?>(
      future: _cache,
      builder: (context, snapshot) {
        final cache = snapshot.data;
        final status = snapshot.connectionState == ConnectionState.done
            ? catalogStatusOf(
                widget.host,
                {if (cache != null) cache.catalogId: cache},
              )
            : null;
        final record = status?.record;
        final following = binding.appliedAddress != null &&
            widget.currentHostname == binding.appliedAddress;
        return Card(
          key: const ValueKey('catalog-source-section'),
          margin: const EdgeInsets.only(top: 12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LText('目录来源'),
                const SizedBox(height: 4),
                catalogLine('来源：', cache?.label ?? binding.catalogId,
                    style: small),
                catalogLine(
                  '设备：',
                  record == null
                      ? binding.deviceId
                      : '${catalogDeviceName(record)} · ${binding.deviceId}',
                  style: small,
                ),
                if (status != null) ...[
                  LText(_presenceText(status.presence), style: small),
                  if (cache?.lastSuccess case final success?)
                    catalogLine('缓存时间：', catalogTime(success.at), style: small),
                  if (record != null)
                    LText(controlPlaneText(record.device.connectedToControl),
                        style: small),
                ],
                LText(
                  following
                      ? '地址跟随目录：刷新时设备地址变了，这里会跟着改。'
                      : '地址不跟随目录：你改过地址（或从没由目录写过），刷新不会动它。',
                  style: small,
                ),
                LText('目录状态不代表能连上：能不能连到、SSH 是否可用，要实际连接才知道。', style: small),
                const SizedBox(height: 4),
                if (widget.unlinked)
                  Row(
                    children: [
                      const Expanded(
                        child: LText('保存后断开关联：主机和它的设置都保留，刷新不再改它。'),
                      ),
                      TextButton(
                        onPressed: () => widget.onUnlinkChanged(false),
                        child: const LText('撤销'),
                      ),
                    ],
                  )
                else
                  TextButton.icon(
                    key: const ValueKey('catalog-unlink'),
                    onPressed: () => widget.onUnlinkChanged(true),
                    icon: const Icon(Icons.link_off),
                    label: const LText('断开和目录的关联'),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

String _presenceText(CatalogPresence presence) => switch (presence) {
      CatalogPresence.listed => '目录状态：最近一次列表里有它',
      CatalogPresence.missing =>
        '目录状态：最近完整列表里没有它（设备可能被删、换了 tailnet，或是看不到的共享设备）',
      CatalogPresence.unknownDevice => '目录状态：缓存里没有这台设备',
      CatalogPresence.sourceNotOnThisDevice =>
        '目录状态：本机没有这个来源（来源被移除，或主机是从别的手机导入的）',
    };
