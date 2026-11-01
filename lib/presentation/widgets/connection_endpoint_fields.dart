import 'package:flutter/material.dart';

import '../../domain/models/host.dart';
import '../localization/localized_widgets.dart';
import 'form_gap.dart';

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
