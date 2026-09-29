import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/host_trust.dart';
import 'package:netcatty_mobile/presentation/widgets/host_key_dialogs.dart';

// SEC02 / SEC03 的界面与规则部分：指纹变了一律拒绝（没有一点就过的"确认更新"），
// 只能删除旧指纹后重连、按首次重新核对；第一次见必须用户核对，不自动信任。
// 连接层（认证前断开、sshd 没收到任何登录）见 integration_ssh_fixture_test 的 JMP02 / SEC03。

const host = 'target.example';
const fp = 'SHA256:current';
const oldFp = 'SHA256:old';

Map<String, dynamic> record(String fingerprint, {int port = 22}) => {
      'hostname': host,
      'port': port,
      'keyType': 'ssh-ed25519',
      'fingerprint': fingerprint,
    };

void main() {
  group('checkHostKey 按逻辑主机名 + 端口比对', () {
    ({HostKeyStatus status, Map<String, dynamic>? existing}) check(
      List<Map<String, dynamic>> known, {
      int port = 22,
      String keyType = 'ssh-ed25519',
    }) =>
        checkHostKey(known,
            hostname: host, port: port, keyType: keyType, fingerprint: fp);

    test('没有记录：unknown', () => expect(check([]).status, HostKeyStatus.unknown));
    test('指纹和类型都一致：trusted',
        () => expect(check([record(fp)]).status, HostKeyStatus.trusted));
    test('指纹不同：changed',
        () => expect(check([record(oldFp)]).status, HostKeyStatus.changed));
    test('指纹同但密钥类型不同：changed', () {
      expect(check([record(fp)], keyType: 'rsa-sha2-512').status,
          HostKeyStatus.changed);
    });
    test('同名不同端口是另一台：unknown', () {
      expect(check([record(fp, port: 2222)]).status, HostKeyStatus.unknown);
    });
  });

  group('SEC04 信任身份：写法等价的名字算同一台，别名不隐式建立', () {
    HostKeyStatus statusFor(String stored, String asked, {int port = 22}) =>
        checkHostKey(
          [
            {...record(fp), 'hostname': stored},
          ],
          hostname: asked,
          port: port,
          keyType: 'ssh-ed25519',
          fingerprint: fp,
        ).status;

    test('只是大小写、结尾的点、IPv6 方括号或 IPv6 写法不同：同一台，已信任', () {
      expect(statusFor('Web.Example.COM', 'web.example.com'),
          HostKeyStatus.trusted);
      expect(statusFor('web.example.com', 'web.example.com.'),
          HostKeyStatus.trusted);
      expect(statusFor('[2001:DB8::1]', '2001:db8:0:0:0:0:0:1'),
          HostKeyStatus.trusted);
    });

    test('指向同一个 IP 的另一个名字、换了端口：都要重新核对，不沿用', () {
      expect(statusFor('127.0.0.1', 'localhost'), HostKeyStatus.unknown);
      expect(statusFor('web.example.com', 'web2.example.com'),
          HostKeyStatus.unknown);
      expect(statusFor('web.example.com', 'web.example.com', port: 2222),
          HostKeyStatus.unknown);
    });

    test('写法等价但指纹变了：照样硬阻断', () {
      expect(
        checkHostKey(
          [
            {...record(oldFp), 'hostname': 'WEB.example.com'},
          ],
          hostname: 'web.example.com',
          port: 22,
          keyType: 'ssh-ed25519',
          fingerprint: fp,
        ).status,
        HostKeyStatus.changed,
      );
    });

    test('规范写法', () {
      expect(trustHostName(' Web.Example.COM. '), 'web.example.com');
      expect(trustHostName('[FE80::ABCD]'), 'fe80::abcd');
      expect(trustHostName('0:0::1'), '::1');
    });
  });

  group('verifyHostKeyWithKnownHosts', () {
    late int newPrompts;
    late int changedPrompts;
    late List<List<Map<String, dynamic>>> saves;
    setUp(() {
      newPrompts = 0;
      changedPrompts = 0;
      saves = [];
    });

    Future<bool> verify(
      List<Map<String, dynamic>> known, {
      bool accept = true,
      bool deleteOld = false,
    }) =>
        verifyHostKeyWithKnownHosts(
          knownHosts: known,
          hostname: host,
          port: 22,
          keyType: 'ssh-ed25519',
          fingerprint: fp,
          confirmNew: () async {
            newPrompts++;
            return accept;
          },
          onChanged: (old) async {
            changedPrompts++;
            expect(old, oldFp);
            return deleteOld;
          },
          save: (value) async => saves.add(value),
          now: () => DateTime.fromMillisecondsSinceEpoch(42),
        );

    test('已信任：直接放行，不弹窗、不写', () async {
      expect(await verify([record(fp)]), isTrue);
      expect((newPrompts, changedPrompts, saves.length), (0, 0, 0));
    });

    test('第一次见，用户拒绝：不放行、不记住', () async {
      expect(await verify([], accept: false), isFalse);
      expect(newPrompts, 1);
      expect(saves, isEmpty);
    });

    test('第一次见，用户核对后接受：放行并按逻辑名记住', () async {
      expect(await verify([]), isTrue);
      expect(saves.single.single, {
        ...record(fp),
        'acceptedAt': 42,
      });
    });

    test('指纹变了、用户关闭：拒绝，记录不动', () async {
      expect(await verify([record(oldFp)]), isFalse);
      expect(changedPrompts, 1);
      expect(newPrompts, 0, reason: '不能给变了的指纹弹"接受"对话框');
      expect(saves, isEmpty);
    });

    test('指纹变了、用户选删除旧指纹：这次照样拒绝；下次按首次重新核对，不自动信任', () async {
      final other = {...record(fp), 'hostname': 'other.example'};
      expect(await verify([record(oldFp), other], deleteOld: true), isFalse);
      expect(saves.single, [other], reason: '只删这一台的旧指纹');

      expect(await verify(saves.single, accept: false), isFalse);
      expect(newPrompts, 1, reason: '删掉以后是第一次见，必须重新让用户核对');
    });
  });

  group('弹窗', () {
    Future<bool?> open(
      WidgetTester tester,
      Future<bool> Function(BuildContext context) show,
    ) async {
      bool? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await show(context),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return result;
    }

    Future<bool> changed(BuildContext context) => showChangedHostKey(
          context,
          hostname: host,
          port: 22,
          algorithm: 'ssh-ed25519',
          fingerprint: fp,
          oldFingerprint: oldFp,
        );

    testWidgets('指纹变了：只有「删除旧指纹」和「关闭」，没有任何继续连接的按钮', (tester) async {
      await open(tester, changed);
      expect(find.text('服务器指纹已变化，已阻止连接'), findsOneWidget);
      expect(find.textContaining(fp), findsOneWidget);
      expect(find.textContaining(oldFp), findsOneWidget);
      expect(find.text('删除旧指纹'), findsOneWidget);
      expect(find.text('关闭'), findsOneWidget);
      for (final label in ['确认更新', '接受并记住', '继续', '信任']) {
        expect(find.text(label), findsNothing, reason: label);
      }
    });

    testWidgets('指纹变了：点删除旧指纹返回 true，点关闭返回 false', (tester) async {
      bool? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await changed(context),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('delete-old-host-key')));
      await tester.pumpAndSettle();
      expect(result, isTrue);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
    });

    testWidgets('第一次见：接受返回 true', (tester) async {
      bool? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await confirmNewHostKey(
              context,
              hostname: host,
              port: 22,
              algorithm: 'ssh-ed25519',
              fingerprint: fp,
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('确认服务器指纹'), findsOneWidget);
      await tester.tap(find.text('接受并记住'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
    });
  });
}
