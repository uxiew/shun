import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/infrastructure/plugins/uuremote_adapter.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';

// X06：UU 远程官方协议的请求构造与回调解析（docs/17「X06 固定的官方口径」，提交 be7d8109）。
// 纯逻辑：这里的回调都是手写的，证明本 App 怎么处理输入，不证明真实 UU 会发什么。

const state = 'AAAAAAAAAAAAAAAAAAAAAA'; // 22 个 base64url 字符
const nonce = '0b0f7c6e-2a51-4d7a-9a3c-5d1e8f2b7c40';

String bind(String query) => 'xwshun-uuremote://callback/bind?$query';
String control(String query) => 'xwshun-uuremote://callback/control?$query';

/// 只按官方说法「保留 callback 原参数、追加结果字段」拼回调，值编码一次。
String appendTo(String callback, Map<String, String> fields) =>
    '$callback&${fields.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&')}';

void main() {
  group('请求：参数只编码一次，和官方 Android 示例的 Uri.encode 一致', () {
    test('绑定：callback 整体编码，里面的 ? = 也编码；nonce 原样', () {
      final callback = UuRequests.callback(UuCallbackKind.bind, state);
      expect(callback, 'xwshun-uuremote://callback/bind?state=$state');
      final uri = UuRequests.authorize(callback: callback, nonce: nonce);
      expect(
        uri,
        'uuremote://external/device/authorize'
        '?callback=xwshun-uuremote%3A%2F%2Fcallback%2Fbind%3Fstate%3D$state'
        '&nonce=$nonce',
      );
      // 对方解一次就回到原值（没有双重编码）。
      final parsed = Uri.parse(uri).queryParameters;
      expect(parsed['callback'], callback);
      expect(parsed['nonce'], nonce);
    });

    test('远控：特殊字符的加密 ID 编码后能原样解回；全屏不带 callback', () {
      const id = 'aB+/=%&?# 中é~';
      final full = UuRequests.control(
        anonymousDeviceId: id,
        window: UuWindow.fullscreen,
      );
      expect(full, isNot(contains('callback')));
      expect(full, contains('&window_type=0'));
      final raw =
          RegExp(r'anonymous_device_id=([^&]*)').firstMatch(full)!.group(1)!;
      expect(raw, isNot(contains('+')));
      expect(raw, isNot(contains(' ')));
      expect(Uri.decodeComponent(raw), id);

      final pip = UuRequests.control(
        anonymousDeviceId: id,
        window: UuWindow.pip,
        callback: UuRequests.callback(UuCallbackKind.control, state),
      );
      expect(pip, contains('&window_type=1&callback=xwshun-uuremote%3A%2F%2F'));
    });
  });

  group('UUR02 绑定回调：严格一次解码', () {
    test('成功：%2B %2F %3D 解一次；字面的 + 保持 +；%252B 只解成 %2B', () {
      final cb = parseUuCallback(bind(
        'state=$state&anonymous_device_id=ab%2Bc%2Fd%3D+x%252B&nonce=$nonce',
      )) as UuBindCallback;
      expect(cb.anonymousDeviceId, 'ab+c/d=+x%2B');
      expect(cb.nonce, nonce);
      expect(cb.error, isNull);
    });

    test('按官方「保留原参数、追加结果」拼出的回调能解析', () {
      const id = 'Zm9v+YmFy/YmF6==';
      final cb = parseUuCallback(appendTo(
        UuRequests.callback(UuCallbackKind.bind, state),
        {'anonymous_device_id': id, 'nonce': nonce},
      )) as UuBindCallback;
      expect(cb.anonymousDeviceId, id);
    });

    test('失败：error 原文保留（未知错误码也保留，由调用方显示）', () {
      for (final code in ['user_cancel', 'superseded', 'brand_new_code']) {
        final cb =
            parseUuCallback(bind('state=$state&error=$code&nonce=$nonce'))
                as UuBindCallback;
        expect(cb.error, code);
        expect(cb.anonymousDeviceId, isNull);
      }
    });

    test('nonce 字段是空值也照样解析出来（官方：没传时回传空值），是否对得上由调用方判', () {
      final cb = parseUuCallback(bind('state=$state&error=timeout&nonce='))
          as UuBindCallback;
      expect(cb.nonce, '');
    });

    final rejects = {
      '成功和失败同时出现':
          'state=$state&anonymous_device_id=x&error=timeout&nonce=$nonce',
      '成功和失败都没有': 'state=$state&nonce=$nonce',
      '空的设备标识': 'state=$state&anonymous_device_id=&nonce=$nonce',
      '空的错误码': 'state=$state&error=&nonce=$nonce',
      '缺 nonce': 'state=$state&anonymous_device_id=x',
      '重复的 nonce':
          'state=$state&anonymous_device_id=x&nonce=$nonce&nonce=$nonce',
      '重复的设备标识':
          'state=$state&anonymous_device_id=x&anonymous_device_id=y&nonce=$nonce',
      '重复的 state': 'state=$state&state=$state&error=timeout&nonce=$nonce',
      '超长设备标识': 'state=$state&anonymous_device_id=${'a' * 4097}&nonce=$nonce',
      '控制字符': 'state=$state&anonymous_device_id=a%0Ab&nonce=$nonce',
      '坏的百分号编码': 'state=$state&anonymous_device_id=a%zz&nonce=$nonce',
      '坏的 UTF-8': 'state=$state&anonymous_device_id=%FF%FE&nonce=$nonce',
      '空参数': 'state=$state&&anonymous_device_id=x&nonce=$nonce',
      '没有 state': 'anonymous_device_id=x&nonce=$nonce',
      'state 格式不对': 'state=short&anonymous_device_id=x&nonce=$nonce',
      '参数太多': 'state=$state&error=timeout&nonce=$nonce'
          '${List.generate(10, (i) => '&p$i=1').join()}',
    };
    for (final MapEntry(key: name, value: query) in rejects.entries) {
      test('拒收：$name', () {
        expect(
          () => parseUuCallback(bind(query)),
          throwsA(isA<UuCallbackRejected>()),
        );
      });
    }

    test('英文界面：拒收原因连同外面那句提示都翻得完整（带参数名的按片段翻）', () {
      NetcattyLocalizations.use('en');
      addTearDown(() => NetcattyLocalizations.use('zh'));
      final han = RegExp(r'[一-鿿]');
      for (final query in rejects.values) {
        try {
          parseUuCallback(bind(query));
        } on UuCallbackRejected catch (e) {
          final shown =
              NetcattyLocalizations.text('收到一条格式不对的 UU 回调，已忽略：${e.message}');
          expect(han.hasMatch(shown), isFalse, reason: shown);
        }
      }
      expect(
        NetcattyLocalizations.text('回调参数重复出现：nonce'),
        'Duplicate callback parameter: nonce',
      );
    });

    test('刚好 4096 字符的设备标识收；整条回调超过 16 KiB 拒收', () {
      final ok = parseUuCallback(bind(
        'state=$state&anonymous_device_id=${'a' * 4096}&nonce=$nonce',
      )) as UuBindCallback;
      expect(ok.anonymousDeviceId!.length, 4096);
      expect(
        () => parseUuCallback(bind('state=$state&x=${'a' * 17000}')),
        throwsA(isA<UuCallbackRejected>()),
      );
    });

    test('未知参数不影响（官方以后可能加字段），但计入参数个数', () {
      final cb = parseUuCallback(
        bind('state=$state&error=timeout&nonce=$nonce&future_field=1'),
      ) as UuBindCallback;
      expect(cb.error, 'timeout');
    });
  });

  group('UUR06 回调地址本身', () {
    for (final raw in [
      'evil://callback/bind?state=$state&error=timeout&nonce=$nonce',
      'xwshun-uuremote://evil/bind?state=$state&error=timeout&nonce=$nonce',
      'xwshun-uuremote://callback/other?state=$state&error=timeout&nonce=$nonce',
      'xwshun-uuremote://callback/bind/extra?state=$state&error=timeout&nonce=$nonce',
      'xwshun-uuremote://user@callback/bind?state=$state&error=timeout&nonce=$nonce',
      'xwshun-uuremote://callback:1/bind?state=$state&error=timeout&nonce=$nonce',
      'xwshun-uuremote://callback/bind?state=$state&error=timeout&nonce=$nonce#x',
      'https://callback/bind?state=$state&error=timeout&nonce=$nonce',
      '',
    ]) {
      test('拒收：$raw', () {
        expect(() => parseUuCallback(raw), throwsA(isA<UuCallbackRejected>()));
      });
    }
  });

  group('UUR04 小窗回调', () {
    test('成功不带 reason；失败带 reason；未知 reason 原样保留', () {
      final ok = parseUuCallback(control('state=$state&status=success'))
          as UuControlCallback;
      expect(ok.success, isTrue);
      final fail = parseUuCallback(
        control('state=$state&status=failure&reason=pip_unsupported'),
      ) as UuControlCallback;
      expect((fail.success, fail.reason), (false, 'pip_unsupported'));
      final unknown = parseUuCallback(
        control('state=$state&status=failure&reason=quantum_flux'),
      ) as UuControlCallback;
      expect(unknown.reason, 'quantum_flux');
    });

    for (final query in [
      'state=$state&status=success&reason=busy',
      'state=$state&status=failure',
      'state=$state&status=failure&reason=',
      'state=$state&status=ok',
      'state=$state&success=1',
      'state=$state&status=success&status=failure&reason=busy',
    ]) {
      test('拒收：$query', () {
        expect(
          () => parseUuCallback(control(query)),
          throwsA(isA<UuCallbackRejected>()),
        );
      });
    }
  });

  group('UUR01 版本与证书', () {
    test('版本号：4.42.0 起支持', () {
      for (final v in [
        '4.42.0',
        '4.42',
        '4.42.1',
        '4.100.0',
        '5.0.0',
        '4.42.0.1234',
        '4.42.0-beta'
      ]) {
        expect(uuVersionSupported(v), isTrue, reason: v);
      }
      for (final v in ['4.41.9', '4.9.99', '3.99.0', 'abc', '', null]) {
        expect(uuVersionSupported(v), isFalse, reason: '$v');
      }
    });

    UuProbe installed({
      String version = '4.42.0',
      Set<String> signers = const {'aa'},
      bool handles = true,
      List<String> others = const [],
    }) =>
        UuProbe(
          platformSupported: true,
          officialInstalled: true,
          officialHandlesScheme: handles,
          versionName: version,
          signers: signers,
          otherHandlers: others,
        );

    test('没装、只有别的 App 声明 uuremote、版本太旧、官方包不接 scheme：都不可用', () {
      expect(evaluateUuApp(const UuProbe(platformSupported: false)),
          isA<UuPlatformUnsupported>());
      final notInstalled = evaluateUuApp(const UuProbe(
        platformSupported: true,
        otherHandlers: ['example.fakeuu'],
      ));
      expect(notInstalled, isA<UuNotInstalled>());
      expect(
          (notInstalled as UuNotInstalled).otherHandlers, ['example.fakeuu']);
      expect(evaluateUuApp(installed(version: '4.41.0'), approvedSigner: 'aa'),
          isA<UuVersionTooOld>());
      expect(evaluateUuApp(installed(handles: false), approvedSigner: 'aa'),
          isA<UuSchemeNotHandled>());
    });

    test('证书：官方固定的直接可用；否则要批准；批准后换签不可用；多签名不支持', () {
      expect(
        evaluateUuApp(installed(), official: {'aa'}),
        isA<UuReady>().having((r) => r.official, 'official', isTrue),
      );
      expect(evaluateUuApp(installed(), official: {'bb'}),
          isA<UuSignerNeedsApproval>());
      expect(
        evaluateUuApp(installed(), official: {}, approvedSigner: 'aa'),
        isA<UuReady>().having((r) => r.official, 'official', isFalse),
      );
      expect(evaluateUuApp(installed(), official: {}, approvedSigner: 'cc'),
          isA<UuSignerChanged>());
      expect(
          evaluateUuApp(installed(signers: {'aa', 'bb'}), approvedSigner: 'aa'),
          isA<UuSignerUnsupported>());
      expect(evaluateUuApp(installed(signers: {}), approvedSigner: 'aa'),
          isA<UuSignerUnsupported>());
    });

    test('官方证书还没固定（没核对过官方 APK）', () {
      expect(UuRemoteProtocol.officialSigners, isEmpty);
    });
  });
}
