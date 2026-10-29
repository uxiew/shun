// X11 设备对抗回归：插件信任、更新、换签、撤销、冒充调用。由 tool/x11-device.py 编排，别直接跑。
//
// 用真的 Kotlin 插件桥、真的测试插件 APK（plugins/out/）和真的 Mosh 插件。测试打出「X11 ACTION <名字>」，
// 脚本照名字装/换/卸包或让 rogue 去打插件，做完在本 App 私有目录放 x11-ack-<名字>，测试看到才往下走。
// 「X11 key=value」是证据行。echo 只是测试插件：这里过了只证明宿主侧的信任机制，不证明任何真实 provider 可用。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:plugin_api/plugin_api.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/application/plugin_discovery.dart';
import 'package:shun/application/plugin_registry.dart';
import 'package:shun/application/plugin_sessions.dart';
import 'package:shun/domain/plugins/builtin_plugins.dart';
import 'package:shun/domain/plugins/official_plugins.dart';
import 'package:shun/infrastructure/plugins/android_plugin_bridge.dart';
import 'package:shun/infrastructure/plugins/plugin_approval_store.dart';

const echo = 'example.shun.fixture.echo';
const debugkey = 'example.shun.fixture.echo.debugkey';
const fakemosh = 'example.shun.fixture.fakemosh';
const rogue = 'example.shun.fixture.rogue';
const mosh = 'top.xdwa.shun.mosh';

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

  testWidgets('X11 信任与撤销对抗', (tester) async {
    final files = await getApplicationSupportDirectory();
    final resets = <DateTime>[];

    /// [packageChange]：这个操作会装/卸包。等宿主把包变化处理完（断开旧连接的通知发完、
    /// 1.5 秒内没有新的）再往下走。更新一次系统发 added、replaced 两条广播，宿主各断开一次；
    /// 不等的话，刚建的连接会被后到的那条断掉，测试看到的是自己的竞态。
    Future<void> action(String name, {bool packageChange = true}) async {
      final ack = File('${files.path}/x11-ack-$name');
      if (ack.existsSync()) ack.deleteSync();
      final before = resets.length;
      debugPrint('X11 ACTION $name');
      await until(ack.existsSync, timeout: const Duration(minutes: 2));
      if (!packageChange) return;
      await until(() => resets.length > before,
          timeout: const Duration(seconds: 60));
      await until(
          () =>
              DateTime.now().difference(resets.last) >
              const Duration(milliseconds: 1500),
          timeout: const Duration(seconds: 60));
      report('$name.resets', resets.length - before);
    }

    final bridge = AndroidPluginBridge();
    final events = <PluginBridgeEvent>[];
    bridge.events.listen(events.add);
    final registry = PluginRegistry(
      policy: AdmissionPolicy(
        builtinIds: BuiltinPlugins.ids,
        reservedOfficialIds: OfficialPlugins.reserved,
        allowDebugSigners: kDebugMode,
      ),
    );
    final prefs = await SharedPreferences.getInstance();
    final store = PluginApprovalStore(prefs);
    final discovery = PluginDiscovery(bridge, store, registry);
    discovery.connectionResets.listen((_) => resets.add(DateTime.now()));
    final manager = PluginSessionManager(bridge, registry);
    await discovery.start();

    PluginEntry? entryOf(String package) =>
        registry.entries.where((e) => e.packageName == package).firstOrNull;
    PluginEntry entry(String package) => entryOf(package)!;
    void state(String tag, String package) {
      final e = entryOf(package);
      report('$tag.$package', '${e?.status.name} | ${e?.reason}');
    }

    Future<PluginTerminalSession> active(String package) async {
      // 包一变宿主就断开旧连接，要先重新握手；连着的话 check 只 ping、沿用。
      expect((await discovery.check(entry(package))).ok, isTrue);
      final s = await manager.open(entry(package));
      if (s.phase != SessionPhase.active) {
        await s.phases
            .firstWhere((p) => p == SessionPhase.active)
            .timeout(const Duration(seconds: 10));
      }
      return s;
    }

    Future<void> roundTrip(PluginTerminalSession s, String text) async {
      final got = BytesBuilder();
      final sub = s.output.listen(got.add);
      await s.write(Uint8List.fromList(utf8.encode(text)));
      await until(() => got.length >= text.length,
          timeout: const Duration(seconds: 5));
      await sub.cancel();
      expect(utf8.decode(got.takeBytes()), text);
    }

    Future<void> statusBecomes(String package, PluginStatus status) =>
        until(() => entryOf(package)?.status == status,
            timeout: const Duration(seconds: 60));

    // ── 1. 发现（PLG03、PLG04、PLG15 debug 部分）──
    for (final p in [echo, debugkey, fakemosh, rogue, mosh]) {
      state('found', p);
    }
    report('found.packages', registry.installedPackages.toList()..sort());
    expect(entry(echo).status, PluginStatus.needsApproval);
    expect(entry(debugkey).status, PluginStatus.needsApproval);
    expect(entry(debugkey).androidDebugSigned, isTrue);
    expect(entry(fakemosh).status, PluginStatus.rejected);
    expect(entry(rogue).status, PluginStatus.rejected);
    expect(entry(mosh).status, PluginStatus.needsApproval);
    for (final p in ['com.android.chrome', 'example.not.installed', echo]) {
      report('inspect.$p', await discovery.inspect(p));
    }
    // 未批准的不绑定：连接测试在宿主这边就停下。
    for (final p in [echo, fakemosh, rogue]) {
      final check = await discovery.check(entry(p));
      report('checkBeforeApproval.$p', check.message);
      expect(check.ok, isFalse);
    }

    // ── 2. 批准后可用；批准记录里有权限（X11 修复）──
    for (final p in [echo, debugkey, mosh]) {
      await discovery.approve(entry(p));
      expect(entry(p).status, PluginStatus.ready, reason: entry(p).reason);
      final check = await discovery.check(entry(p));
      report('check.$p', check.message);
      expect(check.ok, isTrue);
    }
    report('approvals', prefs.getString('shun.plugins.approvals.v1'));

    // ── 3. PLG05：rogue 用求来的同一个 Binder 逐个调 echo 和 Mosh 插件的方法（宿主此刻连着它们）──
    final beforeProbe = await active(echo);
    await action('probe-echo', packageChange: false);
    await action('probe-mosh', packageChange: false);
    await roundTrip(beforeProbe, 'after-rogue\n');
    report('probe.echoSessionAfter', beforeProbe.phase);
    await beforeProbe.close();

    // ── 4. PLG05 宿主侧：echo-leaky 握手后把宿主回调 Binder 转给 rogue，rogue 拿它调宿主 ──
    await action('install-leaky');
    await statusBecomes(echo, PluginStatus.ready);
    events.clear();
    final leakyCheck = await discovery.check(entry(echo));
    report('leaky.check', leakyCheck.message);
    await until(() => events.where((e) => e.type == 'rejectedCall').length >= 2,
        timeout: const Duration(seconds: 20));
    for (final e in events.where((e) => e.type == 'rejectedCall')) {
      report('leaky.rejected', '${e.packageName} ${e.detail}');
    }
    // echo 自己握手后会发一条合法的 ready；rogue 发的叫 rogue-was-here，不该进来。
    for (final e in events.where((e) => e.type == 'providerEvent')) {
      report('leaky.providerEvent', e.detail);
    }
    expect(events.where((e) => e.detail.contains('rogue-was-here')), isEmpty);
    final leakySession = await active(echo);
    await roundTrip(leakySession, 'leaky-still-own\n');
    await leakySession.close();
    await action('install-author');
    await statusBecomes(echo, PluginStatus.ready);

    // ── 5. PLG11/PLG12：会话开着时插件更新、换签。另一个插件的会话全程开着 ──
    final other = await active(debugkey);
    // 会话输出是单订阅流：只听一次，每次核对新写的那段回来了没有。
    final otherOut = BytesBuilder(copy: false);
    other.output.listen(otherOut.add);
    Future<void> otherStillFine(String tag) async {
      expect(other.phase, SessionPhase.active, reason: tag);
      final start = otherOut.length;
      final text = '$tag\n';
      await other.write(Uint8List.fromList(utf8.encode(text)));
      await until(() => otherOut.length >= start + text.length,
          timeout: const Duration(seconds: 5));
      expect(utf8.decode(otherOut.toBytes().sublist(start)), text);
    }

    Future<void> updateWhileOpen(
      String name,
      PluginStatus expected, {
      String? reasonHas,
    }) async {
      final s = await active(echo);
      await action(name);
      await statusBecomes(echo, expected);
      await until(() => s.phase.isTerminal,
          timeout: const Duration(seconds: 10));
      state(name, echo);
      report('$name.session', s.phase);
      if (reasonHas != null) expect(entry(echo).reason, contains(reasonHas));
      if (expected != PluginStatus.ready) {
        expect(registry.readyEntry(entry(echo).pluginId!), isNull);
        await expectLater(
            manager.open(entry(echo)), throwsA(isA<PluginUnavailable>()));
        final check = await discovery.check(entry(echo));
        report('$name.check', check.message);
        expect(check.ok, isFalse);
      }
      await otherStillFine(name);
    }

    // 只多一条权限、版本号不变：X11 修之前会一直可用。
    await updateWhileOpen('install-moreperms', PluginStatus.needsApproval,
        reasonHas: '权限');
    report('moreperms.approvals', prefs.getString('shun.plugins.approvals.v1'));
    // 待批准时开不了会话：直接换回 author，旧批准（只有输入输出）覆盖它，应直接可用。
    await action('install-author');
    await statusBecomes(echo, PluginStatus.ready);
    state('back-to-author', echo);
    await updateWhileOpen('install-morecaps', PluginStatus.needsApproval,
        reasonHas: '能力');
    await action('install-apimajor2');
    await statusBecomes(echo, PluginStatus.incompatible);
    state('install-apimajor2', echo);
    await action('downgrade-author');
    await statusBecomes(echo, PluginStatus.ready);
    state('downgrade-author', echo);
    await updateWhileOpen('swap-impostor', PluginStatus.rejected,
        reasonHas: '换签');
    final kept = store.load().where((a) => a.packageName == echo).single;
    report('impostor.approvalCert', kept.signingDigest);
    expect(entry(echo).signerDigests.contains(kept.signingDigest), isFalse);
    await action('swap-author');
    await statusBecomes(echo, PluginStatus.ready);
    state('swap-author', echo);
    final back = await active(echo);
    await roundTrip(back, 'author-again\n');
    await back.close();

    // ── 6. 撤销与卸载：只断自己的会话、不级联（PLG12、DEV02 的插件侧）──
    final revoked = await active(echo);
    await discovery.revoke(entry(echo));
    await until(() => revoked.phase.isTerminal);
    report('revoke.session', revoked.phase);
    state('revoke', echo);
    expect(entry(echo).status, PluginStatus.needsApproval);
    await otherStillFine('after-revoke');
    await action('uninstall-echo');
    await statusBecomes(echo, PluginStatus.missing);
    state('uninstall', echo);
    expect(entry(debugkey).status, PluginStatus.ready);
    expect(store.load().any((a) => a.packageName == debugkey), isTrue);
    await otherStillFine('after-uninstall');
    await other.close();
    report('other.stopConfirmed', other.stopConfirmed);
    report('done', 'ok');
  }, timeout: const Timeout(Duration(minutes: 20)));
}
