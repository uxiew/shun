import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/tailscale_catalog_refresh.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/widgets/first_login_dialog.dart';

// R26：Tailscale 导入时不统一填用户名和密码，单独连接时再配。什么时候先问、问完得到什么。
void main() {
  HostProfile host(Map<String, Object?> extra) => HostProfile({
        ...HostProfile.create(
          id: 'h',
          label: 'nas',
          hostname: '100.64.0.1',
          username: '',
        ).data,
        ...extra,
      });
  final bound = {
    CatalogBinding.key:
        const CatalogBinding(catalogId: 'c', deviceId: 'd').toJson(),
  };

  test('没有用户名的 SSH / Mosh 主机要问；Telnet、远程桌面不问', () {
    expect(needsFirstLogin(host({})), isTrue);
    expect(needsFirstLogin(host({'protocol': 'mosh'})), isTrue);
    expect(needsFirstLogin(host({'protocol': 'telnet'})), isFalse);
    expect(needsFirstLogin(host({'username': 'admin'})), isFalse,
        reason: '手动建的主机有用户名就照常连，没存密码的在登录那一步问');
  });

  test('目录导入的：没登录成功过、也没密码和私钥时问一次；登录过或配了凭据就不问', () {
    expect(needsFirstLogin(host({...bound, 'username': 'fodelf'})), isTrue);
    expect(
        needsFirstLogin(
            host({...bound, 'username': 'fodelf', 'lastConnectedAt': 1})),
        isFalse);
    expect(
        needsFirstLogin(
            host({...bound, 'username': 'fodelf', 'password': 'x'})),
        isFalse);
    expect(
        needsFirstLogin(
            host({...bound, 'username': 'fodelf', 'identityFileId': 'k'})),
        isFalse);
  });

  testWidgets('用户名必填、不能带空格；密码可以不填；取消什么都不给', (tester) async {
    FirstLogin? result;
    var closed = false;
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    await tester.pumpWidget(ProviderScope(
      overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await askFirstLogin(context, host({}));
              closed = true;
            },
            child: const Text('go'),
          ),
        ),
      ),
    ));
    Future<void> open() async {
      closed = false;
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
    }

    final connect = find.byKey(const ValueKey('first-login-connect'));
    FilledButton button() => tester.widget<FilledButton>(connect);

    await open();
    expect(find.textContaining('100.64.0.1'), findsOneWidget);
    expect(button().onPressed, isNull, reason: '用户名空着');
    await tester.enterText(
        find.byKey(const ValueKey('first-login-username')), 'a b');
    await tester.pump();
    expect(button().onPressed, isNull, reason: '带空格');
    await tester.enterText(
        find.byKey(const ValueKey('first-login-username')), ' fodelf ');
    await tester.pump();
    await tester.tap(connect);
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(result?.username, 'fodelf');
    expect(result?.password, isNull);

    await open();
    await tester.enterText(
        find.byKey(const ValueKey('first-login-username')), 'root');
    await tester.enterText(
        find.byKey(const ValueKey('first-login-password')), 'pw 1');
    await tester.pump();
    await tester.tap(connect);
    await tester.pumpAndSettle();
    expect(result?.password, 'pw 1', reason: '密码原样，不去空格');

    await open();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(result, isNull);
  });
}
