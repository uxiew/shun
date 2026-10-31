import 'dart:convert';
import 'dart:typed_data';

import 'security_key.dart';

/// 从私钥文件读出密钥类型：`RSA`、`ECDSA`、`ED25519`、`ED25519-SK`、`ECDSA-SK`（和桌面端 Netcatty 的 `type` 字段
/// 同一套写法），认不出返回 null。
///
/// 不解密、不要口令：OpenSSH 新格式里公钥那一段是明文的，类型就写在它开头；传统 PEM 看头一行。
/// 以前导入时一律写 `ED25519`，RSA、ECDSA 私钥在列表里也显示成 ED25519。只用来显示，连接时不看它。
String? sshKeyTypeOf(String pem) {
  if (pem.contains('-----BEGIN RSA PRIVATE KEY-----')) return 'RSA';
  if (pem.contains('-----BEGIN EC PRIVATE KEY-----')) return 'ECDSA';
  final body = RegExp(
    r'-----BEGIN OPENSSH PRIVATE KEY-----([\s\S]*?)-----END OPENSSH PRIVATE KEY-----',
  ).firstMatch(pem)?.group(1);
  if (body == null) return null;
  final Uint8List bytes;
  try {
    bytes = base64.decode(body.replaceAll(RegExp(r'\s'), ''));
  } on FormatException {
    return null;
  }
  // openssh-key-v1：魔数、加密算法、KDF 名、KDF 参数、密钥个数、第一把公钥（开头就是类型名）。
  const magic = 'openssh-key-v1\x00';
  if (bytes.length < magic.length ||
      latin1.decode(bytes.sublist(0, magic.length)) != magic) {
    return null;
  }
  var offset = magic.length;
  Uint8List? readString() {
    if (offset + 4 > bytes.length) return null;
    final length = ByteData.sublistView(bytes, offset, offset + 4).getUint32(0);
    offset += 4;
    if (offset + length > bytes.length) return null;
    final value = bytes.sublist(offset, offset + length);
    offset += length;
    return value;
  }

  for (var i = 0; i < 3; i++) {
    if (readString() == null) return null;
  }
  if (offset + 4 > bytes.length) return null;
  offset += 4;
  final publicKey = readString();
  if (publicKey == null || publicKey.length < 4) return null;
  final typeLength = ByteData.sublistView(publicKey, 0, 4).getUint32(0);
  if (4 + typeLength > publicKey.length) return null;
  final type = latin1.decode(publicKey.sublist(4, 4 + typeLength));
  if (type == skEd25519Type || type == skEcdsaType) {
    return securityKeyVaultType(type);
  }
  if (type == 'ssh-ed25519') return 'ED25519';
  if (type == 'ssh-rsa') return 'RSA';
  if (type.startsWith('ecdsa-sha2-')) return 'ECDSA';
  return null;
}
