import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../domain/models/vault.dart';

class SyncedVaultFile {
  const SyncedVaultFile({required this.meta, required this.payload});

  factory SyncedVaultFile.fromJson(Map<String, dynamic> json) =>
      SyncedVaultFile(
        meta: Map<String, dynamic>.from(json['meta'] as Map),
        payload: json['payload'] as String,
      );

  final Map<String, dynamic> meta;
  final String payload;
  Map<String, dynamic> toJson() => {'meta': meta, 'payload': payload};
}

class NetcattyCrypto {
  static const iterations = 600000;

  /// 解密时肯算的最多次数。`kdfIterations` 在云端 meta 里是明文，能改云端文件的人填一个十亿，
  /// 手机就一直算下去、同步卡住。桌面端和本 App 都写 [iterations]，这里留了 3 倍多的余地给以后提高；
  /// 桌面端真调到更高，这里要跟着改，否则手机报 [iterationsOutOfRange] 解不开。
  /// 下限只拦非正数：次数少不影响安全，密钥还是从用户的同步密码来，改小了只会解不开。
  static const maxIterations = 2000000;

  static const iterationsOutOfRange =
      '云端文件的密钥派生次数超出范围，没有解密：可能被改过，也可能是更新版本的桌面端写的';
  static const saltLength = 32;
  static const ivLength = 12;
  static const tagLength = 16;

  static final _pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: iterations,
    bits: 256,
  );
  static final _aes = AesGcm.with256bits();

  static Future<SyncedVaultFile> encrypt({
    required VaultData vault,
    required String password,
    required String deviceId,
    required String deviceName,
    required String appVersion,
    int previousVersion = 0,
  }) async {
    final random = Random.secure();
    final salt = Uint8List.fromList(
      List<int>.generate(saltLength, (_) => random.nextInt(256)),
    );
    final iv = Uint8List.fromList(
      List<int>.generate(ivLength, (_) => random.nextInt(256)),
    );
    final key = await _pbkdf2.deriveKeyFromPassword(
      password: password,
      nonce: salt,
    );
    final convergent = vault.extras['convergentSync'];
    final isConvergentV2 = convergent is Map &&
        convergent['schemaVersion'] == 2 &&
        convergent['encoding'] == 'materialized-winner-v1';
    // Legacy writes remain v1. When the remote already uses desktop's
    // convergent format, the caller supplies an updated envelope and we must
    // preserve it together with the advertised plaintext schema version.
    final cleartext = utf8.encode(jsonEncode(vault.toJson(
      legacySyncSnapshot: !isConvergentV2,
    )));
    final box = await _aes.encrypt(cleartext, secretKey: key, nonce: iv);
    final ciphertextAndTag = Uint8List.fromList([
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
    return SyncedVaultFile(
      meta: {
        'version': previousVersion + 1,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'deviceId': deviceId,
        'deviceName': deviceName,
        'appVersion': appVersion,
        'iv': base64Encode(iv),
        'salt': base64Encode(salt),
        'algorithm': 'AES-256-GCM',
        'kdf': 'PBKDF2',
        'kdfIterations': iterations,
        if (isConvergentV2) 'syncSchemaVersion': 2,
      },
      payload: base64Encode(ciphertextAndTag),
    );
  }

  static Future<VaultData> decrypt(
    SyncedVaultFile file,
    String password,
  ) async {
    if (file.meta['algorithm'] != 'AES-256-GCM' ||
        file.meta['kdf'] != 'PBKDF2') {
      throw const FormatException('Unsupported Netcatty encryption format');
    }
    final rounds = (file.meta['kdfIterations'] as num?)?.toInt() ?? iterations;
    if (rounds < 1 || rounds > maxIterations) {
      throw const FormatException(iterationsOutOfRange);
    }
    final salt = base64Decode(file.meta['salt'] as String);
    final iv = base64Decode(file.meta['iv'] as String);
    final body = base64Decode(file.payload);
    if (body.length <= tagLength) {
      throw const FormatException('Encrypted payload is truncated');
    }
    final key = await Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: rounds,
      bits: 256,
    ).deriveKeyFromPassword(password: password, nonce: salt);
    final box = SecretBox(
      body.sublist(0, body.length - tagLength),
      nonce: iv,
      mac: Mac(body.sublist(body.length - tagLength)),
    );
    try {
      final cleartext = await _aes.decrypt(box, secretKey: key);
      return VaultData.fromJson(
        jsonDecode(utf8.decode(cleartext)) as Map<String, dynamic>,
      );
    } on SecretBoxAuthenticationError {
      throw const FormatException('同步密码错误或云端文件已损坏');
    }
  }
}
