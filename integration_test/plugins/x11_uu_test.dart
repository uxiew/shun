// X11 UUR06 设备对抗：伪造、重放、nonce 不对的 UU 回调，以及别的 App 抢注本 App 的回调地址。
// 由 `tool/x11-device.py uu` 编排，别直接跑。用的是真的 UuRemoteController 和 Kotlin 桥；对端是假 UU（plugins/fixture-fakeuu），
// 伪造回调由电脑端用 am start 从系统那层发进来，和别的 App 能做的一样。假 UU 走通不代表真 UU 可用。
// 过期的回调要等 10 分钟，这里不测，单测用可控时钟测（test/uuremote_controller_test.dart）。
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shun/application/plugin_registry.dart';
import 'package:shun/application/uuremote.dart';
import 'package:shun/infrastructure/plugins/uuremote_adapter.dart';

void report(String key, Object? value) => debugPrint('X11 $key=$value');

Future<void> until(bool Function() done,
    {Duration timeout = const Duration(seconds: 30)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('等待超时');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('X11 UU 回调对抗', (tester) async {
    final files = await getApplicationSupportDirectory();
    Future<void> action(String name) async {
      final ack = File('${files.path}/x11-ack-$name');
      if (ack.existsSync()) ack.deleteSync();
      debugPrint('X11 ACTION $name');
      await until(ack.existsSync, timeout: const Duration(minutes: 2));
    }

    final container = ProviderContainer();
    addTearDown(container.dispose);
    // 不走 uuRemoteProvider：它要先初始化保险库。平台桥、加密存储、注册表都是 App 里的那份，
    // 只是不挂 SSH 主机（这里不测路线，路线在 UUR08 的单测里）。
    final ctrl = UuRemoteController(
      platform: container.read(uuRemotePlatformProvider),
      store: container.read(uuRemoteStoreProvider),
      registry: container.read(pluginRegistryProvider.notifier),
      hosts: () async => const [],
    );
    addTearDown(ctrl.dispose);
    late UuRemoteState latest;
    ctrl.addListener((next) => latest = next);
    UuRemoteState s() => latest;
    await ctrl.retryLoad();
    await until(() => s().loaded);
    await ctrl.refreshApp();
    report('app', s().app.runtimeType);
    final app = s().app;
    expect(app, isA<UuSignerNeedsApproval>(), reason: '假 UU 不是官方证书，应先要用户批准');
    await ctrl.approveSigner((app! as UuSignerNeedsApproval).signer);
    final id = await ctrl.createEntry('x11');

    Future<String> noticeAfter(Future<void> Function() trigger) async {
      ctrl.clearNotice();
      await trigger();
      await until(() => s().notice != null,
          timeout: const Duration(seconds: 20));
      return s().notice!;
    }

    // 1. 没有任何请求时，别的 App 发来一条「绑定成功」：忽略，不出确认框。
    report(
        'forge.noPending', await noticeAfter(() => action('forge-nopending')));
    expect(s().offer, isNull);
    expect(s().bindings, isEmpty);
    // 格式不对、超长、带路径穿越的：同样忽略。
    report(
        'forge.malformed', await noticeAfter(() => action('forge-malformed')));
    expect(s().offer, isNull);

    // 2. 同一条回调发两次：第一次对上、只给确认（不自动挂上），第二次是重放。
    await action('mode-bind_twice');
    ctrl.clearNotice();
    await ctrl.startBind(id);
    await until(() => s().offer != null, timeout: const Duration(seconds: 30));
    final offer = s().offer!;
    report('twice.offer', 'host=${offer.hostId == id}');
    await until(() => s().notice != null, timeout: const Duration(seconds: 20));
    report('twice.second', s().notice);
    expect(s().offer, same(offer));
    expect(s().bindings, isEmpty, reason: '回调之后不自动绑定，要用户确认');

    // 3. state 对、nonce 不对：请求作废、记失败，不给确认。
    await action('mode-bind_wrong_nonce');
    await ctrl.startBind(id);
    await until(() => s().pending == null && s().attempts[id]?.code != null,
        timeout: const Duration(seconds: 30));
    report('wrongNonce.attempt',
        '${s().attempts[id]!.phase.name} ${s().attempts[id]!.code}');
    expect(s().offer, isNull);

    // 4. 别的 App 抢注 shun-uuremote://callback：说出它的包名，不再发绑定请求。
    await action('install-hijack');
    await ctrl.refreshApp();
    report('hijack.rivals', s().callbackRivals);
    expect(s().callbackRivals, contains('example.shun.fixture.fakeuu'));
    await expectLater(ctrl.startBind(id), throwsA(isA<UuRequestRefused>()));
    report('hijack.pending', s().pending);
    expect(s().pending, isNull);
    await action('uninstall-hijack');
    await ctrl.refreshApp();
    expect(s().callbackRivals, isEmpty);
    report('done', 'ok');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
