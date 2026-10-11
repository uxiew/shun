import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
// 自签自验要用各类型公钥的 verify，dartssh2 没有公开导出这几个类。
// dartssh2 锁在 2.22.5，升级时按 plan/v3/docs/12 重跑 test/ssh_identity_test.dart。
// ignore: implementation_imports
import 'package:dartssh2/src/hostkey/hostkey_ecdsa.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/hostkey/hostkey_ed25519.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/hostkey/hostkey_rsa.dart';

import '../../domain/connection_route.dart';
import '../../domain/models/host.dart';
import '../../domain/tailscale_ssh.dart';

/// 私钥读不出来、口令不对、被删了或内容坏了。[message] 是给人看的一句话，不含任何私钥内容。
class SshIdentityException implements Exception {
  const SshIdentityException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 在拨号之前把这一跳的登录私钥解析好。
///
/// 返回 null 表示这一跳不用私钥（没配、或主机设成只用密码）。出错一律抛 [SshIdentityException]，
/// 调用方此时还没有连任何网络：口令错、私钥被删、内容坏了都不该先去连服务器、
/// 再拿一句「登录被拒绝」糊弄过去（SEC06）。
List<SSHKeyPair>? loadHopIdentities(RouteHop hop) {
  final host = hop.host;
  // Tailscale SSH 不发私钥，也就不解密它：口令错了、私钥删了都和这次登录无关。
  if (sshLoginModeOf(host) == SshLoginMode.tailscale) return null;
  if (host.authMethod == HostAuthMethod.password) return null;
  final key = hop.key;
  if (key == null || key.privateKey.isEmpty) {
    if (host.authMethod == HostAuthMethod.key) {
      // 设成只用私钥，私钥却没了：以前会带着空身份去连，被服务器拒后只报「用户名、密码或私钥不对」。
      throw const SshIdentityException('设置为用私钥登录，但引用的私钥不存在（可能已被删除）');
    }
    return null;
  }
  final List<SSHKeyPair> pairs;
  try {
    final passphrase = key.passphrase;
    pairs = SSHKeyPair.fromPem(
      key.privateKey,
      passphrase == null || passphrase.isEmpty ? null : passphrase,
    );
  } on SSHKeyDecryptError catch (error) {
    throw SshIdentityException(
      error.message.contains('encrypted') ? '私钥有口令保护，但没有保存口令' : '私钥口令不对',
    );
  } on SSHKeyDecodeError {
    // 传统 PEM 格式的 RSA 私钥口令不对时，dartssh2 报的也是解码失败，分不出来。
    throw const SshIdentityException('私钥无法解析：格式不对，或者口令不对');
  } on Object {
    // 不带原始异常文本：解析错误可能把私钥片段带进消息里。
    throw const SshIdentityException('私钥无法解析：不是支持的私钥格式');
  }
  if (pairs.isEmpty) {
    throw const SshIdentityException('私钥文件里没有可用的私钥');
  }
  for (final pair in pairs) {
    if (!keyPairSelfCheck(pair)) {
      throw const SshIdentityException('私钥内容已损坏：解出来的私钥和它的公钥对不上，可能被改动过');
    }
  }
  return pairs;
}

/// 用这把私钥签一段固定数据，再用它自己的公钥验签。
///
/// OpenSSH 新格式私钥用 aes256-ctr 加密、没有完整性校验：密文被改了一个字节照样能「解密成功」，
/// 得到的是一把坏钥匙，要到服务器拒绝登录时才暴露，报错还指向「密码或私钥不对」。实测翻转一个字节就是这样。
/// 认不出的密钥类型不拦，交给服务器验。
bool keyPairSelfCheck(SSHKeyPair pair) {
  final message = Uint8List.fromList(utf8.encode('shun identity self-check'));
  try {
    final signature = pair.sign(message);
    return switch ((pair.toPublicKey(), signature)) {
      (SSHEd25519PublicKey key, SSHEd25519Signature sig) =>
        key.verify(message, sig),
      (SSHRsaPublicKey key, SSHRsaSignature sig) => key.verify(message, sig),
      (SSHEcdsaPublicKey key, SSHEcdsaSignature sig) =>
        key.verify(message, sig),
      _ => true,
    };
  } on Object {
    return false;
  }
}

final _passwordPrompt = RegExp(r'password|密码', caseSensitive: false);
// 中文部分依次是「新密码」「验证码」「动态」。写成转义是因为本地化覆盖测试会把源码里
// 所有中文字面量当界面文字查英文翻译，而这不是界面文字。
final _notThePassword = RegExp(
  r'new|verif|code|otp|one[- ]?time|token|pin\b'
  '|\u65b0\u5bc6\u7801|\u9a8c\u8bc1\u7801|\u52a8\u6001',
  caseSensitive: false,
);

/// 没有交互界面时（测试、以后的后台探测）怎么回答 keyboard-interactive 的提问。
///
/// 只在「恰好一个不回显的提问、问的就是密码、不是新密码或验证码」时填保存的密码，
/// 而且一次连接只填一次（[alreadyAnswered]）；其他情况返回 null，放弃这种认证方式。
///
/// 以前对每个不回显的提问都填密码：服务器问一次性验证码、PIN 或「新密码」时，收到的都是你的登录密码。
List<String>? savedPasswordAnswer(
  List<({String text, bool echo})> prompts,
  String? password, {
  required bool alreadyAnswered,
}) {
  // 零个提问的请求（PAM 常在最后一轮发）要回空列表，回 null 会把本来能成的登录中止掉。
  if (prompts.isEmpty) return const [];
  if (alreadyAnswered || password == null || password.isEmpty) return null;
  if (prompts.length != 1) return null;
  final prompt = prompts.single;
  if (prompt.echo) return null;
  if (!_passwordPrompt.hasMatch(prompt.text)) return null;
  if (_notThePassword.hasMatch(prompt.text)) return null;
  return [password];
}
