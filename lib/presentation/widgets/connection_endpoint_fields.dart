import 'package:flutter/material.dart';

import '../../domain/models/host.dart';
import '../localization/localized_widgets.dart';

/// Endpoint form only; the editor retains draft ownership and route validation.
/// Hidden SSH identity remains in its controller when switching protocols.
class ConnectionEndpointFields extends StatelessWidget {
  const ConnectionEndpointFields(
      {super.key,
      required this.protocol,
      required this.hostname,
      required this.username,
      required this.port});

  final HostProtocol protocol;
  final TextEditingController hostname, username, port;

  @override
  Widget build(BuildContext context) {
    final ssh = protocol == HostProtocol.ssh || protocol == HostProtocol.mosh;
    return Column(children: [
      const SizedBox(height: 12),
      TextFormField(
          controller: hostname,
          decoration: LInputDecoration(labelText: '主机名 / IP'),
          keyboardType: TextInputType.url,
          validator: _required),
      const SizedBox(height: 12),
      Row(children: [
        if (ssh) ...[
          Expanded(
              flex: 2,
              child: TextFormField(
                  controller: username,
                  decoration: LInputDecoration(labelText: '用户名'),
                  validator: _required)),
          const SizedBox(width: 12),
        ],
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
