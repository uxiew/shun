// MOS08：mosh-server 引导输出的解析——恶意、超长、非法端口、注入字符、locale 异常都要有界解析、失败即关，
// 错误信息和 toString 里不出现 key。真实输出样本取自 tool/mosh-fixture 里的 mosh-server 1.4.0（key 换成了假的）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/plugins/mosh_bootstrap.dart';

const _key = 'v450/k6rhyS3hwDL4ejCIQ'; // 规范 base64（最后一位 Q 的低 4 位为 0）
const _real = '\r\n'
    'MOSH CONNECT 60101 $_key\r\n'
    '\n'
    'mosh-server (mosh 1.4.0) [build mosh 1.4.0]\n'
    'Copyright 2012 Keith Winstein <mosh-devel@mit.edu>\n'
    'License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>.\n'
    'This is free software: you are free to change and redistribute it.\n'
    'There is NO WARRANTY, to the extent permitted by law.\n'
    '\n'
    '[mosh-server detached, pid = 27]\n';

List<int> _b(String s) => utf8.encode(s);

Matcher _fails(MoshBootstrapFailure f) => throwsA(
      isA<MoshBootstrapException>().having((e) => e.failure, 'failure', f),
    );

void main() {
  group('命令', () {
    test('固定命令，只有端口范围可变', () {
      expect(MoshBootstrap.command(),
          'mosh-server new -s -c 256 -l LANG=en_US.UTF-8 -p 60001:60999');
      expect(MoshBootstrap.command(portRange: (60101, 60108)),
          'mosh-server new -s -c 256 -l LANG=en_US.UTF-8 -p 60101:60108');
      expect(MoshBootstrap.command(portRange: (60101, 60101)),
          endsWith('-p 60101'));
    });

    test('端口范围无效就不拼命令', () {
      for (final r in [(0, 10), (10, 65536), (60010, 60001), (-1, 5)]) {
        expect(() => MoshBootstrap.command(portRange: r), throwsArgumentError,
            reason: '$r');
      }
    });
  });

  group('解析真实输出', () {
    test('mosh-server 1.4.0 的原样输出（CRLF、版权、detached 行）', () {
      final r = MoshBootstrap.parse(_b(_real));
      expect(r.port, 60101);
      expect(ascii.decode(r.printableKey), _key);
    });

    test('toString 不带 key；wipe 之后 key 全 0、再取报错', () {
      final r = MoshBootstrap.parse(_b(_real));
      expect('$r', isNot(contains(_key)));
      final bytes = r.printableKey;
      r.wipe();
      expect(bytes.every((b) => b == 0), isTrue);
      expect(() => r.printableKey, throwsStateError);
    });

    test('前面有 motd、非 UTF-8 字节、ANSI 颜色也不影响认那一行', () {
      final noisy = <int>[
        ..._b('\x1b[1;31mWelcome\x1b[0m\n'),
        0xff,
        0xfe,
        0x00,
        0x0a,
        ..._b('MOSH CONNECT 60001 $_key\n'),
      ];
      expect(MoshBootstrap.parse(noisy).port, 60001);
    });
  });

  group('失败即关', () {
    test('两条都像真的：不取第一条', () {
      expect(
        () => MoshBootstrap.parse(_b(
            'MOSH CONNECT 60001 $_key\nMOSH CONNECT 60002 AAAAAAAAAAAAAAAAAAAAAA\n')),
        _fails(MoshBootstrapFailure.ambiguous),
      );
    });

    test('同一行夹了别的东西（前缀、后缀、行中 \\r 覆盖、制表符、多空格）', () {
      for (final line in [
        'echo MOSH CONNECT 60001 $_key',
        'MOSH CONNECT 60001 $_key; rm -rf ~',
        'MOSH CONNECT 60001 $_key extra',
        'MOSH CONNECT 1 AAAAAAAAAAAAAAAAAAAAAA\rMOSH CONNECT 60001 $_key',
        'MOSH CONNECT\t60001 $_key',
        'MOSH CONNECT  60001 $_key',
        ' MOSH CONNECT 60001 $_key',
        'MOSH CONNECT 60001 $_key\x00',
      ]) {
        expect(() => MoshBootstrap.parse(_b('$line\n')),
            _fails(MoshBootstrapFailure.malformed),
            reason: jsonEncode(line));
      }
    });

    test('端口：0、前导 0、6 位、超过 65535、不在请求范围、非数字', () {
      for (final port in ['0', '060001', '600010', '99999', 'abc', '-1', '']) {
        expect(() => MoshBootstrap.parse(_b('MOSH CONNECT $port $_key\n')),
            _fails(MoshBootstrapFailure.malformed),
            reason: port);
      }
      expect(() => MoshBootstrap.parse(_b('MOSH CONNECT 65535 $_key\n')),
          _fails(MoshBootstrapFailure.portOutOfRange));
      expect(() => MoshBootstrap.parse(_b('MOSH CONNECT 22 $_key\n')),
          _fails(MoshBootstrapFailure.portOutOfRange));
      expect(
          MoshBootstrap.parse(_b('MOSH CONNECT 22 $_key\n'),
              portRange: (22, 22)).port,
          22);
    });

    test('key：长短不对、带 = 或 -_、非规范 base64', () {
      for (final key in [
        'AAAAAAAAAAAAAAAAAAAAA', // 21
        'AAAAAAAAAAAAAAAAAAAAAAA', // 23
        'AAAAAAAAAAAAAAAAAAAA==',
        'AAAAAAAAAAAAAAAAAAAAA-',
        'AAAAAAAAAAAAAAAAAAAAA_',
        'AAAAAAAAAAAAAAAAAAAAAé',
      ]) {
        expect(() => MoshBootstrap.parse(_b('MOSH CONNECT 60001 $key\n')),
            _fails(MoshBootstrapFailure.malformed),
            reason: key);
      }
      // 最后一位 B 的低 4 位不是 0：能解码，但不是 mosh-server 会打出来的规范写法。
      expect(
          () => MoshBootstrap.parse(
              _b('MOSH CONNECT 60001 AAAAAAAAAAAAAAAAAAAAAB\n')),
          _fails(MoshBootstrapFailure.badKey));
    });

    test('超长输出直接拒绝，不逐行扫', () {
      final huge = Uint8List(MoshBootstrap.maxOutputBytes + 1)
        ..fillRange(0, MoshBootstrap.maxOutputBytes + 1, 0x41);
      expect(() => MoshBootstrap.parse(huge),
          _fails(MoshBootstrapFailure.outputTooLarge));
      // 恰好在上限内、连接行在最后：照常解析
      final line = _b('\nMOSH CONNECT 60001 $_key\n');
      final edge = Uint8List(MoshBootstrap.maxOutputBytes)
        ..fillRange(0, MoshBootstrap.maxOutputBytes - line.length, 0x41)
        ..setRange(MoshBootstrap.maxOutputBytes - line.length,
            MoshBootstrap.maxOutputBytes, line);
      expect(MoshBootstrap.parse(edge).port, 60001);
    });

    test('locale 不支持：明确报出来，不算「没收到」', () {
      // glibc 系统上 LANG 指向没生成的 locale 时 mosh-server 1.4.0 的原话（Alpine/musl 上测不出，见 tool/mosh-fixture/README.md）
      const out = 'mosh-server needs a UTF-8 native locale to run.\n\n'
          'Unfortunately, the local environment ([no charset variables]) specifies\n'
          'the character set "US-ASCII",\n\n'
          'The client-supplied environment (LANG=en_US.UTF-8) specifies\n'
          'the character set "US-ASCII".\n\n';
      expect(() => MoshBootstrap.parse(_b(out)),
          _fails(MoshBootstrapFailure.localeUnsupported));
    });

    test('远端没装 mosh-server（sh / bash / zsh 的说法）', () {
      for (final out in [
        'sh: mosh-server: not found\n',
        'bash: mosh-server: command not found\n',
        'zsh: command not found: mosh-server\n',
      ]) {
        expect(() => MoshBootstrap.parse(_b(out)),
            _fails(MoshBootstrapFailure.serverMissing),
            reason: out);
      }
    });

    test('空输出、只有别的话', () {
      expect(() => MoshBootstrap.parse(const []),
          _fails(MoshBootstrapFailure.noConnectLine));
      expect(() => MoshBootstrap.parse(_b('Permission denied\n')),
          _fails(MoshBootstrapFailure.noConnectLine));
    });

    test('错误信息从不带原始输出和 key', () {
      for (final out in [
        'MOSH CONNECT 60001 $_key\nMOSH CONNECT 60001 $_key\n',
        'MOSH CONNECT 1 $_key\n',
        'garbage MOSH CONNECT 60001 $_key\n',
      ]) {
        try {
          MoshBootstrap.parse(_b(out));
          fail('应当失败：$out');
        } on MoshBootstrapException catch (e) {
          expect('$e', isNot(contains(_key)));
          expect('$e', isNot(contains('MOSH CONNECT')));
        }
      }
    });
  });
}
