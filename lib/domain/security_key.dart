import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// OpenSSH 安全密钥（FIDO2，YubiKey 这类）的两种类型。格式见 OpenSSH 的 PROTOCOL.u2f。
const skEd25519Type = 'sk-ssh-ed25519@openssh.com';
const skEcdsaType = 'sk-ecdsa-sha2-nistp256@openssh.com';

/// 句柄文件里 flags 的各位（OpenSSH sk-api.h）。
const skFlagUserPresence = 0x01;
const skFlagUserVerification = 0x04;
const skFlagResident = 0x20;

/// 保险库里 `type` 字段的写法，和桌面端 Netcatty 一样。
String securityKeyVaultType(String sshType) =>
    sshType == skEd25519Type ? 'ED25519-SK' : 'ECDSA-SK';

const _pemBegin = '-----BEGIN OPENSSH PRIVATE KEY-----';
const _pemEnd = '-----END OPENSSH PRIVATE KEY-----';
const _magic = 'openssh-key-v1\x00';

/// 解密带口令的句柄文件。放在外面是因为要用 bcrypt，这个文件不依赖 SSH 库。
typedef SecurityKeyStubDecrypt = Uint8List Function({
  required String cipher,
  required String kdf,
  required Uint8List kdfOptions,
  required Uint8List blob,
  required String passphrase,
});

/// 句柄文件读不出来。[message] 是给人看的一句话，不带文件内容。
class SecurityKeyStubException implements Exception {
  const SecurityKeyStubException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// `ssh-keygen -t ed25519-sk` 生成的那个「私钥文件」。
///
/// 说白了它不是私钥：真正的私钥在钥匙里出不来，文件只存公钥和一个句柄（[keyHandle]），登录时把句柄交给钥匙，
/// 钥匙用它找回私钥来签名。没有那把钥匙，文件拿到也登不了。
class SecurityKeyStub {
  const SecurityKeyStub({
    required this.type,
    required this.publicKey,
    required this.application,
    required this.flags,
    required this.keyHandle,
    this.comment = '',
  });

  /// 从钥匙拿到的公钥拼出句柄文件：手机上生成、从钥匙读 resident 都走这里。
  factory SecurityKeyStub.fromCredential({
    required CoseKey key,
    required String application,
    required int flags,
    required Uint8List keyHandle,
    String comment = '',
  }) {
    final writer = _SshWriter()..writeString(utf8.encode(key.sshType));
    if (key.sshType == skEcdsaType) {
      writer
        ..writeString(utf8.encode('nistp256'))
        ..writeString([0x04, ...key.x, ...key.y!]);
    } else {
      writer.writeString(key.x);
    }
    writer.writeString(utf8.encode(application));
    return SecurityKeyStub(
      type: key.sshType,
      publicKey: writer.toBytes(),
      application: application,
      flags: flags,
      keyHandle: keyHandle,
      comment: comment,
    );
  }

  /// `sk-ssh-ed25519@openssh.com` 或 `sk-ecdsa-sha2-nistp256@openssh.com`。
  final String type;

  /// SSH 线上格式的公钥，原样发给服务器。
  final Uint8List publicKey;

  /// 钥匙里的 rpId，通常是 `ssh:`。可以是 `ssh:别的`，所以别写死：写死了钥匙会报找不到凭据（ConnectBot 踩过）。
  final String application;
  final int flags;
  final Uint8List keyHandle;
  final String comment;

  /// 登录要不要碰钥匙。生成时加了 `no-touch-required` 的才是 false。
  bool get userPresenceRequired => flags & skFlagUserPresence != 0;

  /// 登录要不要 PIN。生成时加了 `verify-required` 的才是 true。
  bool get userVerificationRequired => flags & skFlagUserVerification != 0;

  /// 一行 `authorized_keys` 格式的公钥，给用户贴到服务器上。
  String get publicKeyLine => [
        type,
        base64.encode(publicKey),
        if (comment.isNotEmpty) comment,
      ].join(' ');

  /// 这段文本是不是安全密钥的句柄文件。不解密、不要口令，类型在明文的公钥段里。
  static bool isStubPem(String pem) => sshTypeOf(pem) != null;

