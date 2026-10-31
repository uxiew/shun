import 'dart:async';

import 'package:dartssh2/dartssh2.dart';

/// 每条 SSH 连接用的算法偏好。只改加密算法的顺序，其余用 dartssh2 的默认。
///
/// dartssh2 4.1.0 默认把 AES-GCM 排第一，但它是纯 Dart 实现，很慢。实测（R58，Mac arm64 原生编译，
/// 连 Docker 里的 OpenSSH，33 MB 终端文本）：aes256-gcm 1.1 MB/s，aes128-ctr 8.3 MB/s，
/// chacha20-poly1305 19.8 MB/s。不改顺序的话，`cat` 大文件会比 2.22.5 慢 7 倍。
/// GCM 放最后是给只开 GCM 的服务器留的路。字节内容和回显延迟不受算法影响。
///
/// CBC 不在表里：4.0.0 起默认关了，只认 CBC 的老设备会报 [isAlgorithmMismatch]。
/// 改了顺序要重跑 `test/ssh_client_defaults_test.dart`，数字见 plan/v3/evidence/R58.md。
const shunSshAlgorithms = SSHAlgorithms(
  cipher: [
    SSHCipherType.chacha20poly1305,
    SSHCipherType.aes128ctr,
    SSHCipherType.aes256ctr,
    SSHCipherType.aes128gcm,
    SSHCipherType.aes256gcm,
  ],
);

/// 和服务器没有共同的算法。dartssh2 报的是包在 [SSHAuthAbortError] 里的 `StateError('No matching …')`，
/// 不单独认出来就会被当成「登录前被对方关掉」：提示指向网络，自动恢复还会一直重试。
bool isAlgorithmMismatch(Object? error) {
  final cause = error is SSHAuthAbortError ? error.reason : error;
  return cause is SSHInternalError &&
      '${cause.error}'.contains('No matching ');
}

extension SshClientClose on SSHClient {
  /// 关掉不等结果。从 3.0.0 起 [SSHClient.close] 返回 Future，直接丢掉的话关 socket 报错会变成
  /// 没人接的全局错误。走到这里都是在丢弃这条连接，关不干净也没别的可做。
  void closeQuietly() {
    unawaited(close().catchError((Object _) {}));
  }
}
