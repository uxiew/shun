import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:plugin_api/plugin_api.dart' show hostApiMajor, hostApiMinor;

import '../../application/plugin_discovery.dart';
import '../../application/plugin_registry.dart';
import '../localization/localized_widgets.dart';
import '../ui/components.dart';
import '../widgets/empty_state.dart';
import '../widgets/hint.dart';
import 'plugin_detail_screen.dart';

/// 独立插件 APK 的管理页（X02 起、X04 补全）：列出、诊断某个包为什么不在、事件记录。
/// 每个插件的信息和操作（批准、停用、撤销、设置页）在详情页。
///
/// 打开这页就开始跟踪包的安装、更新、卸载：系统一报告，列表和详情页都按重新核验的结果变化，
/// 不需要手动点「重新扫描」（PLG11）。进程被杀后重新打开这页会整体重新发现一次。
class PluginsScreen extends ConsumerStatefulWidget {
  const PluginsScreen({super.key});

  @override
  ConsumerState<PluginsScreen> createState() => _PluginsScreenState();
}

class _PluginsScreenState extends ConsumerState<PluginsScreen> {
  final _inspectPackage = TextEditingController();
  final _events = <String>[];
  final _subscriptions = <StreamSubscription<Object?>>[];
  PluginDiscovery? _discovery;
  String? _inspectResult;
  String? _error;
  var _busy = false;

