import 'package:flutter/material.dart';

import '../../domain/connection_route.dart';
import '../../domain/models/host.dart';
import '../localization/localized_widgets.dart';
import 'connection_route_draft.dart';

/// Preserve the two existing presentations during the first R40 extraction.
/// This selects rendering only; route resolution remains resolveRoutePlan.
enum ConnectionRouteEditorPresentation { host, catalogImport }

class ConnectionRouteEditor extends StatelessWidget {
  const ConnectionRouteEditor(
      {super.key,
      required this.draft,
      required this.hosts,
      required this.profiles,
      required this.onChanged,
      required this.presentation,
      this.targetHostId,
      this.requiredValidator,
      this.portValidator});

  final ConnectionRouteDraft draft;
  final List<HostProfile> hosts;
  final List<ProxyProfile> profiles;
  final VoidCallback onChanged;
  final ConnectionRouteEditorPresentation presentation;
  final String? targetHostId;
  final FormFieldValidator<String>? requiredValidator, portValidator;

  bool get _host => presentation == ConnectionRouteEditorPresentation.host;
  void _change(VoidCallback change) {
    change();
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SegmentedButton<ConnectionRouteMode>(
        key: _host ? const ValueKey('route-mode') : null,
        segments: [
          ButtonSegment(
              value: ConnectionRouteMode.direct,
              label: const LText('直连'),
              icon: _host ? const Icon(Icons.arrow_forward) : null),
          ButtonSegment(
              value: ConnectionRouteMode.proxy,
              label: const LText('经代理'),
              icon: _host ? const Icon(Icons.public) : null),
          ButtonSegment(
              value: ConnectionRouteMode.jump,
              label: const LText('经跳板机'),
              icon: _host ? const Icon(Icons.alt_route) : null),
        ],
        selected: {draft.mode},
        onSelectionChanged: (value) => _change(() => draft.mode = value.first),
      ),
      SizedBox(height: _host ? 8 : 4),
      if (draft.mode == ConnectionRouteMode.direct)
        LText(
            _host
                ? '手机直接连目标，不经过 App 的代理；你开着的 VPN 照常生效。'
                : '手机直接连设备地址。连 100.x 这类 Tailscale 地址，手机上要开着官方 Tailscale App——本 App 不会替你开。',
            style: small),
      if (draft.mode == ConnectionRouteMode.jump) ..._jumpFields(small),
      if (draft.usesProxy) ..._proxyFields(small),
    ]);
  }

  List<Widget> _jumpFields(TextStyle? small) {
    final candidates = hosts
        .where((host) =>
            host.id != targetHostId &&
            host.protocol == HostProtocol.ssh &&
            !draft.jumpHostIds.contains(host.id))
        .toList();
    HostProfile? find(String id) => hosts.where((h) => h.id == id).firstOrNull;
    final dropdown = DropdownButtonFormField<String>(
      key: _host
          ? const ValueKey('add-jump-host')
          : ValueKey('catalog-import-jump-${draft.jumpHostIds.length}'),
      decoration: LInputDecoration(
          labelText: '添加跳板机',
          prefixIcon: _host ? const Icon(Icons.add_road) : null),
      items: [
        for (final host in candidates)
          DropdownMenuItem(
              value: host.id,
              child: _host ? LText(host.label) : Text(host.label))
      ],
      onChanged: (value) {
        if (value != null) _change(() => draft.jumpHostIds.add(value));
      },
    );
    return [
      if (_host) ...[
        if (draft.jumpHostIds.isEmpty)
          const LText('还没有选跳板机：从下面添加，按连接顺序排列（最多 3 台）。',
              style: TextStyle(color: Colors.redAccent, fontSize: 12))
        else
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: draft.jumpHostIds.length,
            onReorderItem: (oldIndex, newIndex) => _change(() {
              final id = draft.jumpHostIds.removeAt(oldIndex);
              draft.jumpHostIds.insert(newIndex, id);
            }),
            itemBuilder: (context, index) {
              final id = draft.jumpHostIds[index];
              final jump = find(id);
              return ListTile(
                  key: ValueKey(id),
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(child: LText('${index + 1}')),
                  title: LText(jump?.label ?? '缺失的主机'),
                  subtitle: LText(jump == null
                      ? id
                      : '${jump.username}@${jump.hostname}:${jump.port}'),
                  trailing: IconButton(
                      onPressed: () =>
                          _change(() => draft.jumpHostIds.removeAt(index)),
                      icon: const Icon(Icons.remove_circle_outline)));
            },
          ),
        if (candidates.isNotEmpty)
          // Reset the selected value when its host disappears from candidates.
          KeyedSubtree(
              key: ValueKey('add-jump-${draft.jumpHostIds.length}'),
              child: dropdown),
      ] else ...[
        LText('按连接顺序选保险库里的主机做跳板机，最多 3 台。', style: small),
        Wrap(spacing: 8, children: [
          for (final (index, id) in draft.jumpHostIds.indexed)
            InputChip(
                label: Text('${index + 1}. ${find(id)?.label ?? id}'),
                onDeleted: () => _change(() => draft.jumpHostIds.remove(id)))
        ]),
        if (draft.jumpHostIds.length < maxJumpHosts) dropdown,
      ],
      SwitchListTile(
        key: _host ? const ValueKey('entry-proxy-switch') : null,
        contentPadding: EdgeInsets.zero,
        title: const LText('先经代理连第一台跳板机（高级）'),
        subtitle: const LText('代理只用于手机连第一台跳板机；之后每一跳由上一跳转发，不再经过代理。'),
        value: draft.entryProxy,
        onChanged: (value) => _change(() => draft.entryProxy = value),
      ),
    ];
  }

  List<Widget> _proxyFields(TextStyle? small) {
    final custom = const DropdownMenuItem(
      value: 'custom',
      child: LText('自定义 HTTP / SOCKS5 代理'),
    );
    final saved = [
      for (final profile in profiles)
        DropdownMenuItem(
            value: 'profile:${profile.id}',
            child:
                _host ? LText('已保存 · ${profile.label}') : Text(profile.label))
    ];
    final address = _proxyText(
        controller: draft.proxyHost,
        label: '代理地址',
        key: ValueKey(_host ? 'proxy-host' : 'catalog-import-proxy-host'),
        validator: requiredValidator,
        autocorrect: _host);
    final port = _proxyText(
        controller: draft.proxyPort,
        label: '代理端口',
        key: ValueKey(_host ? 'proxy-port' : 'catalog-import-proxy-port'),
        validator: portValidator,
        keyboardType: TextInputType.number);
    return [
      if (_host) const SizedBox(height: 8),
      DropdownButtonFormField<String>(
        key: _host ? null : const ValueKey('catalog-import-proxy'),
        initialValue: draft.proxyMode.isEmpty ? null : draft.proxyMode,
        decoration: LInputDecoration(labelText: '代理'),
        items: _host ? [custom, ...saved] : [...saved, custom],
        onChanged: (value) =>
            _change(() => draft.proxyMode = value ?? (_host ? 'custom' : '')),
      ),
      if (!_host && profiles.isEmpty)
        LText('还没有保存的代理配置（目前只能从桌面端导入）。可以选「自定义」。', style: small),
      if (draft.proxyMode == 'custom') ...[
        if (_host) const SizedBox(height: 12),
        SegmentedButton<ProxyType>(
            segments: const [
              ButtonSegment(value: ProxyType.socks5, label: LText('SOCKS5')),
              ButtonSegment(value: ProxyType.http, label: LText('HTTP')),
            ],
            selected: {
              draft.proxyType
            },
            onSelectionChanged: (value) =>
                _change(() => draft.proxyType = value.first)),
        if (_host) ...[
          const SizedBox(height: 12),
          Row(children: [
            Expanded(flex: 2, child: address),
            const SizedBox(width: 12),
            Expanded(child: port)
          ]),
          const SizedBox(height: 12),
        ] else ...[
          address,
          port
        ],
        _proxyText(
            controller: draft.proxyUsername,
            label: '代理用户名（可选）',
            autocorrect: _host),
        if (_host) const SizedBox(height: 12),
        _proxyText(
            controller: draft.proxyPassword,
            label: '代理密码（可选）',
            obscureText: _host ? draft.obscureProxyPassword : true,
            autocorrect: _host,
            enableSuggestions: _host,
            suffixIcon: _host
                ? IconButton(
                    onPressed: () => _change(() => draft.obscureProxyPassword =
                        !draft.obscureProxyPassword),
                    icon: Icon(draft.obscureProxyPassword
                        ? Icons.visibility
                        : Icons.visibility_off))
                : null),
      ],
      if (_host || draft.proxyMode == 'custom') ...[
        if (_host) const SizedBox(height: 8),
        LText(
            '代理的用户名和密码是明文发给代理的：SSH 只加密之后的终端会话，保护不了这段口令。'
            '${_host ? '远程代理请只在可信网络（比如你自己的 VPN）里使用。' : ''}',
            style: small),
      ],
    ];
  }

  Widget _proxyText(
      {required TextEditingController controller,
      required String label,
      Key? key,
      FormFieldValidator<String>? validator,
      TextInputType? keyboardType,
      bool obscureText = false,
      bool autocorrect = true,
      bool enableSuggestions = true,
      Widget? suffixIcon}) {
    final decoration =
        LInputDecoration(labelText: label, suffixIcon: suffixIcon);
    if (_host) {
      return TextFormField(
          key: key,
          controller: controller,
          decoration: decoration,
          validator: validator,
          keyboardType: keyboardType,
          obscureText: obscureText);
    }
    return TextField(
        key: key,
        controller: controller,
        decoration: decoration,
        keyboardType: keyboardType,
        obscureText: obscureText,
        autocorrect: autocorrect,
        enableSuggestions: enableSuggestions,
        onChanged: (_) => onChanged());
  }
}
