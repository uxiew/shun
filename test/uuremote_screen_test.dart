import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/uuremote.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/models/vault.dart';
import 'package:netcatty_mobile/infrastructure/plugins/uuremote_adapter.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';
import 'package:netcatty_mobile/presentation/screens/uuremote_screen.dart';
import 'package:netcatty_mobile/presentation/screens/vault_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'uuremote_fakes.dart';

// X06 界面：UU 远程页只说 UU 报告了什么，不说「已连接」；绑定回来要用户确认；SSH 经代理时先问；英文界面无汉字。
// 平台层是假的，没有真实 UU 远程。

const id = 'Zm9v+YmFy/YmF6==';

Map<String, String> queryOf(String uri) {
  final raw = uri.substring(uri.indexOf('?') + 1);
  return {
    for (final part in raw.split('&'))
      part.substring(0, part.indexOf('=')):
          Uri.decodeComponent(part.substring(part.indexOf('=') + 1)),
  };
}

String callbackFor(String uri, Map<String, String> fields) =>
    '${queryOf(uri)['callback']}&'
    '${fields.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&')}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  late FakePlatform platform;
  late MemoryBackend backend;
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
    platform = FakePlatform()
      ..probeResult = const UuProbe(
        platformSupported: true,
        officialInstalled: true,
        officialHandlesScheme: true,
        versionName: '4.42.0',
        signers: {
          'ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12'
        },
      );
    backend = MemoryBackend();
  });

  Future<void> open(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(900, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        vaultRepositoryProvider.overrideWithValue(vault),
        uuRemotePlatformProvider.overrideWithValue(platform),
        uuRemoteStoreProvider.overrideWithValue(UuRemoteStore(backend)),
      ],
      child: MaterialApp(home: UuRemoteListener(child: home)),
    ));
    await tester.pumpAndSettle();
  }

  String allText(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
      .join('\n');

  Future<void> approveAndBind(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('uu-approve')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('uu-bind')));
    await tester.pumpAndSettle();
    final uri = platform.launched.last;
    platform.deliver(callbackFor(uri, {
      'anonymous_device_id': id,
      'nonce': queryOf(uri)['nonce']!,
    }));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('uu-offer-confirm')));
    await tester.pumpAndSettle();
  }

  testWidgets('UUR01：没装时说清楚、不能点；装了但证书没核对，批准前不能绑定', (tester) async {
    platform.probeResult = const UuProbe(
      platformSupported: true,
      otherHandlers: ['example.fakeuu'],
    );
    await open(tester, const UuRemoteHostScreen(hostId: 'win'));
    expect(find.byKey(const ValueKey('uu-not-installed')), findsOneWidget);
    expect(find.byKey(const ValueKey('uu-other-handlers')), findsOneWidget);
    expect(
        tester
            .widget<OutlinedButton>(find.byKey(const ValueKey('uu-bind')))
            .onPressed,
        isNull);

    platform.probeResult = const UuProbe(
      platformSupported: true,
      officialInstalled: true,
      officialHandlesScheme: true,
      versionName: '4.42.0',
      signers: {
        'ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12'
      },
    );
    await tester.pumpWidget(const SizedBox());
    await open(tester, const UuRemoteHostScreen(hostId: 'win'));
    expect(find.byKey(const ValueKey('uu-needs-approval')), findsOneWidget);
    expect(find.textContaining('ab12 cd34 ef56'), findsOneWidget);
    expect(
        tester
            .widget<OutlinedButton>(find.byKey(const ValueKey('uu-bind')))
            .onPressed,
        isNull);
    expect(platform.launched, isEmpty);
  });

  testWidgets('UUR02：绑定回来弹确认框，确认后才出现远控按钮；不自动远控；页面上不出现加密标识', (tester) async {
    await open(tester, const UuRemoteHostScreen(hostId: 'win'));
    await approveAndBind(tester);
    expect(find.byKey(const ValueKey('uu-launch-fullscreen')), findsOneWidget);
    expect(find.byKey(const ValueKey('uu-launch-pip')), findsOneWidget);
    expect(platform.launched, hasLength(1));
    expect(allText(tester), isNot(contains(id)));
    expect(backend.values['uuremote.bindings.v1'], contains('win'));
  });

  testWidgets('确认框点「不要」：什么都不存，页面写明没保存', (tester) async {
    await open(tester, const UuRemoteHostScreen(hostId: 'win'));
    await tester.tap(find.byKey(const ValueKey('uu-approve')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('uu-bind')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('uu-end-waiting')), findsOneWidget);
    final uri = platform.launched.last;
    platform.deliver(callbackFor(
        uri, {'anonymous_device_id': id, 'nonce': queryOf(uri)['nonce']!}));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('uu-offer-discard')));
    await tester.pumpAndSettle();
    expect(backend.values['uuremote.bindings.v1'], isNull);
    expect(find.textContaining('你没有保存'), findsOneWidget);
    expect(find.byKey(const ValueKey('uu-launch-fullscreen')), findsNothing);
  });

  testWidgets('UUR03：全屏只写「已交给 UU 远程」，不说已连接，不等回报', (tester) async {
    await open(tester, const UuRemoteHostScreen(hostId: 'win'));
    await approveAndBind(tester);
    await tester.tap(find.byKey(const ValueKey('uu-launch-fullscreen')));
    await tester.pumpAndSettle();
    expect(find.textContaining('全屏模式 UU 不回报结果'), findsOneWidget);
    expect(find.byKey(const ValueKey('uu-end-waiting')), findsNothing);
    for (final word in ['已连接', '在线', '连接成功', 'connected']) {
      expect(allText(tester), isNot(contains(word)));
    }
  });

  testWidgets('UUR04/05：小窗等回报可结束等待；pip_unsupported 只给「改用全屏」，不自动切',
      (tester) async {
    await open(tester, const UuRemoteHostScreen(hostId: 'win'));
    await approveAndBind(tester);
    await tester.tap(find.byKey(const ValueKey('uu-launch-pip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('uu-end-waiting')), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('uu-launch-fullscreen')))
            .onPressed,
        isNull,
        reason: '等回报时不能再发');
    final count = platform.launched.length;
    platform.deliver(callbackFor(platform.launched.last,
        {'status': 'failure', 'reason': 'pip_unsupported'}));
    await tester.pumpAndSettle();
    expect(find.textContaining('不能用小窗'), findsOneWidget);
    expect(find.byKey(const ValueKey('uu-retry-fullscreen')), findsOneWidget);
    expect(platform.launched, hasLength(count));

    await tester.tap(find.byKey(const ValueKey('uu-launch-pip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('uu-end-waiting')));
    await tester.pumpAndSettle();
    expect(find.textContaining('结果未确认'), findsOneWidget);
  });

  testWidgets('UUR07：device_not_found 后只显示这条绑定失效，远控按钮收起', (tester) async {
    await open(tester, const UuRemoteHostScreen(hostId: 'win'));
    await approveAndBind(tester);
    await tester.tap(find.byKey(const ValueKey('uu-launch-pip')));
    await tester.pumpAndSettle();
    platform.deliver(callbackFor(platform.launched.last,
        {'status': 'failure', 'reason': 'device_not_found'}));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('uu-binding-invalid')), findsOneWidget);
    expect(find.byKey(const ValueKey('uu-launch-fullscreen')), findsNothing);
    expect(find.text('重新绑定'), findsOneWidget);
  });

  testWidgets('UUR08：SSH 经代理的主机，远控前先说明 UU 走自己的网络；取消就不发', (tester) async {
    await open(tester, const UuRemoteHostScreen(hostId: 'mac'));
    expect(find.byKey(const ValueKey('uu-route-note')), findsOneWidget);
    await approveAndBind(tester);
    final before = platform.launched.length;
    await tester.tap(find.byKey(const ValueKey('uu-launch-fullscreen')));
    await tester.pumpAndSettle();
    expect(find.text('UU 远程不走这台主机的代理或跳板'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(platform.launched, hasLength(before));
    await tester.tap(find.byKey(const ValueKey('uu-launch-fullscreen')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('uu-route-accept')));
    await tester.pumpAndSettle();
    expect(platform.launched, hasLength(before + 1));
  });

  testWidgets('没有请求时收到的回调：给提示，不弹确认框', (tester) async {
    await open(tester, const UuRemoteHostScreen(hostId: 'win'));
    platform.deliver(
        'xwshun-uuremote://callback/bind?state=AAAAAAAAAAAAAAAAAAAAAA&anonymous_device_id=x&nonce=y');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('uu-offer-confirm')), findsNothing);
    expect(find.textContaining('没有对应的请求'), findsOneWidget);
  });

  testWidgets('UUR06：别的 App 也声明了回调地址，页面说出包名，绑定和小窗不能点，全屏能点；卸载后回到 App 自动恢复',
      (tester) async {
    await open(tester, const UuRemoteHostScreen(hostId: 'win'));
    await approveAndBind(tester);
    final clean = platform.probeResult;
    platform.probeResult = UuProbe(
      platformSupported: true,
      officialInstalled: true,
      officialHandlesScheme: true,
      versionName: '4.42.0',
      signers: clean.signers,
      callbackRivals: const ['example.hijacker'],
    );
    // 用户切出去又回来（比如装了个 App）：回到前台时重查。
    Future<void> leaveAndReturn() async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
    }

    await leaveAndReturn();
    expect(find.byKey(const ValueKey('uu-callback-rivals')), findsOneWidget);
    expect(find.textContaining('example.hijacker'), findsOneWidget);
    VoidCallback? pressed<T extends ButtonStyleButton>(String key) =>
        tester.widget<T>(find.byKey(ValueKey(key))).onPressed;
    expect(pressed<OutlinedButton>('uu-bind'), isNull);
    expect(pressed<OutlinedButton>('uu-launch-pip'), isNull);
    expect(pressed<FilledButton>('uu-launch-fullscreen'), isNotNull);

    platform.probeResult = clean;
    await leaveAndReturn();
    expect(find.byKey(const ValueKey('uu-callback-rivals')), findsNothing);
    expect(pressed<OutlinedButton>('uu-bind'), isNotNull);
  });

  testWidgets('保险库的主机详情：Android 上有「UU 远程」入口', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await open(tester, const Scaffold(body: VaultScreen()));
    await tester.tap(find.text('win-pc'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('host-uuremote')));
    await tester.pumpAndSettle();
    expect(find.byType(UuRemoteHostScreen), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('英文界面：主机的 UU 页（各种状态）和设置总览都没有汉字', (tester) async {
    NetcattyLocalizations.use('en');
    addTearDown(() => NetcattyLocalizations.use('zh'));
    final han = RegExp(r'[一-鿿]');
    void noHan() =>
        expect(han.hasMatch(allText(tester)), isFalse, reason: allText(tester));

    await open(tester, const UuRemoteHostScreen(hostId: 'mac'));
    noHan();
    await tester.tap(find.byKey(const ValueKey('uu-approve')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('uu-bind')));
    await tester.pumpAndSettle();
    noHan();
    final uri = platform.launched.last;
    platform.deliver(callbackFor(
        uri, {'anonymous_device_id': id, 'nonce': queryOf(uri)['nonce']!}));
    await tester.pumpAndSettle();
    noHan(); // 确认框
    await tester.tap(find.byKey(const ValueKey('uu-offer-confirm')));
    await tester.pumpAndSettle();
    noHan();
    await tester.tap(find.byKey(const ValueKey('uu-launch-pip')));
    await tester.pumpAndSettle();
    noHan(); // 路线确认框
    await tester.tap(find.byKey(const ValueKey('uu-route-accept')));
    await tester.pumpAndSettle();
    noHan();
    for (final reason in ['pip_unsupported', 'quantum_flux']) {
      platform.deliver(callbackFor(
          platform.launched.last, {'status': 'failure', 'reason': reason}));
      await tester.pumpAndSettle();
      noHan();
      if (reason == 'pip_unsupported') {
        await tester.tap(find.byKey(const ValueKey('uu-launch-pip')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('uu-route-accept')));
        await tester.pumpAndSettle();
      }
    }
    expect(find.textContaining('quantum_flux'), findsOneWidget);

    // 回调地址被别的 App 也声明：提醒卡片，和请求发出后才出现时的「没有采用」。
    final clean = platform.probeResult;
    await tester.tap(find.byKey(const ValueKey('uu-bind')));
    await tester.pumpAndSettle();
    platform.probeResult = UuProbe(
      platformSupported: true,
      officialInstalled: true,
      officialHandlesScheme: true,
      versionName: '4.42.0',
      signers: clean.signers,
      callbackRivals: const ['example.hijacker'],
    );
    final bind = platform.launched.last;
    platform.deliver(callbackFor(
        bind, {'anonymous_device_id': id, 'nonce': queryOf(bind)['nonce']!}));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('uu-callback-rivals')), findsOneWidget);
    expect(find.byKey(const ValueKey('uu-offer-confirm')), findsNothing);
    noHan();

    await tester.pumpWidget(const SizedBox());
    await open(tester, const UuRemoteSettingsScreen());
    noHan();
  });
}
