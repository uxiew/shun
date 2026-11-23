import 'package:flutter/material.dart';

import '../../domain/connection_route.dart';
import '../localization/localized_widgets.dart';
import '../ui/components.dart';

Future<bool?> showJumpRouteChoice(
        BuildContext context, JumpRouteProposal proposal) =>
    showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const LText('确认跳板路线'),
              content: SingleChildScrollView(
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    const LText('展开后的跳板顺序：'),
                    for (var i = 0; i < proposal.labels.length; i++)
                      Text('${i + 1}. ${proposal.labels[i]}'),
                    const LText('只修改当前路线，不修改原跳板主机。'),
                    if (proposal.hasFirstProxy) ...[
                      const LText('首跳自带代理：'),
                      Text(proposal.proxyDescription!),
                      const LText('请选择也经这个代理，或直连这台跳板机；这会替换当前入口代理。'),
                    ],
                  ])),
              actions: [
                ShunButton(
                    kind: ShunButtonKind.text,
                    onPressed: () => Navigator.pop(context),
                    label: '取消'),
                ShunButton(
                    kind: proposal.hasFirstProxy
                        ? ShunButtonKind.tonal
                        : ShunButtonKind.filled,
                    key: const ValueKey('route-choice-direct'),
                    onPressed: () => Navigator.pop(context, false),
                    label: proposal.hasFirstProxy ? '直连这台跳板机' : '展开并使用此路线'),
                if (proposal.hasFirstProxy)
                  ShunButton(
                      kind: ShunButtonKind.tonal,
                      key: const ValueKey('route-choice-proxy'),
                      onPressed: () => Navigator.pop(context, true),
                      label: '也经这个代理'),
              ],
            ));
