import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'application/app_log.dart';
import 'infrastructure/storage/picked_files.dart';
import 'infrastructure/storage/vault_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 日志（R26 F24）最先建：后面任何一步出错都要记得下来。上次的崩溃、系统退出原因在后台收，不拖启动。
  final appLog = AppLog(FileAppLogStore(appLogDirectory));
  installAppErrorCapture(appLog);
  unawaited(appLog.collectPlatform(const MethodChannelDiagnostics()));
  // 旧版本导入私钥、保险库时留在缓存里的明文副本（R28）。等它清完再起界面，免得清到刚选的文件。
  await purgePickedCopies();
  final repository = await VaultRepository.open();
  runApp(
    ProviderScope(
      overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
        appLogProvider.overrideWith((ref) => appLog),
      ],
      child: const ShunApp(),
    ),
  );
}
