import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/rustdesk.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/models/vault.dart';
import 'package:netcatty_mobile/infrastructure/plugins/rustdesk_external.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';
import 'package:netcatty_mobile/presentation/screens/rustdesk_screen.dart';
import 'package:netcatty_mobile/presentation/screens/vault_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'rustdesk_fakes.dart';

// X07 界面：RustDesk 页只说「已交给 RustDesk」，不说已连接；填 ID 不发请求；SSH 经代理时先问；
// 别的包声明 rustdesk:// 要用户明确信任；英文界面无汉字。平台层是假的，没有真实 RustDesk。

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  late FakeRustDeskPlatform platform;
  late MemoryRustDeskBackend backend;
  late VaultRepository vault;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async => null);
    SharedPreferences.setMockInitialValues({});
    vault = await VaultRepository.open();
    await vault.saveVault(VaultData.fromJson({
      'hosts': [
        HostProfile.create(
                id: 'win',
                label: 'win-pc',
                hostname: '10.0.0.8',
                username: 'me')
            .toJson(),
        {
          ...HostProfile.create(
                  id: 'mac', label: 'mac', hostname: '10.0.0.9', username: 'me')
              .toJson(),
          'proxyConfig': {'type': 'socks5', 'host': '127.0.0.1', 'port': 1080},
        },
      ],
      'keys': [],
      'snippets': [],
      'customGroups': [],
    }));
    platform = FakeRustDeskPlatform();
    backend = MemoryRustDeskBackend();
  });

  Future<void> open(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(900, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        vaultRepositoryProvider.overrideWithValue(vault),
        rustDeskPlatformProvider.overrideWithValue(platform),
        rustDeskStoreProvider.overrideWithValue(RustDeskStore(backend)),
      ],
      child: MaterialApp(home: home),
    ));
    await tester.pumpAndSettle();
  }

  String allText(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
      .join('\n');

  Future<void> saveId(WidgetTester tester, String id) async {
    await tester.enterText(find.byKey(const ValueKey('rd-id-field')), id);
    await tester.tap(find.byKey(const ValueKey('rd-save')));
    await tester.pumpAndSettle();
  }

  VoidCallback? pressed<T extends ButtonStyleButton>(
          WidgetTester tester, String key) =>
      tester.widget<T>(find.byKey(ValueKey(key))).onPressed;

  testWidgets('填 ID：只保存不发请求；不合规的写在输入框下面、不保存', (tester) async {
    await open(tester, const RustDeskHostScreen(hostId: 'win'));
    expect(find.byKey(const ValueKey('rd-launch')), findsNothing);

    await saveId(tester, 'rustdesk://password/hunter2');
    expect(find.textContaining('不要粘贴链接'), findsOneWidget);
    expect(backend.values, isEmpty);
    await saveId(tester, '123456789?password=hunter2');
    expect(find.textContaining('服务器或密钥'), findsOneWidget);
    expect(backend.values, isEmpty);
    expect(find.byKey(const ValueKey('rd-launch')), findsNothing);

    await saveId(tester, '123 456 789');
    expect(tester.widget<Text>(find.byKey(const ValueKey('rd-peer-id'))).data,
        '123 456 789');
    expect(backend.values['rustdesk.links.v1'], contains('"123456789"'));
    expect(find.byKey(const ValueKey('rd-launch')), findsOneWidget);
    expect(platform.launched, isEmpty);
    expect(find.byKey(const ValueKey('rd-attempt')), findsNothing);
  });

  testWidgets('RDX03：点远控后只写「已交给 RustDesk」，写明交给了哪个包哪个版本，不说已连接', (tester) async {
    await open(tester, const RustDeskHostScreen(hostId: 'win'));
    await saveId(tester, '123456789');
    await tester.tap(find.byKey(const ValueKey('rd-launch')));
    await tester.pumpAndSettle();
    expect(platform.launched.single.$1, 'rustdesk://connect/123456789');
    expect(find.textContaining('已交给 RustDesk。它不向本 App 回报结果'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('rd-attempt-target'))).data,
      contains('com.carriez.flutter_hbb 1.4.9'),
    );
    // 切出去（到 RustDesk）再回来：状态不变，没有任何东西把它改成「已连接」或「已结束」。
    for (final state in const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(find.textContaining('已交给 RustDesk。它不向本 App 回报结果'), findsOneWidget);
    for (final word in ['已连接', '在线', '连接成功', '已断开', '已结束', 'connected']) {
      expect(allText(tester), isNot(contains(word)), reason: word);
    }
    // 回到前台只重查手机上装了什么，不会再发一次请求。
    expect(platform.launched, hasLength(1));
  });

  testWidgets('系统没接下启动：写「没能打开 RustDesk」和原因，不写已交给', (tester) async {
    await open(tester, const RustDeskHostScreen(hostId: 'win'));
    await saveId(tester, '123456789');
    platform.failLaunch = 'RustDesk 没有接收这个请求（版本可能太旧，或被停用了）';
    await tester.tap(find.byKey(const ValueKey('rd-launch')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('rd-attempt-text'))).data,
      '没能打开 RustDesk：RustDesk 没有接收这个请求（版本可能太旧，或被停用了）',
    );
    expect(find.textContaining('已交给 RustDesk。'), findsNothing);
  });

  testWidgets('RDX01：没装时说清楚、远控不能点；别的包声明了 rustdesk:// 只列出，信任后才可用',
      (tester) async {
    platform.probeResult = RustDeskProbe(
      platformSupported: true,
      handlers: [
        custom(signers: {
          'ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12'
        }),
      ],
    );
    await open(tester, const RustDeskHostScreen(hostId: 'win'));
    await saveId(tester, '123456789');
    expect(find.byKey(const ValueKey('rd-not-installed')), findsOneWidget);
    expect(find.byKey(const ValueKey('rd-other-com.example.myrustdesk')),
        findsOneWidget);
    expect(find.textContaining('ab12 cd34 ef56'), findsOneWidget);
    expect(pressed<FilledButton>(tester, 'rd-launch'), isNull);

    // 点「信任并改用」先弹确认框；取消就什么都不变。
    await tester
        .tap(find.byKey(const ValueKey('rd-trust-com.example.myrustdesk')));
    await tester.pumpAndSettle();
    expect(find.text('信任这个 App、改用它来远控？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(pressed<FilledButton>(tester, 'rd-launch'), isNull);
    expect(backend.values['rustdesk.trust.v1'], isNull);

    await tester
        .tap(find.byKey(const ValueKey('rd-trust-com.example.myrustdesk')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rd-trust-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('这是你明确信任的客户端。本 App 没有核对过它的来源。'), findsOneWidget);
    // 它只是版本号对得上：不替它说「按源码核对过」。
    expect(find.text('这个版本的连接链接按源码核对过。'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('rd-launch')));
    await tester.pumpAndSettle();
    expect(platform.launched.single.$2, 'com.example.myrustdesk');

    // 撤销信任：回到「没装」，不能再发。
    await tester.tap(find.byKey(const ValueKey('rd-revoke')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rd-not-installed')), findsOneWidget);
    expect(pressed<FilledButton>(tester, 'rd-launch'), isNull);
  });

  testWidgets('RDX01：官方包名但证书不认识，批准前不能发；证书再变就停', (tester) async {
    RustDeskProbe withCert(String cert) => RustDeskProbe(
          platformSupported: true,
          handlers: [
            official(signers: {cert})
          ],
          officialInstalled: official(signers: {cert}),
        );
    platform.probeResult = withCert(
        'ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12');
    await open(tester, const RustDeskHostScreen(hostId: 'win'));
    await saveId(tester, '123456789');
    expect(find.byKey(const ValueKey('rd-needs-approval')), findsOneWidget);
    expect(pressed<FilledButton>(tester, 'rd-launch'), isNull);
    await tester.tap(find.byKey(const ValueKey('rd-approve')));
    await tester.pumpAndSettle();
    expect(pressed<FilledButton>(tester, 'rd-launch'), isNotNull);

    platform.probeResult = withCert(
        'ffffcd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rd-signer-changed')), findsOneWidget);
    expect(pressed<FilledButton>(tester, 'rd-launch'), isNull);
    expect(platform.launched, isEmpty);
  });

  testWidgets('RDX04：SSH 经代理的主机，远控前先说明 RustDesk 走自己的网络；取消就不发', (tester) async {
    await open(tester, const RustDeskHostScreen(hostId: 'mac'));
    await saveId(tester, '123456789');
    expect(find.byKey(const ValueKey('rd-route-note')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('rd-launch')));
    await tester.pumpAndSettle();
    expect(find.text('RustDesk 不走这台主机的代理或跳板'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(platform.launched, isEmpty);
    expect(find.byKey(const ValueKey('rd-attempt')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('rd-launch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rd-route-accept')));
    await tester.pumpAndSettle();
    expect(platform.launched.single.$1, 'rustdesk://connect/123456789');
  });

  testWidgets('RDX05：版本说明跟着装着的版本走；太旧不能发', (tester) async {
    RustDeskProbe version(String v) => RustDeskProbe(
          platformSupported: true,
          handlers: [official(version: v)],
          officialInstalled: official(version: v),
        );
    Future<void> reprobe(String v) async {
      platform.probeResult = version(v);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
    }

    await open(tester, const RustDeskHostScreen(hostId: 'win'));
    await saveId(tester, '123456789');
    expect(find.text('这个版本的连接链接按源码核对过。'), findsOneWidget);

    await reprobe('1.4.6');
    expect(find.byKey(const ValueKey('rd-version-ungated')), findsOneWidget);
    expect(pressed<FilledButton>(tester, 'rd-launch'), isNotNull);

    await reprobe('1.6.0');
    expect(find.byKey(const ValueKey('rd-version-unverified')), findsOneWidget);
    expect(pressed<FilledButton>(tester, 'rd-launch'), isNotNull);

    await reprobe('1.2.3');
    expect(find.byKey(const ValueKey('rd-too-old')), findsOneWidget);
    expect(pressed<FilledButton>(tester, 'rd-launch'), isNull);
  });

  testWidgets('改 ID、删除：只动这一条关联', (tester) async {
    await open(tester, const RustDeskHostScreen(hostId: 'win'));
    await saveId(tester, '123456789');
    await tester.tap(find.byKey(const ValueKey('rd-edit')));
    await tester.pumpAndSettle();
    await saveId(tester, 'office-pc');
    expect(tester.widget<Text>(find.byKey(const ValueKey('rd-peer-id'))).data,
        'office-pc');

    await tester.tap(find.byKey(const ValueKey('rd-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rd-delete-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rd-id-field')), findsOneWidget);
    expect(backend.values['rustdesk.links.v1'], '[]');
    expect(platform.launched, isEmpty);
    // 主机还在保险库里。
    expect((await vault.loadVault()).hosts.map((h) => h.id), contains('win'));
  });

  testWidgets('保险库的主机详情：Android 上有「RustDesk」入口', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await open(tester, const Scaffold(body: VaultScreen()));
    await tester.tap(find.text('win-pc'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('host-rustdesk')));
    await tester.pumpAndSettle();
    expect(find.byType(RustDeskHostScreen), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('设置总览：列出各主机的 RustDesk ID，可以删', (tester) async {
    await open(tester, const RustDeskHostScreen(hostId: 'win'));
    await saveId(tester, '123456789');
    await tester.pumpWidget(const SizedBox());
    await open(tester, const RustDeskSettingsScreen());
    expect(find.text('win-pc'), findsOneWidget);
    expect(find.text('RustDesk ID: 123 456 789'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('还没有主机填过 RustDesk ID。'), findsOneWidget);
  });

  testWidgets('英文界面：主机的 RustDesk 页（各种状态）和设置总览都没有汉字', (tester) async {
    NetcattyLocalizations.use('en');
    addTearDown(() => NetcattyLocalizations.use('zh'));
    final han = RegExp(r'[一-鿿]');
    void noHan() =>
        expect(han.hasMatch(allText(tester)), isFalse, reason: allText(tester));
    Future<void> reprobe(RustDeskProbe probe) async {
      platform.probeResult = probe;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      noHan();
    }

    await open(tester, const RustDeskHostScreen(hostId: 'mac'));
    noHan();
    // 每一种拒收原因都显示一遍。
    for (final bad in [
      '',
      'rustdesk://connect/1',
      '1@evil.example',
      '123456789/r',
      '10.0.0.1',
      'a b',
      'x\u0001yzabcd',
      '1' * 120,
    ]) {
      await saveId(tester, bad);
      noHan();
    }
    await saveId(tester, '123456789');
    noHan();
    await tester.tap(find.byKey(const ValueKey('rd-launch')));
    await tester.pumpAndSettle();
    noHan(); // 路线确认框
    await tester.tap(find.byKey(const ValueKey('rd-route-accept')));
    await tester.pumpAndSettle();
    noHan();
    for (final failure in [
      '只发 RustDesk 的连接链接',
      '没有指定要交给哪个 RustDesk',
      '要交给的那个 RustDesk 已经不在手机上了',
      'RustDesk 的签名证书和核对过的不一致，没有发送',
      'RustDesk 没有接收这个请求（版本可能太旧，或被停用了）',
      '系统不允许打开 RustDesk',
      '只支持 Android',
    ]) {
      platform.failLaunch = failure;
      await tester.tap(find.byKey(const ValueKey('rd-launch')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rd-route-accept')));
      await tester.pumpAndSettle();
      noHan();
    }
    platform.failLaunch = null;
    await tester.tap(find.byKey(const ValueKey('rd-delete')));
    await tester.pumpAndSettle();
    noHan(); // 删除确认框
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // 手机上的 RustDesk 的各种状态。
    await reprobe(const RustDeskProbe(platformSupported: false));
    await reprobe(const RustDeskProbe(platformSupported: true));
    for (final v in ['1.2.3', '1.4.6', '1.6.0', 'nightly']) {
      await reprobe(RustDeskProbe(
        platformSupported: true,
        handlers: [official(version: v)],
        officialInstalled: official(version: v),
      ));
    }
    await reprobe(RustDeskProbe(
      platformSupported: true,
      handlers: [
        official(signers: {fdroidCert}),
        custom(),
        custom(package: 'com.example.two', signers: {'a', 'b'}),
      ],
    ));
    await tester
        .tap(find.byKey(const ValueKey('rd-trust-com.example.myrustdesk')));
    await tester.pumpAndSettle();
    noHan(); // 信任确认框
    await tester.tap(find.byKey(const ValueKey('rd-trust-confirm')));
    await tester.pumpAndSettle();
    noHan();
    await reprobe(RustDeskProbe(
      platformSupported: true,
      handlers: [
        custom(signers: {'cert-changed'})
      ],
    ));
    expect(find.byKey(const ValueKey('rd-signer-changed')), findsOneWidget);
    await reprobe(RustDeskProbe(
      platformSupported: true,
      handlers: [
        official(signers: {'x', 'y'})
      ],
    ));
    await reprobe(RustDeskProbe(
      platformSupported: true,
      handlers: [
        official(signers: {'cert-unknown'})
      ],
    ));
    expect(find.byKey(const ValueKey('rd-needs-approval')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await open(tester, const RustDeskSettingsScreen());
    noHan();
  });
}