  /// 本 App 自己的签名证书，给插件作者抄进插件（X12）。null：还没读到。
  List<({String sha256, bool androidDebug})>? _hostSigners;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    final discovery = await ref.read(pluginDiscoveryProvider.future);
    if (!mounted) return;
    _discovery = discovery;
    _subscriptions
      ..add(discovery.events.listen((event) => _log(
          '${localized(_eventLabel(event.type))} · ${event.packageName} · ${localized(event.detail)}')))
      ..add(discovery.notices.listen((notice) {
        _log(localized(notice));
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: LText(notice)));
        }
      }));
    await _guard(discovery.start);
    if (!discovery.supported) return;
    List<({String sha256, bool androidDebug})> signers;
    try {
      signers = await discovery.hostSigners();
    } on Object {
      signers = const [];
    }
    if (mounted) setState(() => _hostSigners = signers);
  }

  void _log(String line) {
    if (!mounted) return;
    setState(() {
      _events.insert(0, line);
      if (_events.length > 30) _events.removeLast();
    });
  }

  static String _eventLabel(String type) => switch (type) {
        'providerEvent' => '插件回报',
        'rejectedCall' => '已拒绝调用',
        'closed' => '连接关闭',
        _ => type,
      };

  Future<void> _guard(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on Object catch (e) {
      _error = '$e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _inspectPackage.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(pluginRegistryProvider);
    final external = entries.where((e) => !e.isBuiltin).toList();
    final builtin = entries.where((e) => e.isBuiltin).toList();
    final discovery = _discovery;
    final small = Theme.of(context).textTheme.bodySmall;
    final builtinNames =
        builtin.map((e) => localized(e.descriptor!.displayName)).join('、');
    return Scaffold(
      appBar: ShunAppBar(
        title: const LText('插件（实验）'),
        actions: [
          HintButton(title: '插件（实验）', message: _about(builtinNames)),
          IconButton(
            tooltip: localized('重新扫描'),
            onPressed: _busy || discovery == null
                ? null
                : () => _guard(discovery.refresh),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (discovery != null && !discovery.supported)
            const EmptyState(
                icon: Icons.extension_outlined, title: '独立插件只支持 Android'),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) LText('扫描失败：$_error'),
          if (discovery != null &&
              discovery.supported &&
              external.isEmpty &&
              !_busy)
            const EmptyState(icon: Icons.extension_outlined, title: '没有发现插件'),
          if (external.isNotEmpty)
            ShunSection(
                children: [for (final entry in external) _summary(entry)]),
          // 排查和给作者的两块大多数人用不上，收起来；点标题展开（docs/dev/ui-text.md）。
          if (discovery != null && discovery.supported) ...[
            const SizedBox(height: 16),
            _fold(
              key: const ValueKey('plugin-inspect'),
              title: '某个应用没出现在这里？',
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _inspectPackage,
                        decoration: InputDecoration(labelText: localized('包名')),
                      ),
                    ),
                    ShunButton(
                      kind: ShunButtonKind.text,
                      onPressed: () async {
                        final result =
                            await discovery.inspect(_inspectPackage.text);
                        if (mounted) setState(() => _inspectResult = result);
                      },
                      label: '检查',
                    ),
                  ],
                ),
                if (_inspectResult != null) LText(_inspectResult!),
              ],
            ),
            if (_hostSigners != null) ...[
              const SizedBox(height: 8),
              _fold(
                key: const ValueKey('plugin-for-authors'),
                title: '给插件作者',
                children: _forAuthors(small),
              )
            ],
          ],
          if (_events.isNotEmpty) ...[
            const SizedBox(height: 16),
            ShunSection(title: '事件', children: [
              for (final line in _events)
                ShunSectionItem(child: Text(line, style: small)),
            ]),
          ],
        ],
      ),
    );
  }

  /// 页面顶上原来常驻的三段说明，收进 ⓘ。逐句本地化再拼：拼好的整段在英文表里查不到。
  String _about(String builtinNames) => [
        localized(
          '这里只列出声明了本 App 插件接口的已安装应用。批准之前不会启动它们的任何代码；'
          '插件是独立的 App，有自己的权限，本 App 管不住它自己联网。',
        ),
        '${localized('随 App 提供、不能停用：')}$builtinNames',
        localized('插件由你自己安装和卸载；本 App 不下载、不安装任何插件。装上、更新、卸载后这里会自动重新核对。'),
      ].join('\n\n');

  Widget _fold({
    required Key key,
    required String title,
    required List<Widget> children,
  }) =>
      ExpansionTile(
        key: key,
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        expandedAlignment: Alignment.centerLeft,
        shape: prism.AppShape.md,
        collapsedShape: prism.AppShape.md,
        backgroundColor: Theme.of(context).cardColor,
        collapsedBackgroundColor: Theme.of(context).cardColor,
        title: LText(title),
        children: children,
      );

  /// 插件作者要的两样：插件里写信任哪张宿主证书、宿主是哪个插件 API 版本（X12）。
  List<Widget> _forAuthors(TextStyle? small) {
    final signers = _hostSigners!;
    final api = localized('本 App 的插件 API：');
    return [
      Text('$api$hostApiMajor.$hostApiMinor', style: small),
      LText('本 App 的签名证书 SHA-256（插件里要写信任这一张）：', style: small),
      SelectableText(
        signers.isEmpty
            ? localized('读不出来')
            : signers.map((s) => s.sha256).join('\n'),
        key: const ValueKey('host-signers'),
        style: small,
      ),
      if (signers.any((s) => s.androidDebug))
        LText(
          '这是 Android 调试证书：换一台电脑构建，插件要按新证书重建。',
          style: small,
        ),
    ];
  }

  Widget _summary(PluginEntry entry) {
    final d = entry.descriptor;
    final package = entry.packageName!;
    final small = Theme.of(context).textTheme.bodySmall;
    return ShunListRow(
      key: ValueKey('plugin-entry-$package'),
      title: d?.displayName ?? package,
      localizeTitle: false,
      leading: const Icon(Icons.extension_outlined),
      details: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShunPill(localizedOf(context, pluginStatusLabel(entry.status))),
          Text('${d?.pluginId ?? package} · ${d?.version ?? '?'}',
              style: small),
          if (pluginReasonWorthShowing(entry) case final reason?)
            LText(reason, style: small),
        ],
      ),
      chevron: true,
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => PluginDetailScreen(packageName: package),
      )),
    );
  }
}
