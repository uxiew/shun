import 'package:flutter_test/flutter_test.dart';
import 'package:shun/infrastructure/plugins/rustdesk_external.dart';

import 'rustdesk_fakes.dart';

// X07：RustDesk ID 的校验、唯一一种连接链接、发给谁的判定、版本矩阵。
// 规则的出处是冻结的 RustDesk 1.4.9 源码（plan/v3/docs/17「X07 固定的 RustDesk 口径」）。
// 这里证明的是本 App 构造什么、拒绝什么；不证明真实 RustDesk 收到之后做什么。

/// 照 RustDesk 1.4.9 的 urlLinkToCmdArgs 写的最小复刻：一条链接会被它解读成「连哪个 ID、带什么」。
/// 只用来回答一个问题：本 App 构造的链接，RustDesk 读出来的 ID 是不是用户填的那个、有没有多出别的东西。
({String? command, String? id, Map<String, String> query, bool sensitive})
    asRustDeskReadsIt(String link) {
  final uri = Uri.parse(link);
  const options = [
    'connect',
    'play',
    'file-transfer',
    'view-camera',
    'port-forward',
    'rdp',
    'terminal',
    'terminal-admin',
  ];
  String? command;
  String? id;
  var sensitive = false;
  if (uri.authority == 'connection' && uri.path.startsWith('/new/')) {
    command = '--connect';
    id = uri.path.substring('/new/'.length);
  } else if (uri.authority == 'config' || uri.authority == 'password') {
    sensitive = true;
  } else if (options.contains(uri.authority)) {
    command = '--${uri.authority}';
    if (uri.path.length > 1) id = uri.path.substring(1);
  } else if (uri.authority.length > 2 &&
      (uri.path.length <= 1 ||
          uri.path == '/r' ||
          uri.path.startsWith('/r@'))) {
    command = '--connect';
    id = uri.authority + (uri.path.length > 1 ? uri.path : '');
  }
  return (
    command: command,
    id: id,
    query: uri.queryParameters.map((k, v) => MapEntry(k.toLowerCase(), v)),
    sensitive: sensitive,
  );
}

