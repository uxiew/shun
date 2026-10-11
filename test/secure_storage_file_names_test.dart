import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/external_remote.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/tailscale/catalog_secret_store.dart';

/// 照 flutter_secure_storage 9.2.4 Android 端的规则建模（FlutterSecureStorage.java ensureOptions）：
/// 一个进程里只有一个「当前文件」，只有调用带了非空 sharedPreferencesName 才切换，从不切回默认。
///
/// 为什么不走插件的 Dart 层：测试跑在 macOS 上，插件按 Platform.isMacOS 发的是 macOS 的选项，
/// Android 的选项根本不出现在 MethodChannel 上——那样测不到任何东西。所以直接拿代码里真实的
/// AndroidOptions 参数喂给这个模型。
class StickyFilePlugin {
  static const defaultFile = 'FlutterSecureStorage';
  final files = <String, Map<String, String>>{};
  var current = defaultFile;

  /// App 重启：当前文件回到默认，各文件里的内容都还在。
  void restart() => current = defaultFile;

  Map<String, String> _file(FlutterSecureStorage storage) {
    final name = storage.aOptions.params['sharedPreferencesName'] ?? '';
    if (name.isNotEmpty) current = name;
    return files.putIfAbsent(current, () => {});
  }

  void write(FlutterSecureStorage storage, String key, String value) =>
      _file(storage)[key] = value;
  String? read(FlutterSecureStorage storage, String key) => _file(storage)[key];
}

// R14 模拟器上撞到：先打开过 UU/RustDesk（它们的存储带文件名），再存主机密码，
// 密码写进了 UU 的文件；重启后保险库读自己的文件读不到，报「2 条无法解密」。
void main() {
  test('先用过 UU、RustDesk、目录的存储，再存主机密码：写进保险库自己的文件，重启后读得到', () {
    final plugin = StickyFilePlugin();
    final others = [
      SecureProviderBackend(prefsName: 'shun_uuremote', keychainAccount: 'a')
          .storage,
      SecureProviderBackend(prefsName: 'shun_rustdesk', keychainAccount: 'b')
          .storage,
      FlutterSecureCatalogBackend.storage,
    ];
    for (final other in others) {
      plugin.read(other, 'anything');
      plugin.write(vaultSecureStorage, 'host.h1.password', 's3cret');
      expect(plugin.files[StickyFilePlugin.defaultFile]?['host.h1.password'],
          's3cret');
      plugin.files.forEach((name, file) {
        if (name != StickyFilePlugin.defaultFile) {
          expect(file.containsKey('host.h1.password'), isFalse,
              reason: '保险库的密码混进了 $name');
        }
      });
      plugin.restart();
      expect(plugin.read(vaultSecureStorage, 'host.h1.password'), 's3cret');
      plugin.files.clear();
    }
  });

  test('lib 里每一处 FlutterSecureStorage 都显式写了文件名', () {
    // 有一处不写，它就会跟着别人的文件名走（见上面的假插件）。新增存储时漏写，这条会红。
    final missing = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      for (final match
          in RegExp(r'FlutterSecureStorage\(').allMatches(source)) {
        final end = (match.end + 600).clamp(0, source.length);
        if (!source
            .substring(match.end, end)
            .contains('sharedPreferencesName:')) {
          final line =
              '\n'.allMatches(source.substring(0, match.start)).length + 1;
          missing.add('${entity.path}:$line');
        }
      }
    }
    expect(missing, isEmpty, reason: missing.join('\n'));
  });
}
