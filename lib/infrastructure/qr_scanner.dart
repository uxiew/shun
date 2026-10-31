import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 用户没给相机权限。
class QrScanDenied implements Exception {
  const QrScanDenied();
}

abstract class QrScanner {
  /// 扫到的内容；用户退出扫码页返回 null。
  Future<String?> scan({required String prompt});
}

/// 桥在 android/.../QrScanChannel.kt。
class PlatformQrScanner implements QrScanner {
  const PlatformQrScanner();

  static const _channel = MethodChannel('top.xdwa.shun/qr_scan');

  @override
  Future<String?> scan({required String prompt}) async {
    try {
      return await _channel.invokeMethod<String>('scan', {'prompt': prompt});
    } on PlatformException catch (error) {
      if (error.code == 'camera_denied') throw const QrScanDenied();
      rethrow;
    }
  }
}

final qrScannerProvider =
    Provider<QrScanner>((ref) => const PlatformQrScanner());
