import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

/// file_picker 在 Android 上把用户选的文件整份复制到 `cache/file_picker/<毫秒数>/<文件名>`
/// （10.3.10 `FileUtils.openFileStream`），只有调 `clearTemporaryFiles` 才删，重启也留着。
/// 不删的话，导入私钥或保险库 JSON 之后私有目录里就一直有一份明文，而凭据本该只在系统安全存储里
/// （R28 在模拟器上复现：导入私钥后，整个私有目录只有这一处能搜到私钥原文）。
///
/// 读完就调它，删掉 [file] 那一份和它的时间戳目录。只认 file_picker 自己的缓存目录，
/// 别的路径（用户自己的文件、别的平台）一律不碰。删不掉不报错：下次启动 [purgePickedCopies] 还会再清。
/// [cacheRoot] 只给测试用，默认是 App 的 cache 目录。
Future<void> discardPickedCopy(PlatformFile file,
    {Directory? cacheRoot}) async {
  final path = file.path;
  if (path == null) return;
  try {
    final root = await _pickerCache(cacheRoot);
    if (!path.startsWith('${root.path}/')) return;
    final copy = File(path);
    if (await copy.exists()) await copy.delete();
    final stamp = copy.parent;
    if (stamp.path != root.path && await stamp.list().isEmpty) {
      await stamp.delete();
    }
  } on Object {
    // 已经没了，或者删不掉；启动时整体再清一次。
  }
}

/// 启动时把 file_picker 的缓存目录整个清掉：以前的版本导入过私钥，副本还在那里。
/// 只在启动时整体清：这时没有上传在读这些副本，平时只删自己那一份（[discardPickedCopy]）。
Future<void> purgePickedCopies({Directory? cacheRoot}) async {
  if (cacheRoot == null && !Platform.isAndroid) return;
  try {
    final root = await _pickerCache(cacheRoot);
    if (await root.exists()) await root.delete(recursive: true);
  } on Object {
    // 清不掉不影响启动。
  }
}

Future<Directory> _pickerCache(Directory? cacheRoot) async => Directory(
    '${(cacheRoot ?? await getTemporaryDirectory()).path}/file_picker');
