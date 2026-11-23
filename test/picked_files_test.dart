import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/infrastructure/storage/picked_files.dart';

// R28 / SEC05：选择器留在缓存里的明文副本要删，而且只删它自己目录里的。
// 设备上的复现和修后复测见 plan/v3/evidence/R28.md。
void main() {
  late Directory cache;
  setUp(() async => cache = await Directory.systemTemp.createTemp('r28-cache'));
  tearDown(() => cache.delete(recursive: true));

  File copyAt(String stamp, String name) =>
      File('${cache.path}/file_picker/$stamp/$name')
        ..createSync(recursive: true)
        ..writeAsStringSync('-----BEGIN OPENSSH PRIVATE KEY-----');

  PlatformFile picked(File file) =>
      PlatformFile(name: file.uri.pathSegments.last, size: 1, path: file.path);

  test('删掉这一份和它的时间戳目录，别的副本不动', () async {
    final mine = copyAt('1793341872131', 'id_ed25519');
    final other = copyAt('1793341872999', 'upload.bin');
    await discardPickedCopy(picked(mine), cacheRoot: cache);
    expect(mine.existsSync(), isFalse);
    expect(mine.parent.existsSync(), isFalse);
    expect(other.existsSync(), isTrue, reason: '另一个可能正在上传');
  });

  test('不在 file_picker 缓存目录里的路径不碰，路径里带 file_picker 字样也不行', () async {
    final outside = File('${cache.path}/Documents/file_picker/keep/id_rsa')
      ..createSync(recursive: true);
    final sibling = File('${cache.path}/file_picker-other/x')
      ..createSync(recursive: true);
    for (final file in [outside, sibling]) {
      await discardPickedCopy(picked(file), cacheRoot: cache);
      expect(file.existsSync(), isTrue, reason: file.path);
    }
    await discardPickedCopy(PlatformFile(name: 'x', size: 0), cacheRoot: cache);
  });

  test('启动时整个清掉，没有目录也不报错', () async {
    copyAt('1', 'a');
    copyAt('2', 'b');
    await purgePickedCopies(cacheRoot: cache);
    expect(Directory('${cache.path}/file_picker').existsSync(), isFalse);
    await purgePickedCopies(cacheRoot: cache);
  });
}
