import 'dart:io';

import 'package:plugin_api/plugin_api.dart';

/// 插件作者在构建前自查描述符：
///
///   cd packages/plugin_api && dart pub get
///   dart run bin/check_descriptor.dart <描述符.json> [--package <applicationId>] [--service <服务类全名>]
///
/// 通过退出码 0，不通过 1，用法不对 2。报出来的话和宿主插件页上的一致（同一套判定代码）。
/// 它不查证书和用户批准：那些要装到设备上才知道。
void main(List<String> args) {
  String? file;
  String? package;
  String? service;
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if ((arg == '--package' || arg == '--service') && i + 1 < args.length) {
      final value = args[++i];
      if (arg == '--package') {
        package = value;
      } else {
        service = value;
      }
    } else if (!arg.startsWith('--') && file == null) {
      file = arg;
    } else {
      file = null;
      break;
    }
  }
  if (file == null) {
    stderr.writeln(
      '用法：dart run bin/check_descriptor.dart <描述符.json> '
      '[--package <applicationId>] [--service <服务类全名>]',
    );
    exit(2);
  }
  final String json;
  try {
    json = File(file).readAsStringSync();
  } on FileSystemException catch (e) {
    stderr.writeln('读不了 $file：${e.osError?.message ?? e.message}');
    exit(2);
  }

  final result = AuthorCheck.run(
    json,
    packageName: package,
    serviceClass: service,
  );
  final d = result.descriptor;
  if (d != null) {
    stdout
      ..writeln(
        '${d.pluginId} ${d.version}（API ${d.apiMajor}.${d.apiMinor}，'
        '${d.deployment.wire}）',
      )
      ..writeln('  能力：${d.capabilities.map((c) => c.wire).join('、')}')
      ..writeln('  路线：${d.supportedRoutes.map((r) => r.wire).join('、')}')
      ..writeln('  权限：${d.permissions.map((p) => p.wire).join('、')}')
      ..writeln('  包名：${d.packageName ?? '—'}')
      ..writeln('  服务：${d.serviceClass ?? '—'}');
  }
  for (final w in result.warnings) {
    stdout.writeln('提醒：$w');
  }
  for (final e in result.errors) {
    stdout.writeln('不通过：$e');
  }
  if (result.ok) {
    stdout.writeln('通过（宿主 API $hostApiMajor.$hostApiMinor 的判定）。证书和批准要装到设备上再看。');
  }
  exit(result.ok ? 0 : 1);
}