  /// 句柄文件的 SSH 类型，不是句柄文件时返回 null。
  static String? sshTypeOf(String pem) {
    final envelope = _tryEnvelope(pem);
    if (envelope == null) return null;
    final type = envelope.publicKeyType;
    return type == skEd25519Type || type == skEcdsaType ? type : null;
  }

  /// 句柄文件里的公钥，写成一行 `authorized_keys` 格式；文件带口令也读得出来。不是句柄文件时返回 null。
  static String? publicKeyLineOf(String pem) {
    final type = sshTypeOf(pem);
    if (type == null) return null;
    return '$type ${base64.encode(_tryEnvelope(pem)!.publicKey)}';
  }

  static _StubEnvelope? _tryEnvelope(String pem) {
    try {
      final body = _decodePem(pem);
      return body == null ? null : _readEnvelope(body);
    } on Object {
      return null;
    }
  }

  /// 解析句柄文件。文件带口令时要给 [passphrase] 和 [decrypt]。
  factory SecurityKeyStub.parse(
    String pem, {
    String? passphrase,
    SecurityKeyStubDecrypt? decrypt,
  }) {
    final body = _decodePem(pem);
    if (body == null) {
      throw const SecurityKeyStubException('不是 OpenSSH 格式的文件');
    }
    try {
      final envelope = _readEnvelope(body);
      final Uint8List private;
      if (envelope.cipher == 'none') {
        private = envelope.privateBlock;
      } else {
        if (passphrase == null || passphrase.isEmpty) {
          throw const SecurityKeyStubException('安全密钥文件有口令保护，但没有保存口令');
        }
        if (decrypt == null) {
          throw const SecurityKeyStubException('这里解不开带口令的安全密钥文件');
        }
        private = decrypt(
          cipher: envelope.cipher,
          kdf: envelope.kdf,
          kdfOptions: envelope.kdfOptions,
          blob: envelope.privateBlock,
          passphrase: passphrase,
        );
      }
      return _readPrivateBlock(private, envelope);
    } on SecurityKeyStubException {
      rethrow;
    } on Object {
      // 不带原始异常：解析错误可能把文件片段带进消息。
      throw const SecurityKeyStubException('安全密钥文件内容已损坏');
    }
  }

  static Uint8List? _decodePem(String pem) {
    final start = pem.indexOf(_pemBegin);
    final end = pem.indexOf(_pemEnd);
    if (start < 0 || end < start) return null;
    try {
      return base64.decode(
        pem
            .substring(start + _pemBegin.length, end)
            .replaceAll(RegExp(r'\s'), ''),
      );
    } on FormatException {
      return null;
    }
  }

  static _StubEnvelope _readEnvelope(Uint8List body) {
    if (body.length < _magic.length ||
        latin1.decode(body.sublist(0, _magic.length)) != _magic) {
      throw const FormatException('magic');
    }
    final reader = _SshReader(body, _magic.length);
    final cipher = utf8.decode(reader.readString());
    final kdf = utf8.decode(reader.readString());
    final kdfOptions = reader.readString();
    if (reader.readUint32() != 1) throw const FormatException('keys');
    final publicKey = reader.readString();
    final privateBlock = reader.readString();
    return _StubEnvelope(
      cipher: cipher,
      kdf: kdf,
      kdfOptions: kdfOptions,
      publicKey: publicKey,
      publicKeyType: utf8.decode(_SshReader(publicKey, 0).readString()),
      privateBlock: privateBlock,
    );
  }

  static SecurityKeyStub _readPrivateBlock(
    Uint8List block,
    _StubEnvelope envelope,
  ) {
    final reader = _SshReader(block, 0);
    if (reader.readUint32() != reader.readUint32()) {
      throw SecurityKeyStubException(
        envelope.cipher == 'none' ? '安全密钥文件内容已损坏' : '安全密钥文件的口令不对',
      );
    }
    final type = utf8.decode(reader.readString());
    if (type != skEd25519Type && type != skEcdsaType) {
      throw const SecurityKeyStubException('不是安全密钥的文件');
    }
    if (type == skEcdsaType) reader.readString(); // 曲线名 nistp256
    reader.readString(); // 公钥本体，和外层那段一样；发给服务器的是外层那段
    final application = utf8.decode(reader.readString());
    final flags = reader.readByte();
    final keyHandle = reader.readString();
    reader.readString(); // reserved
    final comment = utf8.decode(reader.readString());
    if (type != envelope.publicKeyType || keyHandle.isEmpty) {
      throw const SecurityKeyStubException('安全密钥文件内容已损坏');
    }
    return SecurityKeyStub(
      type: type,
      publicKey: envelope.publicKey,
      application: application,
      flags: flags,
      keyHandle: keyHandle,
      comment: comment,
    );
  }

