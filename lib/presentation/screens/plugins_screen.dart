import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/plugin_discovery.dart';
import '../../application/plugin_registry.dart';
import '../../infrastructure/plugins/android_plugin_bridge.dart';
import '../localization/localized_widgets.dart';

/// 独立插件 APK 的最小管理页（X02）：发现、批准、撤销、连接测试。
/// 完整的插件管理（启停、更新/卸载检测、设置入口）在 X04。
class PluginsScreen extends ConsumerStatefulWidget {
  const PluginsScreen({super.key});

  @override
  ConsumerState<PluginsScreen> createState() => _PluginsScreenState();
}

class _PluginsScreenState extends ConsumerState<PluginsScreen> {
  final _inspectPackage = TextEditingController();
  final _results = <String, String>{};
  final _events = <String>[];
  final _connected = <String>{};
  StreamSubscription<PluginBridgeEvent>? _subscription;
  PluginDiscovery? _discovery;
  String? _inspectResult;
  String? _error;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    final discovery = await ref.read(pluginDiscoveryProvider.future);
    if (!mounted) return;
    _discovery = discovery;
    _subscription = discovery.events.listen((event) {
      if (!mounted) return;
      setState(() {
        if (event.type == 'closed') _connected.remove(event.packageName);
        _events.insert(0,
            '${_eventLabel(event.type)} · ${event.packageName} · ${event.detail}');
        if (_events.length > 30) _events.removeLast();
      });
    });
    await _refresh();
  }

  static String _eventLabel(String type) => switch (type) {
        'providerEvent' => '插件回报',
        'rejectedCall' => '已拒绝调用',
        'closed' => '连接关闭',
        _ => type,
      };

  Future<void> _refresh() async {
    final discovery = _discovery;
    if (discovery == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await discovery.refresh();
    } on Object catch (e) {
      _error = '$e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    final discovery = _discovery;
    if (discovery != null) {
      for (final package in _connected) {
        unawaited(discovery.disconnect(package));
      }
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
    final builtinNames =
        builtin.map((e) => e.descriptor!.displayName).join('、');
    return Scaffold(
      appBar: AppBar(
        title: const LText('插件（实验）'),
        actions: [
          IconButton(
            tooltip: localized('重新扫描'),
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const LText(
            '这里只列出声明了本 App 插件接口的已安装应用。批准之前不会启动它们的任何代码；'
            '插件是独立的 App，有自己的权限，本 App 管不住它自己联网。',
          ),
          const SizedBox(height: 8),
          LText(
            '随 App 提供、不能停用：$builtinNames',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (discovery != null && !discovery.supported)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: LText('独立插件只支持 Android'),
            ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) LText('扫描失败：$_error'),
          if (discovery != null &&
              discovery.supported &&
              external.isEmpty &&
              !_busy)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: LText('没有发现插件'),
            ),
          for (final entry in external) _entryCard(entry),
          if (discovery != null && discovery.supported) ...[
            const SizedBox(height: 16),
            const LText('某个应用没出现在这里？'),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inspectPackage,
                    decoration: InputDecoration(labelText: localized('包名')),
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    final result =
                        await discovery.inspect(_inspectPackage.text);
                    if (mounted) setState(() => _inspectResult = result);
                  },
                  child: const LText('检查'),
                ),
              ],
            ),
            if (_inspectResult != null) LText(_inspectResult!),
          ],
          if (_events.isNotEmpty) ...[
            const SizedBox(height: 16),
            const LText('事件'),
            for (final line in _events)
              LText(line, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }

  static String _statusLabel(PluginStatus status) => switch (status) {
        PluginStatus.ready => '可用',
        PluginStatus.needsApproval => '待批准',
        PluginStatus.rejected => '已拒绝',
        PluginStatus.incompatible => '不兼容',
        PluginStatus.disabled => '已停用',
        PluginStatus.missing => '已卸载',
      };

  Widget _entryCard(PluginEntry entry) {
    final d = entry.descriptor;
    final package = entry.packageName!;
    final digest = entry.signerDigests.isEmpty
        ? '—'
        : entry.signerDigests.map((s) => '${s.substring(0, 16)}…').join(', ');
    final discovery = _discovery!;
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    d?.displayName ?? package,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Chip(label: LText(_statusLabel(entry.status))),
              ],
            ),
            SelectableText(
              '${d?.pluginId ?? '?'} · $package · ${d?.version ?? '?'}',
            ),
            LText('证书 SHA-256：$digest'),
            if (entry.androidDebugSigned)
              const LText('用 Android 调试证书签名：只有开发构建能用'),
            if (d != null)
              LText('能力：${d.capabilities.map((c) => c.wire).join('、')}'),
            if (entry.reason != null) LText(entry.reason!),
            if (_results[package] != null) LText(_results[package]!),
            Wrap(
              spacing: 8,
              children: [
                if (entry.status == PluginStatus.needsApproval)
                  FilledButton(
                    onPressed: () => _approve(entry),
                    child: const LText('批准'),
                  ),
                if (entry.status == PluginStatus.ready ||
                    entry.status == PluginStatus.disabled)
                  OutlinedButton(
                    onPressed: () async {
                      await discovery.revoke(entry);
                      if (mounted) setState(() => _connected.remove(package));
                    },
                    child: const LText('撤销批准'),
                  ),
                OutlinedButton(
                  onPressed: () async {
                    setState(() => _results[package] = localized('正在连接…'));
                    final result = await discovery.check(entry);
                    if (!mounted) return;
                    setState(() {
                      _results[package] = result;
                      if (entry.status == PluginStatus.ready) {
                        _connected.add(package);
                      }
                    });
                  },
                  child: const LText('连接测试'),
                ),
                if (_connected.contains(package))
                  TextButton(
                    onPressed: () async {
                      await discovery.disconnect(package);
                      if (mounted) setState(() => _connected.remove(package));
                    },
                    child: const LText('断开'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _approve(PluginEntry entry) async {
    final d = entry.descriptor!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const LText('批准这个插件？'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(
                  '${d.displayName}\n${d.pluginId}\n${entry.packageName}'),
              const SizedBox(height: 8),
              const LText('签名证书 SHA-256（请与插件作者公布的核对）：'),
              SelectableText(entry.signerDigests.join('\n')),
              if (entry.androidDebugSigned)
                const LText('这是 Android 调试证书：每台开发机都有一张，任何人都能用它签名。'),
              const SizedBox(height: 8),
              LText('能力：${d.capabilities.map((c) => c.wire).join('、')}'),
              const SizedBox(height: 8),
              const LText(
                '批准后它能收到自己会话里的数据，拿不到保险库、私钥、密码或其他主机。'
                '以后换了签名证书或申请新能力，会重新请你确认。',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const LText('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const LText('批准'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _discovery!.approve(entry);
    } on PluginApprovalRefused catch (e) {
      if (mounted) setState(() => _results[entry.packageName!] = e.message);
    }
  }
}
