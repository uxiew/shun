import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'infrastructure/storage/picked_files.dart';
import 'infrastructure/storage/vault_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 旧版本导入私钥、保险库时留在缓存里的明文副本（R28）。等它清完再起界面，免得清到刚选的文件。
  await purgePickedCopies();
  final repository = await VaultRepository.open();
  runApp(
    ProviderScope(
      overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
      child: const ShunApp(),
    ),
  );
}
