import 'dart:async';

import 'package:flutter/services.dart';

import '../../domain/security_key.dart';

/// 一次跟钥匙打交道走到哪一步了，给界面显示用。
enum SecurityKeyStage {
  /// 等钥匙贴上来或插上来。
  waitingForKey,

  /// 连上了，正在通信。
  communicating,

  /// 钥匙在等人碰一下。
  waitingForTouch,
}

/// 手机上能不能用钥匙。
class SecurityKeyAvailability {
  const SecurityKeyAvailability({
    required this.nfc,
    required this.nfcEnabled,
    required this.usb,
  });

  /// 手机有没有 NFC。
  final bool nfc;

  /// NFC 有没有打开。关着的话贴了没反应，要提醒用户。
  final bool nfcEnabled;

  /// 手机能不能当 USB 主机。
  final bool usb;
}

/// 钥匙上新生成的密钥：注册结果的 authenticatorData 里带着公钥和句柄。
class SecurityKeyCreated {
  const SecurityKeyCreated(this.attestedData);

  final Uint8List attestedData;
}

/// 从钥匙里读出来的一把 resident 密钥。
class SecurityKeyResident {
  const SecurityKeyResident({
    required this.application,
    required this.credentialId,
    required this.coseKey,
  });

  final String application;
  final Uint8List credentialId;
  final CoseKey coseKey;
}

/// 和 Android 侧 `SecurityKeyChannel.kt` 说话，每次调用就是一轮「等钥匙 → 通信 → 结束」。
///
/// PIN 放在参数里一起传、不在通信中途问：用 NFC 时钥匙一直贴着才有电，不能让人贴着打字。
/// PIN 不对就抛 [SecurityKeyFailure.pinInvalid]，要不要再试由用户决定：错几次钥匙就锁了，这里绝不自动重试。
class SecurityKeyChannel {
  SecurityKeyChannel({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('top.xdwa.shun/security_key') {
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;
  final _stages = StreamController<SecurityKeyStage>.broadcast();

  Stream<SecurityKeyStage> get stages => _stages.stream;

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method != 'stage') return;
    final stage = switch (call.arguments) {
      'communicating' => SecurityKeyStage.communicating,
      'touch' => SecurityKeyStage.waitingForTouch,
      _ => null,
    };
    if (stage != null) _stages.add(stage);
  }

  Future<SecurityKeyAvailability> availability() async {
    final Map<Object?, Object?>? value;
    try {
      value = await _channel.invokeMapMethod<Object?, Object?>('availability');
    } on MissingPluginException {
      return const SecurityKeyAvailability(
        nfc: false,
        nfcEnabled: false,
        usb: false,
      );
    }
    return SecurityKeyAvailability(
      nfc: value?['nfc'] == true,
      nfcEnabled: value?['nfcEnabled'] == true,
      usb: value?['usb'] == true,
    );
  }

  /// 让钥匙签名。[clientDataHash] 是 `SHA256(要签的数据)`。
  Future<SecurityKeyAssertion> sign({
    required String application,
    required Uint8List clientDataHash,
    required Uint8List keyHandle,
    required bool userPresence,
    String? pin,
  }) async {
    final value = await _invoke('sign', {
      'rpId': application,
      'clientDataHash': clientDataHash,
      'credentialId': keyHandle,
      'userPresence': userPresence,
      if (pin != null) 'pin': pin,
    });
    return SecurityKeyAssertion(
      authenticatorData: value['authenticatorData'] as Uint8List,
      signature: value['signature'] as Uint8List,
    );
  }

  /// 在钥匙上生成新密钥。Ed25519 优先，钥匙不支持就是 ECDSA，实际是哪种看返回的公钥。
  Future<SecurityKeyCreated> create({
    required String application,
    required bool resident,
    required bool requirePin,
    String? pin,
  }) async {
    final value = await _invoke('create', {
      'rpId': application,
      'resident': resident,
      'requirePin': requirePin,
      if (pin != null) 'pin': pin,
    });
    return SecurityKeyCreated(value['authenticatorData'] as Uint8List);
  }

  /// 读钥匙里所有 `ssh:` 开头的 resident 密钥。这个操作钥匙一定要 PIN。
  Future<List<SecurityKeyResident>> listResident({required String pin}) async {
    final value = await _invoke('listResident', {'pin': pin});
    return [
      for (final item in value['credentials'] as List)
        if (_readResident(item as Map<Object?, Object?>) case final resident?)
          resident,
    ];
  }

  /// 这把钥匙认不出的公钥类型（SSH 用不了）跳过，其余的照常导入。
  static SecurityKeyResident? _readResident(Map<Object?, Object?> item) {
    try {
      return SecurityKeyResident(
        application: item['rpId'] as String,
        credentialId: item['credentialId'] as Uint8List,
        coseKey: CoseKey.parse(item['publicKey'] as Uint8List),
      );
    } on SecurityKeyException {
      return null;
    }
  }

  /// 停掉正在进行的那一轮，它会以 [SecurityKeyFailure.cancelled] 结束。
  Future<void> cancel() async {
    try {
      await _channel.invokeMethod<void>('cancel');
    } on MissingPluginException {
      return;
    }
  }

  Future<Map<Object?, Object?>> _invoke(
    String method,
    Map<String, Object?> arguments,
  ) async {
    _stages.add(SecurityKeyStage.waitingForKey);
    try {
      final value =
          await _channel.invokeMapMethod<Object?, Object?>(method, arguments);
      return value ?? const {};
    } on PlatformException catch (error) {
      throw securityKeyExceptionOf(error.code, error.details);
    } on MissingPluginException {
      throw const SecurityKeyException(SecurityKeyFailure.unsupported);
    }
  }
}

/// 把 Kotlin 报的错误码翻成 [SecurityKeyException]。认不出的都算通信失败。
SecurityKeyException securityKeyExceptionOf(String code, Object? details) {
  final failure = SecurityKeyFailure.values.firstWhere(
    (value) => value.name == code,
    orElse: () => SecurityKeyFailure.transport,
  );
  return SecurityKeyException(
    failure,
    pinRetries: details is Map ? details['pinRetries'] as int? : null,
  );
}
