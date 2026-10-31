import 'dart:convert';
import 'dart:typed_data';

import '../../domain/models/vault.dart';
import '../sync/netcatty_crypto.dart';

/// 带凭据的加密备份文件（R60）。格式就是云同步的 `{meta, payload}`（[NetcattyCrypto]），没有再造一种。
///
/// 和云同步一样，文件离开手机后就能被离线猜口令，所以口令不能短（[minPassphraseLength]）。
class EncryptedVaultFile {
  const EncryptedVaultFile._();

  static const minPassphraseLength = 12;
  static const passphraseTooShort = '至少 12 位';

  /// 文件能打开，但不是加密备份，也不是保险库 JSON。
  static const notAVaultFile = '不是保险库文件，或者文件已损坏';

  static const iterationsRejected = '文件的密钥派生次数超出范围，没有解密：可能被改过，也可能是更新版本导出的';

  /// 口令不对和文件被改过分不出来：AES-GCM 只告诉你校验没过。
  static const wrongPassphraseOrDamaged = '口令不对，或者文件被改过';

  /// meta 是明文，写固定值：备份文件会被传来传去，不带这台手机的设备 ID。
  static Future<Uint8List> encode({
    required VaultData vault,
    required String passphrase,
    required String appVersion,
  }) async {
    final file = await NetcattyCrypto.encrypt(
      vault: _forFile(vault),
      password: passphrase,
      deviceId: 'file-export',
      deviceName: 'shun',
      appVersion: appVersion,
    );
    return Uint8List.fromList(utf8.encode(jsonEncode(file.toJson())));
  }

  /// 手机互传（R62）的明文内容：和备份文件带一样的东西，加密交给 LanTransferSender。
  static Uint8List plainForTransfer(VaultData vault) => Uint8List.fromList(utf8
      .encode(jsonEncode(_forFile(vault).toJson(legacySyncSnapshot: true))));

  /// 指纹记录是这台手机自己核对出来的，不跟文件走；同步的收敛元数据对别的手机没意义。
  static VaultData _forFile(VaultData vault) {
    final json = vault.toJson(legacySyncSnapshot: true)..remove('knownHosts');
    return VaultData.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>);
  }

  /// 这些字节是不是加密备份。不是就返回 null，调用方按明文 JSON 处理。
  ///
  /// 文件尾部多出来的东西不理：短内容盖长文件可能不截断（file_picker 写的都这样，现在自己写的见
  /// DocumentTreeChannel.saveDocument），直接 `jsonDecode` 会报错，备份就打不开了。内容有 GCM 校验，尾巴影响不到它。
  static SyncedVaultFile? tryParse(List<int> bytes) {
    try {
      final text = utf8.decode(bytes, allowMalformed: true);
      final end = _endOfFirstObject(text);
      if (end == null) return null;
      final json = jsonDecode(text.substring(0, end));
      if (json is! Map<String, dynamic>) return null;
      if (json['meta'] is! Map || json['payload'] is! String) return null;
      return SyncedVaultFile.fromJson(json);
    } on FormatException {
      return null;
    }
  }

  /// 第一个完整 JSON 对象结束的位置。不是以 `{` 开头、或者没有结束时返回 null。
  static int? _endOfFirstObject(String text) {
    var depth = 0;
    var inString = false;
    var escaped = false;
    final start = text.indexOf('{');
    if (start < 0 || text.substring(0, start).trim().isNotEmpty) return null;
    for (var index = start; index < text.length; index++) {
      final unit = text[index];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (unit == r'\') {
          escaped = true;
        } else if (unit == '"') {
          inString = false;
        }
      } else if (unit == '"') {
        inString = true;
      } else if (unit == '{') {
        depth += 1;
      } else if (unit == '}') {
        depth -= 1;
        if (depth == 0) return index + 1;
      }
    }
    return null;
  }

  /// 明文 JSON（不含密码的导出、桌面端解密后导出的）。不是保险库或文件坏了抛 [FormatException]。
  static VaultData parsePlain(List<int> bytes) {
    try {
      // 同样可能留着尾巴，见 [tryParse]。
      final text = utf8.decode(bytes, allowMalformed: true);
      final end = _endOfFirstObject(text);
      if (end == null) throw const FormatException(notAVaultFile);
      return VaultData.fromJson(
        jsonDecode(text.substring(0, end)) as Map<String, dynamic>,
      );
    } on FormatException {
      throw const FormatException(notAVaultFile);
    } on TypeError {
      throw const FormatException(notAVaultFile);
    }
  }

  /// 解密。口令不对、文件被改过都抛 [FormatException]，消息能直接给人看。
  static Future<VaultData> decrypt(
    SyncedVaultFile file,
    String passphrase,
  ) async {
    try {
      return await NetcattyCrypto.decrypt(file, passphrase);
    } on FormatException catch (error) {
      if (error.message == NetcattyCrypto.iterationsOutOfRange) {
        throw const FormatException(iterationsRejected);
      }
      throw const FormatException(wrongPassphraseOrDamaged);
    } on TypeError {
      // meta 里缺字段、类型不对：文件不是我们写的，或者被改过。
      throw const FormatException(wrongPassphraseOrDamaged);
    }
  }
}
