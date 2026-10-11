// SEC05 验证用的入口：用 App 自己的保险库代码（VaultRepository.saveVault，和主机编辑器保存走的是同一条路）
// 写入一份带特征串的假凭据，再读回来确认能解密。之后在设备上翻 App 私有目录、备份产物和日志，
// 搜这些特征串——出现就是明文泄漏。
//
// 用法见 plan/v3/evidence/R09.md。它和正式 App 同一个包名，会覆盖设备上这个 App 的数据，
// 只在测试设备/模拟器上跑。
import 'package:flutter/material.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';

const markers = {
  'hostPassword': 'SEC05-HOST-PW-7f1c',
  'telnetPassword': 'SEC05-TELNET-PW-2b9d',
  'inlineProxyPassword': 'SEC05-INLINE-PROXY-4e0a',
  'profileProxyPassword': 'SEC05-PROFILE-PROXY-9a37',
  'privateKey': 'SEC05-KEY-MATERIAL-c58e',
  'passphrase': 'SEC05-KEY-PASS-61d2',
};

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final repository = await VaultRepository.open();
  await repository.saveVault(VaultData.fromJson({
    'hosts': [
      {
        'id': 'sec05-host',
        'label': 'sec05',
        'hostname': 'sec05.example.com',
        'port': 22,
        'username': 'sec05',
        'protocol': 'ssh',
        'password': markers['hostPassword'],
        'telnetPassword': markers['telnetPassword'],
        'identityFileId': 'sec05-key',
        'proxyConfig': {
          'type': 'socks5',
          'host': '127.0.0.1',
          'port': 1080,
          'username': 'sec05-proxy',
          'password': markers['inlineProxyPassword'],
        },
      },
    ],
    'keys': [
      {
        'id': 'sec05-key',
        'label': 'sec05',
        'privateKey': '-----BEGIN OPENSSH PRIVATE KEY-----\n'
            '${markers['privateKey']}\n-----END OPENSSH PRIVATE KEY-----',
        'passphrase': markers['passphrase'],
      },
    ],
    'proxyProfiles': [
      {
        'id': 'sec05-proxy',
        'label': 'sec05',
        'config': {
          'type': 'socks5',
          'host': 'proxy.example.com',
          'port': 1080,
          'username': 'sec05',
          'password': markers['profileProxyPassword'],
        },
      },
    ],
    'snippets': [],
    'customGroups': [],
  }));
  final back = await repository.loadVault();
  final host = back.hosts.single;
  final roundTrip = host.password == markers['hostPassword'] &&
      back.keys.single.passphrase == markers['passphrase'] &&
      back.keys.single.privateKey.contains(markers['privateKey']!);
  // 只打印布尔值，不打印凭据本身。
  debugPrint('SEC05 seeded: roundTrip=$roundTrip');
  runApp(MaterialApp(
    home: Scaffold(body: Center(child: Text('SEC05 seeded: $roundTrip'))),
  ));
}
