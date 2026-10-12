import 'package:flutter/material.dart';

import '../../domain/connection_route.dart';
import '../../domain/models/host.dart';
import '../../domain/route_description.dart';
import '../localization/localized_widgets.dart';
import 'connection_route_draft.dart';
import 'route_legs_view.dart';
import 'jump_route_choice_dialog.dart';

/// A chain editor over the same RoutePlan used for connecting. Incomplete or
/// invalid drafts remain editable, but are never presented as validated routes.
/// Persistence and proxy navigation are supplied by the owner.
class ConnectionRouteEditor extends StatefulWidget {
  const ConnectionRouteEditor(
      {super.key,
      required this.draft,
      required this.hosts,
      required this.profiles,
      required this.onChanged,
      required this.onSelectProxy,
      required this.onManageProxies,
      this.plan,
      this.canConfirmRoutes = true,
      this.error,
      this.warnings = const [],
      this.targetHostId,
      required this.targetLabel,
      this.targetDetail = ''});

  final ConnectionRouteDraft draft;
  final List<HostProfile> hosts;
  final List<ProxyProfile> profiles;
  final VoidCallback onChanged, onManageProxies;
  final Future<String?> Function(Map<String, dynamic>? inline) onSelectProxy;
  final RoutePlan? plan;
  final bool canConfirmRoutes;
  final String? error, targetHostId;
  final List<String> warnings;
  final String targetLabel, targetDetail;

  @override
  State<ConnectionRouteEditor> createState() => _ConnectionRouteEditorState();
}

class _ConnectionRouteEditorState extends State<ConnectionRouteEditor> {
  bool _selecting = false;
  String? _choiceError;
  ConnectionRouteDraft get draft => widget.draft;
  void _change(VoidCallback change) {
    draft.invalidateChoices();
    _choiceError = null;
    change();
    widget.onChanged();
  }

  Future<void> _select({bool convert = false}) async {
    if (_selecting) return;
    setState(() => _selecting = true);
    try {
      final inline = draft.inlineProxy;
      final id = await widget.onSelectProxy(
          convert && inline is Map ? Map<String, dynamic>.from(inline) : null);
      if (mounted && id != null) _change(() => draft.selectProxy(id));
    } finally {
      if (mounted) setState(() => _selecting = false);
    }
  }

  Future<void> _confirmRoutes() async {
    if (_selecting || !widget.canConfirmRoutes) return;
    setState(() {
      _selecting = true;
      _choiceError = null;
    });
    try {
      JumpRouteProposal propose() =>
          proposeJumpRouteChoice(draft.choiceTarget(widget.targetHostId),
              hosts: widget.hosts, proxyProfiles: widget.profiles);
      final shown = propose();
      final useProxy = await showJumpRouteChoice(context, shown);
      if (!mounted || useProxy == null) return;
      final current = propose();
      if (!widget.canConfirmRoutes || !shown.sameRevision(current)) {
        throw const RouteConfigException('跳板路线确认已失效，请重新确认。');
      }
      _change(() => draft.applyChoice(current.select(useFirstProxy: useProxy)));
    } on RouteConfigException catch (error) {
      if (mounted) setState(() => _choiceError = error.message);
    } finally {
      if (mounted) setState(() => _selecting = false);
    }
  }

