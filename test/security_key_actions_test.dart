import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/security_key.dart';
import 'package:shun/domain/host_summary.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/security_key_channel.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/widgets/keychain_sheet.dart';
import 'package:shun/presentation/widgets/security_key_prompt.dart';

import 'support/soft_authenticator.dart';

/// 不连平台：生成、读取直接回测试准备的结果，并记下收到的参数。
class _FakeChannel extends SecurityKeyChannel {
  _FakeChannel() : super(channel: const MethodChannel('test/security_key'));

  SecurityKeyCreated? created;
  List<SecurityKeyResident> residents = const [];
  Object? failWith;
  final calls = <Map<String, Object?>>[];

  @override
  Stream<SecurityKeyStage> get stages => const Stream.empty();

  @override
  Future<SecurityKeyAvailability> availability() async =>
      const SecurityKeyAvailability(nfc: true, nfcEnabled: true, usb: true);

  @override
  Future<void> cancel() async {}

  @override
  Future<SecurityKeyCreated> create({
    required String application,
    required bool resident,
    required bool requirePin,
    String? pin,
  }) async {
    calls.add({
      'application': application,
      'resident': resident,
      'requirePin': requirePin,
      'pin': pin,
    });
    final failure = failWith;
    if (failure != null) throw failure;
    return created!;
  }

