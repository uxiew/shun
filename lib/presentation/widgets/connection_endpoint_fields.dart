import 'package:flutter/material.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../domain/models/host.dart';
import '../localization/localized_widgets.dart';
import 'form_gap.dart';

/// Use the surface fill for idle fields; keep visible focus and error rings.
class ConnectionFieldTheme extends StatelessWidget {
  const ConnectionFieldTheme(
      {super.key, required this.child, this.dialog = false});

  final Widget child;
  final bool dialog;

  @override
  Widget build(BuildContext context) {
    final colors = prism.Theme.of(context).colorScheme;
    final level = dialog
        ? prism.SurfaceLevel.floatingOf(colors).next
        : prism.SurfaceContext(context).raisedSurfaceLevel;
    const outline = OutlineInputBorder(borderRadius: prism.AppRadius.md);
    return InputDecorationTheme(
      data: InputDecorationTheme.of(context).copyWith(
        filled: true,
        fillColor: level.colorOf(colors),
        border: outline,
        enabledBorder: outline.copyWith(borderSide: BorderSide.none),
      ),
      child: child,
    );
  }
}

/// Endpoint form only; the editor retains draft ownership and route validation.
/// 用户名不在这里：它属于认证，选了凭据就不用填（F31）。
class ConnectionEndpointFields extends StatelessWidget {
  const ConnectionEndpointFields(
      {super.key,
      required this.protocol,
      required this.hostname,
      required this.port});

  final HostProtocol protocol;
  final TextEditingController hostname, port;

  @override
  Widget build(BuildContext context) {
    final ssh = protocol == HostProtocol.ssh || protocol == HostProtocol.mosh;
    return Column(children: [
      const FormGap(),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
            flex: 2,
            child: TextFormField(
                controller: hostname,
                decoration: LInputDecoration(labelText: '主机名 / IP'),
                keyboardType: TextInputType.url,
                validator: _required)),
        const SizedBox(width: 12),
        Expanded(
            child: TextFormField(
                controller: port,
                decoration:
                    LInputDecoration(labelText: ssh ? 'SSH 端口' : 'Telnet 端口'),
                keyboardType: TextInputType.number,
                validator: (value) {
                  final parsed = int.tryParse(value ?? '');
                  return parsed == null || parsed < 1 || parsed > 65535
                      ? '端口无效'
                      : null;
                })),
      ]),
    ]);
  }

  static String? _required(String? value) =>
      value == null || value.trim().isEmpty ? '必填' : null;
}
