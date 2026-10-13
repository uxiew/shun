import 'package:flutter/material.dart';

import '../localization/localized_widgets.dart';

/// Opaque imported connections are not interpreted by a supported-type form.
/// This page cannot produce an edited host or start any connection.
class UnsupportedConnectionPage extends StatelessWidget {
  const UnsupportedConnectionPage({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          leading: IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close)),
          title: const LText('不支持的连接类型'),
        ),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Text(label),
          const SizedBox(height: 12),
          const LText('此连接类型暂不支持，原配置已保留，不会改用 SSH。'),
          const SizedBox(height: 8),
          const LText('请在支持此类型的客户端中编辑；这里不会修改它的类型或设置。'),
        ]),
      );
}
