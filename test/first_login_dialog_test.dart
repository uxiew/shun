import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/tailscale_catalog_refresh.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/ui/components.dart';
import 'package:shun/presentation/widgets/first_login_dialog.dart';

import 'support/prism_test_host.dart';

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
        localizationsDelegates: prismTestDelegates,
        builder: prismTestBuilder,
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
    ShunButton button() => tester.widget<ShunButton>(connect);

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

  group('UIM10（R89）首次登录', () {
    testWidgets('认证方式是分段：选中状态读屏可见；密码切明文仍不让输入法学；取消不返回东西', (tester) async {
      final handle = tester.ensureSemantics();
      FirstLogin? result = (username: 'x', password: null, identity: null);
      var closed = false;
      SharedPreferences.setMockInitialValues({});
      final repository = await VaultRepository.open();
      await tester.pumpWidget(ProviderScope(
        overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          localizationsDelegates: prismTestDelegates,
          builder: prismTestBuilder,
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
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(find.descendant(
          of: find.byKey(const ValueKey('login-choice-simple')),
          matching: find.bySemanticsLabel('用户名 / 密码'),
        )),
        isSemantics(
          label: '用户名 / 密码',
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          hasTapAction: true,
        ),
      );
      EditableText password() => tester.widget<EditableText>(find.descendant(
          of: find.byKey(const ValueKey('first-login-password')),
          matching: find.byType(EditableText)));
      for (final obscured in [true, false]) {
        expect(password().obscureText, obscured);
        expect(password().enableIMEPersonalizedLearning, isFalse);
        expect(password().enableSuggestions, isFalse);
        expect(password().autocorrect, isFalse);
        await tester.tap(find.descendant(
            of: find.byKey(const ValueKey('first-login-password')),
            matching: find.byType(IconButton)));
        await tester.pump();
      }
      await tester.tap(find.byKey(const ValueKey('first-login-cancel')));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(result, isNull);
      handle.dispose();
    });

    testWidgets('迁移前首次登录的入口一项不少、顺序不变（用户名/密码）', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final repository = await VaultRepository.open();
      await tester.pumpWidget(ProviderScope(
        overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          localizationsDelegates: prismTestDelegates,
          builder: prismTestBuilder,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => askFirstLogin(context, host({})),
              child: const Text('go'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      final keys = [
        for (final element in find
            .descendant(
                of: find.byType(AlertDialog),
                matching:
                    find.byWidgetPredicate((w) => w.key is ValueKey<String>))
            .evaluate())
          (element.widget.key! as ValueKey<String>).value,
      ];
      var at = 0;
      // HEAD 上录到的顺序：认证方式、用户名、密码、连接（认证方式的分段 key 是新增的，不算）。
      const before = [
        'first-login-mode',
        'first-login-username',
        'first-login-password',
        'first-login-connect',
      ];
      for (final key in keys) {
        if (at < before.length && before[at] == key) at++;
      }
      expect(at, before.length, reason: keys.join('\n'));
    });
  });
}