  /// 写成不带口令的 OpenSSH 文件，`ssh` 命令也认。
  String toPem({Random? random}) {
    final rng = random ?? Random.secure();
    final check = rng.nextInt(1 << 32);
    final key = _SshReader(publicKey, 0);
    key.readString(); // 类型名
    final private = _SshWriter()
      ..writeUint32(check)
      ..writeUint32(check)
      ..writeString(utf8.encode(type));
    if (type == skEcdsaType) private.writeString(key.readString());
    private
      ..writeString(key.readString())
      ..writeString(utf8.encode(application))
      ..writeByte(flags)
      ..writeString(keyHandle)
      ..writeString(const [])
      ..writeString(utf8.encode(comment));
    // 按 8 字节对齐，填充是 1, 2, 3…（ssh-keygen 写法）。
    for (var pad = 1; private.length % 8 != 0; pad++) {
      private.writeByte(pad);
    }
    final file = _SshWriter()
      ..writeRaw(latin1.encode(_magic))
      ..writeString(utf8.encode('none'))
      ..writeString(utf8.encode('none'))
      ..writeString(const [])
      ..writeUint32(1)
      ..writeString(publicKey)
      ..writeString(private.toBytes());
    final encoded = base64.encode(file.toBytes());
    final lines = StringBuffer('$_pemBegin\n');
    for (var i = 0; i < encoded.length; i += 70) {
      lines.writeln(encoded.substring(i, min(i + 70, encoded.length)));
    }
    lines.writeln(_pemEnd);
    return lines.toString();
  }
}

class _StubEnvelope {
  const _StubEnvelope({
    required this.cipher,
    required this.kdf,
    required this.kdfOptions,
    required this.publicKey,
    required this.publicKeyType,
    required this.privateBlock,
  });

  final String cipher;
  final String kdf;
  final Uint8List kdfOptions;
  final Uint8List publicKey;
  final String publicKeyType;
  final Uint8List privateBlock;
}

/// 钥匙对一次签名请求的回复：CTAP2 `getAssertion` 的原始结果。
class SecurityKeyAssertion {
  const SecurityKeyAssertion({
    required this.authenticatorData,
    required this.signature,
  });

  /// `SHA256(rpId) + flags + counter`，共 37 字节。
  final Uint8List authenticatorData;

  /// Ed25519 是 64 字节原始签名；ECDSA 是 DER 编码的 `SEQUENCE { r, s }`。
  final Uint8List signature;
}

/// 一次登录要钥匙签的东西，[hostLabel]、[username] 给用户看签的是哪台机器。
class SecurityKeySignRequest {
  const SecurityKeySignRequest({
    required this.key,
    required this.data,
    required this.hostLabel,
    required this.username,
    this.cancelled,
  });

  final SecurityKeyStub key;
  final Uint8List data;
  final String hostLabel;
  final String username;

  /// 这次连接被取消时完成。弹框要跟着关，不然连接没了框还在等人碰。
  final Future<void>? cancelled;
}

/// 谁来跟钥匙打交道：真机上是界面 + Kotlin 桥，测试里是软件认证器。
typedef SecurityKeySigner = Future<SecurityKeyAssertion> Function(
  SecurityKeySignRequest request,
);

enum SecurityKeyFailure {
  /// 用户点了取消。
  cancelled,

  /// 没等到钥匙或没等到触摸。
  timeout,

  /// 钥匙要 PIN，但这次没给。
  pinRequired,

  /// PIN 不对。
  pinInvalid,

  /// PIN 错太多次，钥匙锁了。
  pinBlocked,

  /// 钥匙还没设过 PIN。
  pinNotSet,

  /// 贴上来的不是生成这把密钥的钥匙。
  noCredential,

  /// 钥匙不支持这个操作（比如老 U2F 钥匙）。
  unsupported,