  @override
  Future<List<SecurityKeyResident>> listResident({required String pin}) async {
    calls.add({'pin': pin});
    return residents;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final hasKeygen = Process.runSync('which', ['ssh-keygen']).exitCode == 0;
  final skip = !hasKeygen;
  late Directory dir;
  late SoftAuthenticator soft;
  late SoftAuthenticator other;
  final secrets = <String, String>{};

  setUpAll(() async {
    if (!hasKeygen) return;
    dir = await Directory.systemTemp.createTemp('shun-sk-ui-');
    soft = await SoftAuthenticator.create(dir, skEd25519Type);
    other = await SoftAuthenticator.create(dir, skEcdsaType);
  });
  tearDownAll(() async {
    if (hasKeygen) await dir.delete(recursive: true);
  });

  /// 钥匙注册结果的样子：authData 头 + aaguid + 句柄长度 + 句柄 + COSE 公钥。
  Uint8List attested(List<int> handle, Uint8List cose) => Uint8List.fromList([
        ...List.filled(37, 1),
        ...List.filled(16, 2),
        0,
        handle.length,
        ...handle,
        ...cose,
      ]);

  Future<ProviderContainer> open(
    WidgetTester tester,
    _FakeChannel channel, {
    List<Map<String, dynamic>> keys = const [],
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    secrets.clear();
    const storage = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(storage, (call) async {
      final args = (call.arguments as Map?) ?? const {};
      final key = args['key'] as String?;
      switch (call.method) {
        case 'write':
          secrets[key!] = args['value'] as String;
        case 'read':
          return secrets[key];
        case 'delete':
          secrets.remove(key);
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(storage, null));
    SharedPreferences.setMockInitialValues({
      'shun_vault_v1': jsonEncode({
        'hosts': const [],
        'keys': keys,
        'snippets': const [],
        'customGroups': const [],
      }),
    });
    final repository = await VaultRepository.open();
    final container = ProviderContainer(
      overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
        securityKeyChannelProvider.overrideWithValue(channel),
      ],
    );
    addTearDown(container.dispose);
    await container.read(vaultControllerProvider.notifier).ready();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: KeychainSheet()),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  List<SshKeyProfile> keysOf(ProviderContainer container) =>
      container.read(vaultControllerProvider).data!.keys;

  Future<void> openAdd(WidgetTester tester, String option) async {
    await tester.tap(find.byKey(const ValueKey('keychain-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加安全密钥'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey(option)));
    await tester.pumpAndSettle();
  }

  testWidgets('在钥匙上生成：存成句柄文件，给出要贴到服务器的公钥', (tester) async {
    final channel = _FakeChannel();
    final handle = List.generate(20, (index) => index + 1);
    final cose = SoftAuthenticator.coseOf(soft.pair);
    channel.created = SecurityKeyCreated(attested(handle, cose));
    final container = await open(tester, channel);

    await openAdd(tester, 'security-key-create');
    await tester.enterText(
      find.byKey(const ValueKey('security-key-label')),
      'YubiKey',
    );
    await tester.tap(find.byKey(const ValueKey('security-key-resident')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('security-key-create-confirm')));
    await tester.pumpAndSettle();

    expect(channel.calls.single, {
      'application': 'ssh:',
      'resident': true,
      'requirePin': false,
      'pin': null,
    });
    final key = keysOf(container).single;
    expect(key.label, 'YubiKey');
    expect(key.data['type'], 'ED25519-SK');
    final stub = SecurityKeyStub.parse(key.privateKey);
    expect(stub.keyHandle, handle);
    expect(stub.application, 'ssh:');
    expect(stub.flags, skFlagUserPresence | skFlagResident);
    expect(key.data['publicKey'], startsWith(skEd25519Type));
    expect(
      tester
          .widget<SelectableText>(
            find.byKey(const ValueKey('security-key-public-key')),
          )
          .data,
      startsWith(skEd25519Type),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('shun_vault_v1'),
      isNot(contains('OPENSSH PRIVATE KEY')),
      reason: '句柄文件和普通私钥一样进安全存储，不进普通偏好',
    );
    expect(secrets.values.join(), contains('OPENSSH PRIVATE KEY'));
  }, skip: skip);

  testWidgets('要求每次 PIN：先填 PIN，句柄里记上要 PIN', (tester) async {
    final channel = _FakeChannel();
    channel.created = SecurityKeyCreated(
      attested([1, 2, 3], SoftAuthenticator.coseOf(soft.pair)),
    );
    final container = await open(tester, channel);
    await openAdd(tester, 'security-key-create');
    await tester.tap(find.byKey(const ValueKey('security-key-require-pin')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('security-key-create-confirm')));
    await tester.pumpAndSettle();
    expect(channel.calls, isEmpty);
    await tester.enterText(find.byKey(const ValueKey('security-key-pin')), '1234');
    await tester.tap(find.byKey(const ValueKey('security-key-pin-submit')));
    await tester.pumpAndSettle();
    expect(channel.calls.single['pin'], '1234');
    final stub = SecurityKeyStub.parse(keysOf(container).single.privateKey);
    expect(stub.userVerificationRequired, isTrue);
    expect(
      secrets.values.join() + jsonEncode(keysOf(container).single.data),
      isNot(contains('1234')),
      reason: 'PIN 不存',
    );
  }, skip: skip);

  testWidgets('钥匙不支持：报一句人话，什么都不存', (tester) async {
    final channel = _FakeChannel();
    channel.failWith = const SecurityKeyException(SecurityKeyFailure.unsupported);
    final container = await open(tester, channel);
    await openAdd(tester, 'security-key-create');
    await tester.tap(find.byKey(const ValueKey('security-key-create-confirm')));
    await tester.pumpAndSettle();
    expect(find.textContaining('这把钥匙不支持'), findsOneWidget);
    expect(keysOf(container), isEmpty);
  }, skip: skip);

  testWidgets('读钥匙里已有的：要 PIN；已经导入过的不重复加', (tester) async {
    final channel = _FakeChannel();
    channel.residents = [
      SecurityKeyResident(
        application: soft.stub.application,
        credentialId: soft.stub.keyHandle,
        coseKey: CoseKey.parse(SoftAuthenticator.coseOf(soft.pair)),
      ),
      SecurityKeyResident(
        application: 'ssh:work',
        credentialId: Uint8List.fromList([7, 7, 7]),
        coseKey: CoseKey.parse(SoftAuthenticator.coseOf(other.pair)),
      ),
    ];
    final container = await open(tester, channel, keys: const []);
    final notifier = container.read(vaultControllerProvider.notifier);
    final vault = await notifier.ready();
    await notifier.replace(
      vault.copyWith(
        keys: [
          SshKeyProfile({
            'id': 'existing',
            'label': 'existing',
            'privateKey': soft.stub.toPem(),
          }),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await openAdd(tester, 'security-key-read');
    expect(channel.calls, isEmpty, reason: '没填 PIN 不碰钥匙');
    await tester.enterText(find.byKey(const ValueKey('security-key-pin')), '1234');
    await tester.tap(find.byKey(const ValueKey('security-key-pin-submit')));
    await tester.pumpAndSettle();

    expect(find.text('找到 2 把，新增 1 把'), findsOneWidget);
    final keys = keysOf(container);
    expect(keys, hasLength(2));
    final added = SecurityKeyStub.parse(keys.last.privateKey);
    expect(added.application, 'ssh:work');
    expect(added.type, skEcdsaType);
    expect(added.flags, skFlagUserPresence | skFlagResident);
  }, skip: skip);

  testWidgets('列表里只有安全密钥能看公钥；主机摘要写明是安全密钥', (tester) async {
    final channel = _FakeChannel();
    final container = await open(tester, channel);
    final notifier = container.read(vaultControllerProvider.notifier);
    final vault = await notifier.ready();
    final sk = SshKeyProfile({
      'id': 'sk',
      'label': 'yk',
      'type': 'ED25519-SK',
      'privateKey': soft.stub.toPem(),
    });
    await notifier.replace(
      vault.copyWith(
        keys: [
          sk,
          SshKeyProfile({
            'id': 'plain',
            'label': 'plain',
            'type': 'ED25519',
            'privateKey': 'not a stub',
          }),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('keychain-public-key-sk')), findsOneWidget);
    expect(find.byKey(const ValueKey('keychain-public-key-plain')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('keychain-public-key-sk')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SelectableText>(
            find.byKey(const ValueKey('security-key-public-key')),
          )
          .data,
      startsWith(skEd25519Type),
    );

    final host = HostProfile({
      'id': 'h',
      'hostname': 'x',
      'username': 'u',
      'authMethod': 'key',
      'protocol': 'ssh',
    });
    expect(describeLogin(host, sk), '安全密钥“yk”');
  }, skip: skip);
}
