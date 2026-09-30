import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/domain/connection_route.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_identity.dart';

// SEC06：私钥在拨号之前解析，口令对/错/没存、内容被改、私钥被删都失败关闭并说人话；
// 以及 keyboard-interactive 在没有界面时只对「明确问密码」的提问填一次密码。
// 测试用的私钥现场用 ssh-keygen 生成，没有 ssh-keygen 的机器整组跳过。
void main() {
  final hasKeygen = Process.runSync('which', ['ssh-keygen']).exitCode == 0;
  late Directory dir;
  final keys = <String, String>{};

  setUpAll(() async {
    if (!hasKeygen) return;
    dir = await Directory.systemTemp.createTemp('xwshun-keys-');
    Future<void> gen(String name, List<String> args) async {
      final result = await Process.run(
          'ssh-keygen', ['-q', ...args, '-C', '', '-f', '${dir.path}/$name']);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      keys[name] = File('${dir.path}/$name').readAsStringSync();
    }

    await gen('ed25519', ['-t', 'ed25519', '-N', '']);
    await gen('ed25519_enc', ['-t', 'ed25519', '-N', 'right-pass']);
    await gen('rsa_pem_enc',
        ['-t', 'rsa', '-b', '2048', '-m', 'PEM', '-N', 'right-pass']);
    await gen('ecdsa', ['-t', 'ecdsa', '-b', '256', '-N', '']);
  });
  tearDownAll(() async {
    if (hasKeygen) await dir.delete(recursive: true);
  });

  /// 把 OpenSSH 私钥解 base64 后，从末尾数第 [fromEnd] 个字节翻转，模拟密文被改。
  String flip(String pem, int fromEnd) {
    final lines = const LineSplitter().convert(pem.trim());
    final blob = base64.decode(lines.sublist(1, lines.length - 1).join());
    blob[blob.length - fromEnd] ^= 0xff;
    final text = base64.encode(blob);
    return [
      lines.first,
      for (var i = 0; i < text.length; i += 70)
        text.substring(i, i + 70 > text.length ? text.length : i + 70),
      lines.last,
    ].join('\n');
  }

  RouteHop hopWith({
    String? privateKey,
    String? passphrase,
    String authMethod = 'key',
    bool keyExists = true,
  }) {
    final host = HostProfile({
      'id': 'h',
      'label': 'web',
      'hostname': 'web.example.com',
      'port': 22,
      'username': 'u',
      'protocol': 'ssh',
      'authMethod': authMethod,
      'identityFileId': 'k',
    });
    final key = SshKeyProfile({
      'id': 'k',
      'label': 'k',
      'privateKey': privateKey ?? '',
      if (passphrase != null) 'passphrase': passphrase,
    });
    return resolveRoutePlan(host,
            hosts: [host],
            proxyProfiles: const [],
            keys: keyExists ? [key] : const [])
        .target;
  }

  String failure(RouteHop hop) {
    try {
      loadHopIdentities(hop);
    } on SshIdentityException catch (error) {
      return error.message;
    }
    fail('应当失败');
  }

  group('SEC06 私钥在拨号前解析', () {
    test('无口令、有口令且口令对、传统 PEM、ECDSA：都能用，且通过自签自验', () {
      for (final (name, pass) in [
        ('ed25519', null),
        ('ed25519_enc', 'right-pass'),
        ('rsa_pem_enc', 'right-pass'),
        ('ecdsa', null),
      ]) {
        final pairs = loadHopIdentities(
            hopWith(privateKey: keys[name], passphrase: pass));
        expect(pairs, isNotEmpty, reason: name);
        expect(pairs!.every(keyPairSelfCheck), isTrue, reason: name);
      }
    }, skip: hasKeygen ? false : '没有 ssh-keygen');

    test('口令错、没存口令、传统 PEM 口令错：失败关闭，说清原因', () {
      expect(
          failure(
              hopWith(privateKey: keys['ed25519_enc'], passphrase: 'wrong')),
          '私钥口令不对');
      expect(
          failure(hopWith(privateKey: keys['ed25519_enc'])), '私钥有口令保护，但没有保存口令');
      expect(
          failure(
              hopWith(privateKey: keys['rsa_pem_enc'], passphrase: 'wrong')),
          '私钥无法解析：格式不对，或者口令不对');
    }, skip: hasKeygen ? false : '没有 ssh-keygen');

    test('加密私钥的密文被改了一个字节：dartssh2 照样「解密成功」，自签自验把它拦下', () {
      final enc = keys['ed25519_enc']!;
      for (final fromEnd in [40, 72]) {
        // 40：私钥里那份公钥副本；72：私钥种子。aes256-ctr 没有完整性校验，两处被改都能解出东西来。
        final tampered = flip(enc, fromEnd);
        expect(SSHKeyPair.fromPem(tampered, 'right-pass'), isNotEmpty,
            reason: '前提：库本身察觉不到篡改');
        expect(failure(hopWith(privateKey: tampered, passphrase: 'right-pass')),
            startsWith('私钥内容已损坏'),
            reason: 'fromEnd=$fromEnd');
      }
    }, skip: hasKeygen ? false : '没有 ssh-keygen');

    test('不是私钥的内容：报格式不对，报错里不带原文', () {
      const secretish = '-----BEGIN OPENSSH PRIVATE KEY-----\n'
          'AAAA-secret-material-here!!\n-----END OPENSSH PRIVATE KEY-----';
      final message = failure(hopWith(privateKey: secretish));
      expect(message, '私钥无法解析：不是支持的私钥格式');
      expect(message, isNot(contains('secret-material')));
    });

    test('设成只用私钥、私钥却被删了：拨号前拒绝；密码登录和自动模式不受影响', () {
      expect(failure(hopWith(keyExists: false)), '设置为用私钥登录，但引用的私钥不存在（可能已被删除）');
      expect(loadHopIdentities(hopWith(keyExists: false, authMethod: 'auto')),
          isNull);
      expect(
          loadHopIdentities(
              hopWith(privateKey: 'garbage', authMethod: 'password')),
          isNull,
          reason: '只用密码时根本不读私钥');
    });
  });

  group('keyboard-interactive 没有界面时只对明确问密码的提问填一次', () {
    List<String>? answer(List<({String text, bool echo})> prompts,
            {bool used = false}) =>
        savedPasswordAnswer(prompts, 'saved-pw', alreadyAnswered: used);

    test('问密码：填保存的密码', () {
      for (final text in ['Password: ', "fixture@host's password:", '密码：']) {
        expect(answer([(text: text, echo: false)]), ['saved-pw'], reason: text);
      }
    });

    test('验证码、PIN、新密码、要回显的、一次问两个、已经填过一次：都不填', () {
      for (final text in [
        'Verification code: ',
        'One-time password (OTP): ',
        'Enter PIN: ',
        'New password: ',
        'Retype new password: ',
        '请输入验证码：',
        '动态口令：',
      ]) {
        expect(answer([(text: text, echo: false)]), isNull, reason: text);
      }
      expect(answer([(text: 'Password: ', echo: true)]), isNull);
      expect(
          answer([
            (text: 'Password: ', echo: false),
            (text: 'Password: ', echo: false),
          ]),
          isNull);
      expect(answer([(text: 'Password: ', echo: false)], used: true), isNull,
          reason: '同一连接第二次问密码，说明第一次不对，不再重复发');
    });

    test('零个提问的请求回空列表，不中止登录', () {
      expect(answer(const []), isEmpty);
      expect(answer(const [], used: true), isEmpty);
    });
  });
}