  /// 说不出来的通信错误。
  transport,
}

/// 跟钥匙打交道失败。不带 PIN、句柄、签名内容。
class SecurityKeyException implements Exception {
  const SecurityKeyException(this.failure, {this.pinRetries});

  final SecurityKeyFailure failure;

  /// PIN 还能试几次，钥匙报的。
  final int? pinRetries;

  @override
  String toString() => switch (failure) {
        SecurityKeyFailure.cancelled => '取消了安全密钥签名',
        SecurityKeyFailure.timeout => '没有等到安全密钥',
        SecurityKeyFailure.pinRequired => '安全密钥要求输入 PIN',
        SecurityKeyFailure.pinInvalid => pinRetries == null
            ? '安全密钥的 PIN 不对'
            : '安全密钥的 PIN 不对，还能试 $pinRetries 次',
        SecurityKeyFailure.pinBlocked => '安全密钥的 PIN 错太多次，已锁定',
        SecurityKeyFailure.pinNotSet => '这把钥匙还没设 PIN，先用钥匙厂商的工具设一个',
        SecurityKeyFailure.noCredential => '这把钥匙里没有这把密钥：可能贴错了钥匙',
        SecurityKeyFailure.unsupported => '这把钥匙不支持：需要 FIDO2，老的 U2F 钥匙暂不支持',
        SecurityKeyFailure.transport => '和安全密钥通信失败',
      };
}

/// 自动恢复碰不了钥匙，只能停下来等人。
class SecurityKeyNeedsUser implements Exception {
  const SecurityKeyNeedsUser();

  @override
  String toString() => '这台机器要碰安全密钥才能登录，自动恢复不会替你碰';
}

/// 打包成 SSH 要的签名（PROTOCOL.u2f）：类型名 + 签名 + 1 字节 flags + 4 字节 counter。
/// 多一个字节 sshd 都会拒绝，所以这里严格检查钥匙的回复。
///
/// [SecurityKeyFailure.transport]：回复不是 37 字节（带了扩展数据）、要触摸却没碰过、签名格式不对。
Uint8List encodeSecurityKeySignature(
  SecurityKeyStub key,
  SecurityKeyAssertion assertion,
) {
  final data = assertion.authenticatorData;
  if (data.length != 37 ||
      (key.userPresenceRequired && data[32] & skFlagUserPresence == 0)) {
    throw const SecurityKeyException(SecurityKeyFailure.transport);
  }
  final body = _SshWriter()..writeString(utf8.encode(key.type));
  if (key.type == skEd25519Type) {
    if (assertion.signature.length != 64) {
      throw const SecurityKeyException(SecurityKeyFailure.transport);
    }
    body.writeString(assertion.signature);
  } else {
    body.writeString(_ecdsaDerToSsh(assertion.signature));
  }
  body
    ..writeByte(data[32])
    ..writeRaw(data.sublist(33, 37));
  return body.toBytes();
}

/// DER 的 `SEQUENCE { INTEGER r, INTEGER s }` 转成 SSH 的 mpint r + mpint s。
/// 两边都是大端补码、最短表示，整数内容可以直接拿来用。
Uint8List _ecdsaDerToSsh(Uint8List der) {
  try {
    if (der[0] != 0x30) throw const FormatException('sequence');
    var offset = 1;
    final sequenceLength = der[offset++];
    if (sequenceLength >= 0x80) {
      // P-256 的签名最长 72 字节，按规范不会出现长格式的长度。
      throw const FormatException('length');
    }
    if (offset + sequenceLength != der.length) {
      throw const FormatException('length');
    }
    Uint8List readInteger() {
      if (der[offset++] != 0x02) throw const FormatException('integer');
      final length = der[offset++];
      if (length == 0 || length >= 0x80) throw const FormatException('length');
      final value = der.sublist(offset, offset + length);
      offset += length;
      return value;
    }

    final r = readInteger();
    final s = readInteger();
    if (offset != der.length) throw const FormatException('trailing');
    return (_SshWriter()
          ..writeString(r)
          ..writeString(s))
        .toBytes();
  } on Object {
    throw const SecurityKeyException(SecurityKeyFailure.transport);
  }
}

/// 钥匙给的公钥（COSE 格式，CBOR 编码的一个 map）。
class CoseKey {
  const CoseKey._(this.sshType, this.x, this.y);