  Widget _node(RouteLeg leg, int index, {List<Widget> actions = const []}) =>
      Card(
          child: Padding(
              padding: const EdgeInsets.all(10),
              child:
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(RouteLegsView.iconFor(leg.kind)),
                const SizedBox(width: 10),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      LText('${index + 1}. ${leg.title}'),
                      if (leg.detail.isNotEmpty)
                        LText(leg.detail,
                            style: Theme.of(context).textTheme.bodySmall),
                      if (actions.isNotEmpty)
                        Wrap(spacing: 4, children: actions),
                    ])),
              ])));

  List<RouteLeg> _draftLegs() {
    final config = draft.selectedProxyConfig;
    final profile =
        widget.profiles.where((p) => p.id == draft.proxyProfileId).firstOrNull;
    return [
      const RouteLeg(RouteLegKind.phone, '手机'),
      if (draft.usesProxy)
        RouteLeg(
            RouteLegKind.proxy,
            draft.proxyProfileId != null
                ? (profile?.label ?? '代理配置缺失')
                : '主机自带代理',
            profile != null
                ? '${profile.config?.host ?? ''}:${profile.config?.port ?? ''}'
                : config == null
                    ? ''
                    : '${config.host}:${config.port}'),
      for (final id in draft.jumpHostIds)
        RouteLeg(
            RouteLegKind.jump,
            widget.hosts.where((h) => h.id == id).firstOrNull?.label ??
                '缺失的主机'),
      RouteLeg(RouteLegKind.target, widget.targetLabel, widget.targetDetail),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final legs =
        widget.plan == null ? _draftLegs() : describeRoute(widget.plan!);
    final candidates = widget.hosts
        .where((h) =>
            h.id != widget.targetHostId &&
            h.protocol == HostProtocol.ssh &&
            !draft.jumpHostIds.contains(h.id))
        .toList();
    var jumpIndex = 0;
    return Column(
        key: const ValueKey('route-preview'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(spacing: 8, children: [
            TextButton(
                onPressed: widget.onManageProxies, child: const LText('代理管理')),
            if (draft.usesProxy ||
                draft.jumpHostIds.isNotEmpty ||
                widget.error != null)
              TextButton(
                  key: const ValueKey('route-clear'),
                  onPressed: () => _change(draft.clear),
                  child: const LText('清空路线')),
          ]),
          if (draft.jumpHostIds.any((id) {
            final host =
                widget.hosts.where((host) => host.id == id).firstOrNull;
            return host != null &&
                (host.proxyProfileId?.isNotEmpty == true ||
                    host.data['proxyConfig'] != null ||
                    host.data['hostChain'] != null);
          })) ...[
            const LText('跳板自带路线需要明确确认；展开后仍最多 3 跳，后续跳板不能自带代理。'),
            if (!widget.canConfirmRoutes)
              const LText('代理凭据尚未就绪，请等待加载或修复无法读取的凭据。'),
            TextButton(
                key: const ValueKey('route-confirm-jumps'),
                onPressed: _selecting || !widget.canConfirmRoutes
                    ? null
                    : _confirmRoutes,
                child: const LText('检查并展开跳板路线')),
          ],
          if (_choiceError != null)
            LText(_choiceError!,
                key: const ValueKey('route-choice-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          LText(widget.plan != null && widget.error == null
              ? '连接时会这样走'
              : '路线草稿（尚未通过校验）'),
          Column(key: const ValueKey('route-legs'), children: [
            for (var index = 0; index < legs.length; index++) ...[
              if (index > 0) const Icon(Icons.arrow_downward, size: 18),
              if (legs[index].kind == RouteLegKind.jump)
                _jumpNode(legs[index], index, jumpIndex++)
              else
                _node(legs[index], index, actions: [
                  if (legs[index].kind == RouteLegKind.phone &&
                      !draft.usesProxy)
                    TextButton(
                        key: const ValueKey('route-add-proxy'),
                        onPressed: _selecting ? null : () => _select(),
                        child: const LText('添加代理')),
                  if (legs[index].kind == RouteLegKind.proxy) ...[
                    TextButton(
                        key: const ValueKey('route-change-proxy'),
                        onPressed: _selecting ? null : () => _select(),
                        child: const LText('更换代理')),
                    TextButton(
                        key: const ValueKey('route-remove-proxy'),
                        onPressed: () => _change(draft.removeProxy),
                        child: const LText('移除代理')),
                    if (draft.inlineProxy is Map)
                      TextButton(
                          key: const ValueKey('route-save-inline'),
                          onPressed:
                              _selecting ? null : () => _select(convert: true),
                          child: const LText('存为可复用代理')),
                  ],
                ]),
              // Insert a jump immediately before the target, regardless of entry.
              if (index == legs.length - 2 &&
                  draft.jumpHostIds.length < maxJumpHosts)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: DropdownButtonFormField<String>(
                      key: ValueKey('add-jump-${draft.jumpHostIds.join(',')}'),
                      isExpanded: true,
                      decoration: LInputDecoration(labelText: '添加跳板机'),
                      items: [
                        for (final h in candidates)
                          DropdownMenuItem(
                              value: h.id,
                              child: Text(h.label,
                                  overflow: TextOverflow.ellipsis))
                      ],
                      onChanged: (id) {
                        if (id != null) _change(() => draft.addJump(id));
                      },
                    )),
            ],
          ]),
          if (draft.usesProxy) const LText('代理只用于手机连第一跳；后续由上一台跳板转发。'),
          if (draft.usesProxy)
            const LText('代理的用户名和密码是明文发给代理的：SSH 只加密之后的终端会话，保护不了这段口令。'),
          if (widget.error != null)
            LText(widget.error!,
                key: const ValueKey('route-preview-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          for (final warning in widget.warnings)
            LText(warning, key: const ValueKey('route-preview-warning')),
        ]);
  }

  Widget _jumpNode(RouteLeg leg, int nodeIndex, int index) =>
      _node(leg, nodeIndex, actions: [
        IconButton(
            key: ValueKey('jump-up-$index'),
            tooltip: localized('上移'),
            onPressed: index == 0
                ? null
                : () => _change(() {
                      final id = draft.jumpHostIds.removeAt(index);
                      draft.jumpHostIds.insert(index - 1, id);
                    }),
            icon: const Icon(Icons.arrow_upward)),
        IconButton(
            key: ValueKey('jump-down-$index'),
            tooltip: localized('下移'),
            onPressed: index == draft.jumpHostIds.length - 1
                ? null
                : () => _change(() {
                      final id = draft.jumpHostIds.removeAt(index);
                      draft.jumpHostIds.insert(index + 1, id);
                    }),
            icon: const Icon(Icons.arrow_downward)),
        IconButton(
            key: ValueKey('jump-remove-$index'),
            tooltip: localized('移除跳板机'),
            onPressed: () => _change(() => draft.jumpHostIds.removeAt(index)),
            icon: const Icon(Icons.remove_circle_outline)),
      ]);
}
