import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/security_key.dart';
import 'package:shun/infrastructure/ssh/security_key_channel.dart';
import 'package:shun/presentation/widgets/security_key_prompt.dart';

import 'support/prism_test_host.dart';

/// 不连平台的通道：阶段由测试自己发，记下有没有调 cancel。
class _FakeChannel extends SecurityKeyChannel {
  _FakeChannel({this.nfcEnabled = true})
      : super(channel: const MethodChannel('test/security_key'));

  final bool nfcEnabled;
  final stageEvents = StreamController<SecurityKeyStage>.broadcast();
  var cancelCalls = 0;

  /// 当前那一轮：取消时以「取消」结束，和真桥一样。
  Completer<Object>? inFlight;

  @override
  Stream<SecurityKeyStage> get stages => stageEvents.stream;

  @override
  Future<SecurityKeyAvailability> availability() async =>
      SecurityKeyAvailability(
        nfc: true,
        nfcEnabled: nfcEnabled,
        usb: true,
      );

  @override
  Future<void> cancel() async {
    cancelCalls += 1;
    final current = inFlight;
    if (current != null && !current.isCompleted) {
      current.completeError(
        const SecurityKeyException(SecurityKeyFailure.cancelled),
      );
    }
  }
}

void main() {
  /// 打开对话框，把最后的结果（值或错误）记下来。
  Future<List<Object?>> open(
    WidgetTester tester,
    _FakeChannel channel, {
    required Future<Object> Function(String? pin) run,
    bool pinFirst = false,
    bool pinOnNoCredential = false,
    Future<void>? abort,
    Duration wait = const Duration(seconds: 60),
  }) async {
    final outcome = <Object?>[];
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: prismTestDelegates,
        builder: prismTestBuilder,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              try {
                outcome.add(
                  await showSecurityKeyPrompt<Object>(
                    context,
                    channel,
                    title: 'title',
                    detail: 'fixture@web',
                    run: run,
                    pinFirst: pinFirst,
                    pinOnNoCredential: pinOnNoCredential,
                    abort: abort,
                    wait: wait,
                  ),
                );
              } on SecurityKeyException catch (error) {
                outcome.add(error);
              }
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump();
    return outcome;
  }

  String status(WidgetTester tester) => tester
      .widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('security-key-status')),
          matching: find.byType(Text),
        ),
      )
      .data!;

  Future<void> enterPin(WidgetTester tester, String pin) async {
    await tester.enterText(find.byKey(const ValueKey('security-key-pin')), pin);
    await tester.tap(find.byKey(const ValueKey('security-key-pin-submit')));
    await tester.pump();
  }

  testWidgets('写明登录哪台机器；阶段变了提示跟着变；完成就关', (tester) async {
    final channel = _FakeChannel();
    final result = Completer<Object>();
    final outcome = await open(tester, channel, run: (_) => result.future);
    expect(find.text('fixture@web'), findsOneWidget);
    expect(status(tester), contains('贴到手机背面'));

    channel.stageEvents.add(SecurityKeyStage.communicating);
    await tester.pump();
    expect(status(tester), contains('别拿开'));
    channel.stageEvents.add(SecurityKeyStage.waitingForTouch);
    await tester.pump();
    expect(status(tester), '碰一下钥匙');

    result.complete('done');
    await tester.pumpAndSettle();
    expect(outcome, ['done']);
    expect(find.text('fixture@web'), findsNothing);
    expect(channel.cancelCalls, 0);
  });

  testWidgets('NFC 关着时说清楚，不让人白贴', (tester) async {
    final channel = _FakeChannel(nfcEnabled: false);
    final result = Completer<Object>();
    await open(tester, channel, run: (_) => result.future);
    await tester.pump();
    expect(status(tester), contains('NFC 没打开'));
    result.complete('done');
    await tester.pumpAndSettle();
  });

  testWidgets('要 PIN 的密钥：先填 PIN 再贴钥匙，短了不浪费机会', (tester) async {
    final channel = _FakeChannel();
    final pins = <String?>[];
    final outcome = await open(
      tester,
      channel,
      pinFirst: true,
      run: (pin) async {
        pins.add(pin);
        return 'done';
      },
    );
    expect(pins, isEmpty, reason: 'NFC 上不能让人贴着打字，所以没填完不开始');
    await enterPin(tester, '123');
    expect(pins, isEmpty);
    expect(find.text('PIN 至少 4 位'), findsOneWidget);
    await enterPin(tester, '1234');
    await tester.pumpAndSettle();
    expect(pins, ['1234']);
    expect(outcome, ['done']);
  });

  testWidgets('PIN 错了：写出剩余次数，等用户再填，绝不自己重试', (tester) async {
    final channel = _FakeChannel();
    final pins = <String?>[];
    final outcome = await open(
      tester,
      channel,
      pinFirst: true,
      run: (pin) async {
        pins.add(pin);
        if (pin == '1111') {
          throw const SecurityKeyException(
            SecurityKeyFailure.pinInvalid,
            pinRetries: 3,
          );
        }
        return 'done';
      },
    );
    await enterPin(tester, '1111');
    await tester.pump();
    await tester.pump();
    expect(pins, ['1111']);
    expect(find.textContaining('还能试 3 次'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('security-key-pin')))
          .controller!
          .text,
      isEmpty,
      reason: '错的 PIN 不留在框里',
    );
    await tester.pump(const Duration(seconds: 5));
    expect(pins, ['1111'], reason: '等多久都不自己重试');

    await enterPin(tester, '2222');
    await tester.pumpAndSettle();
    expect(pins, ['1111', '2222']);
    expect(outcome, ['done']);
  });

  testWidgets('没填 PIN 时钥匙要 PIN：转成问 PIN', (tester) async {
    final channel = _FakeChannel();
    final pins = <String?>[];
    await open(
      tester,
      channel,
      run: (pin) async {
        pins.add(pin);
        if (pin == null) {
          throw const SecurityKeyException(SecurityKeyFailure.pinRequired);
        }
        return 'done';
      },
    );
    await tester.pump();
    expect(find.text('这把钥匙要 PIN'), findsOneWidget);
    await enterPin(tester, '1234');
    await tester.pumpAndSettle();
    expect(pins, [null, '1234']);
  });

  testWidgets('别的失败直接报出去', (tester) async {
    final channel = _FakeChannel();
    final outcome = await open(
      tester,
      channel,
      run: (_) async => throw const SecurityKeyException(
        SecurityKeyFailure.pinBlocked,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      (outcome.single! as SecurityKeyException).failure,
      SecurityKeyFailure.pinBlocked,
    );
  });

  testWidgets('resident 密钥说找不到：可能是没 PIN 看不见，问一次；还找不到才报错', (tester) async {
    final channel = _FakeChannel();
    final pins = <String?>[];
    final outcome = await open(
      tester,
      channel,
      pinOnNoCredential: true,
      run: (pin) async {
        pins.add(pin);
        throw const SecurityKeyException(SecurityKeyFailure.noCredential);
      },
    );
    await tester.pump();
    expect(find.text('这把钥匙可能要 PIN'), findsOneWidget);
    await enterPin(tester, '1234');
    await tester.pumpAndSettle();
    expect(pins, [null, '1234']);
    expect(
      (outcome.single! as SecurityKeyException).failure,
      SecurityKeyFailure.noCredential,
    );
  });

  testWidgets('点取消：停掉桥那头的操作，报取消', (tester) async {
    final channel = _FakeChannel();
    channel.inFlight = Completer<Object>();
    final outcome = await open(
      tester,
      channel,
      run: (_) => channel.inFlight!.future,
    );
    await tester.tap(find.byKey(const ValueKey('security-key-cancel')));
    await tester.pumpAndSettle();
    expect(channel.cancelCalls, 1);
    expect(
      (outcome.single! as SecurityKeyException).failure,
      SecurityKeyFailure.cancelled,
    );
  });

  testWidgets('等太久：按超时报，不说成用户取消', (tester) async {
    final channel = _FakeChannel();
    channel.inFlight = Completer<Object>();
    final outcome = await open(
      tester,
      channel,
      run: (_) => channel.inFlight!.future,
      wait: const Duration(seconds: 2),
    );
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(channel.cancelCalls, 1);
    expect(
      (outcome.single! as SecurityKeyException).failure,
      SecurityKeyFailure.timeout,
    );
  });

  testWidgets('连接被取消：框跟着关，不留在屏幕上等人碰', (tester) async {
    final channel = _FakeChannel();
    channel.inFlight = Completer<Object>();
    final abort = Completer<void>();
    final outcome = await open(
      tester,
      channel,
      run: (_) => channel.inFlight!.future,
      abort: abort.future,
    );
    abort.complete();
    await tester.pumpAndSettle();
    expect(find.text('fixture@web'), findsNothing);
    expect(
      (outcome.single! as SecurityKeyException).failure,
      SecurityKeyFailure.cancelled,
    );
  });

  testWidgets('没有页面可弹：报要人来，不碰钥匙', (tester) async {
    final channel = _FakeChannel();
    await expectLater(
      signWithSecurityKey(
        null,
        channel,
        SecurityKeySignRequest(
          key: SecurityKeyStub(
            type: skEd25519Type,
            publicKey: Uint8List(1),
            application: 'ssh:',
            flags: skFlagUserPresence,
            keyHandle: Uint8List(1),
          ),
          data: Uint8List(1),
          hostLabel: 'web',
          username: 'fixture',
        ),
      ),
      throwsA(isA<SecurityKeyNeedsUser>()),
    );
  });

  test('翻译 Kotlin 报的错误码：名字对得上，带剩余次数，认不出的算通信失败', () {
    for (final failure in SecurityKeyFailure.values) {
      expect(securityKeyExceptionOf(failure.name, null).failure, failure);
    }
    expect(
      securityKeyExceptionOf('pinInvalid', {'pinRetries': 2}).pinRetries,
      2,
    );
    expect(
      securityKeyExceptionOf('whatever', null).failure,
      SecurityKeyFailure.transport,
    );
  });

  group('UIM10（R89）钥匙询问框', () {
    /// 按钮读屏上是带名字、可点、可用的按钮（换成别的实现也一样）。
    Future<void> expectButton(
        WidgetTester tester, String key, String label) async {
      // 对话框淡入走完，读屏节点才排除掉底下的页面。
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester.getSemantics(find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.bySemanticsLabel(label),
        )),
        isSemantics(
          label: label,
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
    }

    testWidgets('等钥匙：状态句和取消 key 在，取消是按钮，没有 PIN 框', (tester) async {
      final handle = tester.ensureSemantics();
      final channel = _FakeChannel();
      final result = Completer<Object>();
      final outcome = await open(tester, channel, run: (_) => result.future);
      expect(find.byKey(const ValueKey('security-key-status')), findsOneWidget);
      expect(find.byKey(const ValueKey('security-key-pin')), findsNothing);
      expect(
          find.byKey(const ValueKey('security-key-pin-submit')), findsNothing);
      await expectButton(tester, 'security-key-cancel', '取消');
      await tester.tap(find.byKey(const ValueKey('security-key-cancel')));
      await tester.pumpAndSettle();
      expect((outcome.single as SecurityKeyException).failure,
          SecurityKeyFailure.cancelled);
      expect(channel.cancelCalls, 1);
      handle.dispose();
    });

    testWidgets('PIN 框：打码、三个输入法开关全关、没有「显示」眼睛，继续是按钮', (tester) async {
      final handle = tester.ensureSemantics();
      final channel = _FakeChannel();
      await open(tester, channel,
          run: (_) => Completer<Object>().future, pinFirst: true);
      final field = tester
          .widget<TextField>(find.byKey(const ValueKey('security-key-pin')));
      expect(field.obscureText, isTrue);
      expect(field.enableSuggestions, isFalse);
      expect(field.autocorrect, isFalse);
      expect(field.enableIMEPersonalizedLearning, isFalse);
      // 换成 ShunSecretField 会多一个眼睛：PIN 不给切明文。
      expect(find.byTooltip('显示密码'), findsNothing);
      expect(find.byType(IconButton), findsNothing);
      await expectButton(tester, 'security-key-pin-submit', '继续');
      await tester.tap(find.byKey(const ValueKey('security-key-cancel')));
      await tester.pumpAndSettle();
      handle.dispose();
    });

    testWidgets('PIN 错：提示 key 在，框留着让用户决定再不再试', (tester) async {
      final channel = _FakeChannel();
      await open(tester, channel,
          run: (_) async => throw const SecurityKeyException(
              SecurityKeyFailure.pinInvalid,
              pinRetries: 5),
          pinFirst: true);
      await enterPin(tester, '1234');
      await tester.pump();
      expect(
          find.byKey(const ValueKey('security-key-pin-note')), findsOneWidget);
      expect(find.byKey(const ValueKey('security-key-pin')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('security-key-cancel')));
      await tester.pumpAndSettle();
    });
  });
}