  /// 解析 COSE_Key。只认 SSH 能用的两种：EdDSA（Ed25519）和 ES256（P-256）。
  factory CoseKey.parse(Uint8List cbor) => _fromMap(_CborReader(cbor).read());

  /// 从钥匙注册结果的 authenticatorData 里取出凭据：
  /// `rpIdHash(32) + flags(1) + counter(4) + aaguid(16) + 长度(2) + credentialId + COSE_Key`。
  static ({Uint8List credentialId, CoseKey key}) fromAttestedData(
    Uint8List authData,
  ) {
    const headerLength = 37 + 16;
    try {
      final length = ByteData.sublistView(authData, headerLength, headerLength + 2)
          .getUint16(0);
      final start = headerLength + 2;
      final credentialId = authData.sublist(start, start + length);
      return (
        credentialId: credentialId,
        key: _fromMap(_CborReader(authData.sublist(start + length)).read()),
      );
    } on SecurityKeyException {
      rethrow;
    } on Object {
      throw const SecurityKeyException(SecurityKeyFailure.transport);
    }
  }

  static CoseKey _fromMap(Object? value) {
    if (value is! Map) {
      throw const SecurityKeyException(SecurityKeyFailure.transport);
    }
    final alg = value[3];
    final x = value[-2];
    final y = value[-3];
    if (alg == -8 && x is Uint8List && x.length == 32) {
      return CoseKey._(skEd25519Type, x, null);
    }
    if (alg == -7 &&
        x is Uint8List &&
        y is Uint8List &&
        x.length == 32 &&
        y.length == 32) {
      return CoseKey._(skEcdsaType, x, y);
    }
    throw const SecurityKeyException(SecurityKeyFailure.unsupported);
  }

  final String sshType;
  final Uint8List x;
  final Uint8List? y;
}

/// 够用就好的 CBOR 读取：定长的整数、字节串、文本、数组、map。COSE_Key 里没有别的。
class _CborReader {
  _CborReader(this._bytes);

  final Uint8List _bytes;
  var _offset = 0;

  Object? read() {
    final head = _bytes[_offset++];
    final major = head >> 5;
    final info = head & 0x1f;
    final value = _length(info);
    switch (major) {
      case 0:
        return value;
      case 1:
        return -1 - value;
      case 2:
      case 3:
        final data = _bytes.sublist(_offset, _offset + value);
        _offset += value;
        return major == 2 ? data : utf8.decode(data);
      case 4:
        return [for (var i = 0; i < value; i++) read()];
      case 5:
        final map = <Object?, Object?>{};
        for (var i = 0; i < value; i++) {
          final key = read();
          map[key] = read();
        }
        return map;
      default:
        throw const FormatException('cbor');
    }
  }

  int _length(int info) {
    if (info < 24) return info;
    final size = switch (info) {
      24 => 1,
      25 => 2,
      26 => 4,
      _ => throw const FormatException('cbor'),
    };
    var value = 0;
    for (var i = 0; i < size; i++) {
      value = value << 8 | _bytes[_offset++];
    }
    return value;
  }
}

class _SshReader {
  _SshReader(this._bytes, this._offset);

  final Uint8List _bytes;
  int _offset;

  int readByte() => _bytes[_offset++];

  int readUint32() {
    final value = ByteData.sublistView(_bytes, _offset, _offset + 4).getUint32(0);
    _offset += 4;
    return value;
  }

  Uint8List readString() {
    final length = readUint32();
    if (_offset + length > _bytes.length) throw const FormatException('string');
    final value = _bytes.sublist(_offset, _offset + length);
    _offset += length;
    return value;
  }
}

class _SshWriter {
  final _builder = BytesBuilder();

  int get length => _builder.length;

  void writeRaw(List<int> bytes) => _builder.add(bytes);

  void writeByte(int value) => _builder.addByte(value);

  void writeUint32(int value) => _builder
      .add((ByteData(4)..setUint32(0, value)).buffer.asUint8List());

  void writeString(List<int> bytes) {
    writeUint32(bytes.length);
    _builder.add(bytes);
  }

  Uint8List toBytes() => _builder.toBytes();
}