void main() {
  group('RDX02 RustDesk ID', () {
    test('纯数字：去掉 RustDesk 界面显示的空格，1 到 16 位', () {
      expect(RustDeskPeerId.parse('123456789').value, '123456789');
      expect(RustDeskPeerId.parse('123 456 789').value, '123456789');
      expect(RustDeskPeerId.parse('  1 234 567 890\n').value, '1234567890');
      // 桌面端的 ID 由网卡地址算出，可能很短。
      expect(RustDeskPeerId.parse('7').value, '7');
      expect(RustDeskPeerId.parse('1234567890123456').value, hasLength(16));
      expect(() => RustDeskPeerId.parse('12345678901234567'),
          throwsA(isA<RustDeskPeerIdRejected>()));
    });

    test('自定义 ID：字母开头，共 6 到 16 位的字母、数字、下划线、连字符，大小写原样', () {
      for (final id in [
        'office',
        'My-PC_01',
        'a12345',
        'Abcdefghijklmnop',
        // 这三个恰好是 RustDesk 链接里的命令词：放在 connect/ 后面就只是 ID。
        'config',
        'password',
        'terminal',
      ]) {
        expect(RustDeskPeerId.parse(id).value, id);
      }
      for (final id in [
        'short', // 5 位
        'Abcdefghijklmnopq', // 17 位
        '1abcdef', // 数字开头又不是纯数字
        '_abcdef',
        'my pc 01', // 自定义 ID 里不能有空格
        '办公室电脑01',
        'officeé',
      ]) {
        expect(() => RustDeskPeerId.parse(id),
            throwsA(isA<RustDeskPeerIdRejected>()),
            reason: id);
      }
    });

    test('恶意或带参数的输入一律拒收，并说出是哪一类', () {
      String reasonOf(String input) {
        try {
          RustDeskPeerId.parse(input);
        } on RustDeskPeerIdRejected catch (e) {
          return e.message;
        }
        fail('应当拒收：$input');
      }

      // 带密码、密钥、改配置的。
      expect(reasonOf('123456789?password=hunter2'), contains('服务器或密钥'));
      expect(reasonOf('123456789?key=abc'), contains('服务器或密钥'));
      expect(reasonOf('123456789@evil.example'), contains('服务器或密钥'));
      expect(
          reasonOf('123456789@evil.example:21116?key=x'), contains('服务器或密钥'));
      // 整条链接，包括改配置、改密码的。
      for (final link in [
        'rustdesk://connect/123456789',
        'rustdesk://config/eyJob3N0IjoiZXZpbCJ9',
        'rustdesk://password/hunter2',
        'https://evil.example/x',
        'intent://connect/1#Intent;scheme=rustdesk;end',
      ]) {
        expect(reasonOf(link), contains('不要粘贴链接'), reason: link);
      }
      // 强制中继后缀。
      expect(reasonOf('123456789/r'), contains('强制中继'));
      expect(reasonOf(r'123456789\r'), contains('强制中继'));
      // 直连地址。
      expect(reasonOf('192.168.1.20'), contains('IP 或域名'));
      expect(reasonOf('pc.example.com:21118'), contains('IP 或域名'));
      expect(reasonOf('fe80::1'), contains('IP 或域名'));
      // 路径、片段、百分号编码、换行和别的控制字符。
      for (final input in [
        '123456789/../config/x',
        'connect/123456789',
        '123456789#frag',
        '123456789%3Fpassword%3Dx',
        '123456789&relay=1',
        'office;id',
        "office'--",
        'office<script>',
      ]) {
        expect(() => RustDeskPeerId.parse(input),
            throwsA(isA<RustDeskPeerIdRejected>()),
            reason: input);
      }
      expect(reasonOf('123456\n789'), contains('控制字符'));
      expect(reasonOf('office\u0000x'), contains('控制字符'));
      expect(reasonOf('office\u007f'), contains('控制字符'));
      expect(reasonOf(''), contains('还没填'));
      expect(reasonOf('   '), contains('还没填'));
      expect(reasonOf('1' * 200), contains('太长'));
    });

    test('链接只有一种写法：rustdesk://connect/<ID>，没有查询参数、片段、用户信息、端口', () {
      for (final input in [
        '123 456 789',
        '7',
        'office',
        'My-PC_01',
        'config',
        'password',
        'terminal-admin1',
      ]) {
        final peer = RustDeskPeerId.parse(input);
        final link = peer.connectUri;
        expect(link, 'rustdesk://connect/${peer.value}');
        expect(rustDeskConnectUri.hasMatch(link), isTrue, reason: link);
        final uri = Uri.parse(link);
        expect(uri.scheme, 'rustdesk');
        expect(uri.host, 'connect');
        expect(uri.hasQuery, isFalse);
        expect(uri.hasFragment, isFalse);
        expect(uri.userInfo, isEmpty);
        expect(uri.hasPort, isFalse);
        // RustDesk 读出来的就是这个 ID，动作是连接，没有任何附带参数，也不是改配置的链接。
        final read = asRustDeskReadsIt(link);
        expect(read.command, '--connect');
        expect(read.id, peer.value);
        expect(read.query, isEmpty);
        expect(read.sensitive, isFalse);
      }
    });

    test('为什么不用 rustdesk://<ID>：大小写会丢，命令词会被当成命令', () {
      // 同一个 ID 换成把 ID 放在主机名位置的写法，RustDesk 读出来就不是它了。
      expect(asRustDeskReadsIt('rustdesk://My-PC_01').id, isNot('My-PC_01'));
      expect(asRustDeskReadsIt('rustdesk://password').sensitive, isTrue);
      expect(asRustDeskReadsIt('rustdesk://config').sensitive, isTrue);
      expect(asRustDeskReadsIt('rustdesk://terminal').id, isNull);
    });

    test('白名单正则挡住别的动作、参数和改配置的链接', () {
      for (final link in [
        'rustdesk://connect/123456789?password=x',
        'rustdesk://connect/123456789?relay',
        'rustdesk://connect/123456789/r',
        'rustdesk://connect/123456789@evil.example',
        'rustdesk://connect/',
        'rustdesk://connect/12345678901234567',
        'rustdesk://connect/abc',
        'rustdesk://123456789',
        'rustdesk://connection/new/123456789',
        'rustdesk://config/eyJ9',
        'rustdesk://password/hunter2',
        'rustdesk://file-transfer/123456789',
        'rustdesk://terminal-admin/123456789',
        'rustdesk://port-forward/123456789',
        'RUSTDESK://connect/123456789',
        'rustdesk://connect/123456789\n',
        ' rustdesk://connect/123456789',
        'uuremote://external/device/control?anonymous_device_id=x',
      ]) {
        expect(rustDeskConnectUri.hasMatch(link), isFalse, reason: link);
      }
    });

    test('数字 ID 按 RustDesk 的习惯三位一组显示，自定义 ID 原样', () {
      expect(RustDeskPeerId.parse('123456789').display, '123 456 789');
      expect(RustDeskPeerId.parse('1234567890').display, '1 234 567 890');
      expect(RustDeskPeerId.parse('12345').display, '12 345');
      expect(RustDeskPeerId.parse('7').display, '7');
      expect(RustDeskPeerId.parse('My-PC_01').display, 'My-PC_01');
    });
  });

  group('RDX05 版本矩阵', () {
    test('按冻结的源码分段', () {
      RustDeskVersionSupport of(String? v) => rustDeskVersionSupport(v);
      expect(of('1.1.9'), RustDeskVersionSupport.tooOld);
      expect(of('1.2.3'), RustDeskVersionSupport.tooOld);
      expect(of('1.2.4'), RustDeskVersionSupport.deepLinksUngated);
      expect(of('1.3.9'), RustDeskVersionSupport.deepLinksUngated);
      expect(of('1.4.6'), RustDeskVersionSupport.deepLinksUngated);
      expect(of('1.4.7'), RustDeskVersionSupport.verified);
      expect(of('1.4.9'), RustDeskVersionSupport.verified);
      expect(of('1.4.9-1'), RustDeskVersionSupport.verified);
      expect(of('1.5.0'), RustDeskVersionSupport.verified);
      expect(of('1.5.1'), RustDeskVersionSupport.newerUnverified);
      expect(of('2.0.0'), RustDeskVersionSupport.newerUnverified);
      expect(of('1.10'), RustDeskVersionSupport.newerUnverified);
      expect(of(null), RustDeskVersionSupport.unreadable);
      expect(of('nightly'), RustDeskVersionSupport.unreadable);
    });
  });

  group('RDX01 发给谁', () {
    RustDeskProbe probe(
      List<RustDeskClient> handlers, {
      RustDeskClient? installed,
    }) =>
        RustDeskProbe(
          platformSupported: true,
          handlers: handlers,
          officialInstalled: installed ??
              handlers
                  .where((c) => c.package == RustDeskProtocol.officialPackage)
                  .firstOrNull,
        );

    test('不是 Android：不支持', () {
      expect(
        evaluateRustDeskApp(const RustDeskProbe(platformSupported: false)),
        isA<RustDeskPlatformUnsupported>(),
      );
    });

    test('什么都没装：没装', () {
      final status = evaluateRustDeskApp(probe([]));
      expect(status, isA<RustDeskNotInstalled>());
      expect(status.others, isEmpty);
    });

    test('官方包名 + GitHub 发行版证书：直接可用', () {
      final status = evaluateRustDeskApp(probe([official()])) as RustDeskReady;
      expect(status.source, RustDeskTrustSource.githubRelease);
      expect(status.client.package, RustDeskProtocol.officialPackage);
      expect(status.signer, githubCert);
      expect(status.version, RustDeskVersionSupport.verified);
    });

    test('官方包名 + F-Droid 证书：直接可用，渠道另记', () {
      final status = evaluateRustDeskApp(
        probe([
          official(signers: {fdroidCert})
        ]),
      ) as RustDeskReady;
      expect(status.source, RustDeskTrustSource.fdroid);
    });

    test('官方包名 + 不认识的证书：要用户批准；批准的是这一张，再变就停', () {
      final resigned = probe([
        official(signers: {'cert-x'})
      ]);
      final needs = evaluateRustDeskApp(resigned);
      expect(needs, isA<RustDeskSignerNeedsApproval>());
      expect((needs as RustDeskSignerNeedsApproval).signer, 'cert-x');

      const trust = RustDeskTrust(
          package: RustDeskProtocol.officialPackage, signer: 'cert-x');
      final ready =
          evaluateRustDeskApp(resigned, trust: trust) as RustDeskReady;
      expect(ready.source, RustDeskTrustSource.userApproved);

      final changed = evaluateRustDeskApp(
        probe([
          official(signers: {'cert-y'})
        ]),
        trust: trust,
      );
      expect(changed, isA<RustDeskSignerChanged>());
      expect((changed as RustDeskSignerChanged).approved, 'cert-x');
      expect(changed.current, 'cert-y');
    });

    test('批准过别的证书，后来换回发行版证书：直接可用', () {
      final status = evaluateRustDeskApp(
        probe([official()]),
        trust: const RustDeskTrust(
            package: RustDeskProtocol.officialPackage, signer: 'cert-x'),
      ) as RustDeskReady;
      expect(status.source, RustDeskTrustSource.githubRelease);
    });

    test('只有别的包声明了 rustdesk://：仍算没装，只把它列出来', () {
      final status = evaluateRustDeskApp(probe([custom()]));
      expect(status, isA<RustDeskNotInstalled>());
      expect(status.others.single.package, 'com.example.myrustdesk');
    });

    test('别的包报出发行版的证书也不算数：发行渠道证书只对官方包名有效', () {
      final status = evaluateRustDeskApp(
        probe([
          custom(signers: {githubCert})
        ]),
      );
      expect(status, isA<RustDeskNotInstalled>());
      // 用户信任了这个包：可用，但算「你信任的」，页面不会写成「和 GitHub 官方发行版的一致」。
      final trusted = evaluateRustDeskApp(
        probe([
          custom(signers: {githubCert})
        ]),
        trust: const RustDeskTrust(
            package: 'com.example.myrustdesk', signer: githubCert),
      ) as RustDeskReady;
      expect(trusted.source, RustDeskTrustSource.userApproved);
    });

    test('官方包和别的包都在：用官方包，别的只列出', () {
      final status =
          evaluateRustDeskApp(probe([custom(), official()])) as RustDeskReady;
      expect(status.client.package, RustDeskProtocol.officialPackage);
      expect(status.others.single.package, 'com.example.myrustdesk');
    });

    test('用户信任了自建客户端：用它；它换签就停；它卸载了回到官方包', () {
      const trust =
          RustDeskTrust(package: 'com.example.myrustdesk', signer: 'cert-mine');
      final both = probe([custom(), official()]);
      final ready = evaluateRustDeskApp(both, trust: trust) as RustDeskReady;
      expect(ready.client.package, 'com.example.myrustdesk');
      expect(ready.source, RustDeskTrustSource.userApproved);
      expect(ready.others.single.package, RustDeskProtocol.officialPackage);

      final changed = evaluateRustDeskApp(
        probe([
          custom(signers: {'cert-other'}),
          official()
        ]),
        trust: trust,
      );
      expect(changed, isA<RustDeskSignerChanged>());
      expect((changed as RustDeskSignerChanged).client.package,
          'com.example.myrustdesk');

      final gone = evaluateRustDeskApp(probe([official()]), trust: trust)
          as RustDeskReady;
      expect(gone.client.package, RustDeskProtocol.officialPackage);
      expect(
        evaluateRustDeskApp(probe([]), trust: trust),
        isA<RustDeskNotInstalled>(),
      );
    });

    test('信任的是 A 包，手机上只有 B 包：B 不因此可用', () {
      final status = evaluateRustDeskApp(
        probe([custom(package: 'com.example.other')]),
        trust: const RustDeskTrust(
            package: 'com.example.myrustdesk', signer: 'cert-mine'),
      );
      expect(status, isA<RustDeskNotInstalled>());
    });

    test('多张证书共同签名：不支持', () {
      expect(
        evaluateRustDeskApp(
          probe([
            official(signers: {githubCert, 'cert-x'})
          ]),
        ),
        isA<RustDeskSignerUnsupported>(),
      );
      expect(
        evaluateRustDeskApp(probe([official(signers: {})])),
        isA<RustDeskSignerUnsupported>(),
      );
    });

    test('版本太旧：1.2.3 即使声明了 scheme 也不发；装着但不接链接也算太旧', () {
      expect(
        evaluateRustDeskApp(probe([official(version: '1.2.3')])),
        isA<RustDeskVersionTooOld>(),
      );
      final dormant = evaluateRustDeskApp(
        probe([custom()], installed: official(version: '1.1.9')),
      );
      expect(dormant, isA<RustDeskVersionTooOld>());
      expect((dormant as RustDeskVersionTooOld).client.versionName, '1.1.9');
      expect(dormant.others.single.package, 'com.example.myrustdesk');
    });

    test('版本段带进可用状态：旧版提醒、新版没核对过、看不懂', () {
      RustDeskVersionSupport of(String version) =>
          (evaluateRustDeskApp(probe([official(version: version)]))
                  as RustDeskReady)
              .version;
      expect(of('1.4.6'), RustDeskVersionSupport.deepLinksUngated);
      expect(of('1.4.9'), RustDeskVersionSupport.verified);
      expect(of('1.6.0'), RustDeskVersionSupport.newerUnverified);
      expect(of('custom-build'), RustDeskVersionSupport.unreadable);
    });

    test('固定的证书是 64 位小写十六进制', () {
      for (final cert in RustDeskProtocol.knownSigners.keys) {
        expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(cert), isTrue);
      }
      expect(RustDeskProtocol.knownSigners[githubCert],
          RustDeskChannel.githubRelease);
      expect(RustDeskProtocol.knownSigners[fdroidCert], RustDeskChannel.fdroid);
    });

    test('信任记录读写；坏数据读成没有', () {
      const trust = RustDeskTrust(package: 'p', signer: 's');
      final back = RustDeskTrust.fromJson(trust.toJson())!;
      expect((back.package, back.signer), ('p', 's'));
      expect(RustDeskTrust.fromJson({'package': 'p'}), isNull);
      expect(RustDeskTrust.fromJson('x'), isNull);
    });
  });
}
