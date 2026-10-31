import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:shun/domain/security_key.dart';

Uint8List _sha256(List<int> bytes) =>
    Uint8List.fromList(const DartSha256().hashSync(bytes).bytes);

/// 测试里代替真钥匙：按 CTAP2 的算法组 authenticatorData 再签名，签出来的东西 sshd 分不出真假。
///
/// 它只能证明「格式对」：真钥匙的触摸、PIN 重试计数、NFC 和 USB 都模拟不了，所以这里过了不算 SKY02–SKY04 过。
/// 私钥是 ssh-keygen 现场生成的普通密钥，签名用 dartssh2 自己的实现。
class SoftAuthenticator {
  SoftAuthenticator._(this.pair, this.stub);

  /// 生成一把。[sshType] 是 [skEd25519Type] 或 [skEcdsaType]。
  static Future<SoftAuthenticator> create(
    Directory dir,
    String sshType, {
    String application = 'ssh:',
    int flags = skFlagUserPresence,
    Uint8List? keyHandle,
    String comment = '',
  }) async {
    final path =
        '${dir.path}/soft-${DateTime.now().microsecondsSinceEpoch}-$sshType';
    final generated = await Process.run('ssh-keygen', [
      '-q',
      if (sshType == skEd25519Type) ...['-t', 'ed25519'],
      if (sshType == skEcdsaType) ...['-t', 'ecdsa', '-b', '256'],
      '-N',
      '',
      '-C',
      '',
      '-f',
      path,
    ]);
    if (generated.exitCode != 0) throw StateError('${generated.stderr}');
    final pair = SSHKeyPair.fromPem(File(path).readAsStringSync()).single;
    return SoftAuthenticator._(
      pair,
      SecurityKeyStub.fromCredential(
        key: CoseKey.parse(coseOf(pair)),
        application: application,
        flags: flags,
        keyHandle:
            keyHandle ?? Uint8List.fromList(utf8.encode('handle-$sshType')),
        comment: comment,
      ),
    );
  }

  final SSHKeyPair pair;
  final SecurityKeyStub stub;

  /// 钥匙里的签名计数器，每签一次加一。
  var counter = 41;

  /// 这次回复里的 flags。默认 UP：用户碰过了。
  var flags = skFlagUserPresence;

  /// 按这个 rpId 签名，模拟句柄文件和钥匙对不上。默认就是句柄文件里的。
  String? signingApplication;

  /// 收到过的签名请求。
  final requests = <SecurityKeySignRequest>[];

  /// 可以把签好的结果再改一下，看 sshd 拒不拒绝。
  SecurityKeyAssertion Function(SecurityKeyAssertion)? tamper;

  /// 不走签名，直接抛这个（比如用户取消）。
  Object? failWith;

  Future<SecurityKeyAssertion> call(SecurityKeySignRequest request) async {
    requests.add(request);
    final failure = failWith;
    if (failure != null) throw failure;
    final assertion = signRaw(request.data);
    return tamper?.call(assertion) ?? assertion;
  }

  SecurityKeyAssertion signRaw(Uint8List data) {
    counter += 1;
    final authenticatorData = Uint8List.fromList([
      ..._sha256(utf8.encode(signingApplication ?? stub.application)),
      flags,
      ...(ByteData(4)..setUint32(0, counter)).buffer.asUint8List(),
    ]);
    final signature = pair.sign(
      Uint8List.fromList([...authenticatorData, ..._sha256(data)]),
    );
    return SecurityKeyAssertion(
      authenticatorData: authenticatorData,
      signature: _toCtapSignature(signature.encode()),
    );
  }

  /// SSH 线上的签名转成钥匙回的样子：Ed25519 是 64 字节原样；ECDSA 从两个 mpint 换成 DER。
  Uint8List _toCtapSignature(Uint8List encoded) {
    final outer = _Reader(encoded);
    final type = utf8.decode(outer.string());
    final blob = outer.string();
    if (type == 'ssh-ed25519') return blob;
    final inner = _Reader(blob);
    final r = inner.string();
    final s = inner.string();
    return Uint8List.fromList([
      0x30,
      r.length + s.length + 4,
      0x02,
      r.length,
      ...r,
      0x02,
      s.length,
      ...s,
    ]);
  }

  /// 公钥写成钥匙给的 COSE_Key：是 CBOR 编码的一个 map。
  static Uint8List coseOf(SSHKeyPair pair) {
    final reader = _Reader(pair.toPublicKey().encode());
    final type = utf8.decode(reader.string());
    if (type == 'ssh-ed25519') {
      final x = reader.string();
      return Uint8List.fromList([
        0xA4, 0x01, 0x01, 0x03, 0x27, 0x20, 0x06, 0x21, 0x58, 0x20, ...x, //
      ]);
    }
    reader.string(); // 曲线名
    final point = reader.string(); // 0x04 + x + y
    return Uint8List.fromList([
      0xA5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20, //
      ...point.sublist(1, 33),
      0x22, 0x58, 0x20,
      ...point.sublist(33, 65),
    ]);
  }
}

class _Reader {
  _Reader(this._bytes);

  final Uint8List _bytes;
  var _offset = 0;

  Uint8List string() {
    final length =
        ByteData.sublistView(_bytes, _offset, _offset + 4).getUint32(0);
    _offset += 4;
    final value = _bytes.sublist(_offset, _offset + length);
    _offset += length;
    return value;
  }
}
