// R67 / TSC11 设备验证：真 App 页面、真前后台切换、真实时钟、真 HTTP。Tailscale API 是本机假服务器
// tool/tailscale-fixture/serve.dart：证明的是 App 什么时候发请求、怎么显示，不证明真 Tailscale 怎么回。
//
// 不是 CI 测试，只用 tool/r67-device.py 跑（它只认项目专用模拟器），全程约 10 分钟：每一步都要真等 60 秒的间隔。
// 输出以 "R67 " 开头的行是证据，驱动脚本照着做，做完在 App 私有目录放 r67-ack-<号>：
//   R67 SHOT <名字>         截一张屏
//   R67 MARK <名字>         记下现在假 API 收到多少次读设备的请求
//   R67 SERVE <场景> <号>   换假 API 的回答：online / offline / 429 / 401 / down / up
//   R67 HOME <号>            按 HOME，停 75 秒，再把 App 叫回来
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shun/app.dart';
import 'package:shun/application/catalog_overview.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/tailscale_catalog_access.dart';
import 'package:shun/application/tailscale_catalog_provider.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/infrastructure/tailscale/catalog_cache.dart';
import 'package:shun/infrastructure/tailscale/catalog_secret_store.dart';
import 'package:shun/infrastructure/tailscale/tailscale_api.dart';

const source = 'ts-r67';
const noKey = 'ts-r67-nokey';

void mark(String line) => debugPrint('R67 $line');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'R67 在线状态：前台自己变，后台不发请求，失败不弹框不连着试',
    timeout: const Timeout(Duration(minutes: 25)),
    (tester) async {
      final repository = await VaultRepository.open();
      final client = http.Client();
      addTearDown(client.close);
      final container = ProviderContainer(overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
        tailscaleCatalogAccessProvider.overrideWithValue(TailscaleCatalogAccess(
          const TailscaleCatalogSecretStore(FlutterSecureCatalogBackend()),
          // ignore: invalid_use_of_visible_for_testing_member
          (credential) => TailscaleCatalogClient.fixture(
            client,
            Uri.parse('http://127.0.0.1:18480'),
            credential,
          ),
        )),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const ShunApp(),
      ));

      Future<void> frames(int milliseconds) async {
        final end = DateTime.now().add(Duration(milliseconds: milliseconds));
        while (DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      Future<Duration> waitFor(
        bool Function() condition,
        String what, {
        Duration timeout = const Duration(seconds: 80),
      }) async {
        final start = DateTime.now();
        while (!condition()) {
          if (DateTime.now().difference(start) > timeout) fail('等待$what超时');
          await tester.pump(const Duration(milliseconds: 100));
        }
        return DateTime.now().difference(start);
      }

      Future<void> shot(String name) async {
        await frames(600);
        mark('SHOT $name');
        await frames(1200);
      }

      final support = await getApplicationSupportDirectory();
      var ackId = 0;

      /// 等驱动脚本做完。期间不 pump：App 在后台时没有帧，pump 会卡住。
      Future<void> ack(int id, Duration timeout) async {
        final file = File('${support.path}/r67-ack-$id');
        final end = DateTime.now().add(timeout);
        while (!file.existsSync()) {
          if (DateTime.now().isAfter(end)) fail('驱动脚本没回 $id');
          await binding.delayed(const Duration(milliseconds: 200));
        }
      }

      Future<void> serve(String scenario) async {
        final id = ++ackId;
        mark('SERVE $scenario $id');
        await ack(id, const Duration(seconds: 15));
      }

      CatalogRefresh? attempt() => container
          .read(catalogOverviewProvider)
          .firstWhere((view) => view.catalogId == source)
          .cache
          .lastAttempt;

      final row =
          find.byKey(const ValueKey('vault-catalog-device-$source-2001'));
      bool rowSays(String text) => find
          .descendant(of: row, matching: find.textContaining(text))
          .evaluate()
          .isNotEmpty;

      bool quiet() =>
          find.byType(AlertDialog).evaluate().isEmpty &&
          find.byType(SnackBar).evaluate().isEmpty;

      /// 等自动读撞上这个失败，再等整整一个间隔：不弹框，也不再读。
      Future<void> failsQuietly(String name) async {
        final before = attempt()!.at;
        final elapsed = await waitFor(
          () => attempt()!.at != before && !attempt()!.ok,
          '自动读撞上 $name',
        );
        final hit = attempt()!.at;
        mark('report $name.hitAfter=${elapsed.inSeconds}s');
        mark('MARK $name-hit');
        await frames(70 * 1000);
        mark('MARK $name-wait');
        mark('report $name.quiet=${quiet()} '
            'noMoreAttempts=${attempt()!.at == hit}');
        expect(quiet(), isTrue, reason: '$name 不弹框');
        expect(attempt()!.at, hit, reason: '$name 之后不连着试');
        await shot('$name-quiet');
      }

      /// 手动刷新照旧能用，也把上一次失败的退避清掉，下一步才测得到。
      Future<void> recoverByHand(String name) async {
        await serve('online');
        final overview = container.read(catalogOverviewProvider.notifier);
        final outcome = await overview.refresh(source);
        mark('report $name.manualRefresh=${outcome?.error ?? 'ok'}');
        expect(outcome?.error, isNull, reason: '手动刷新照旧');
        await frames(500);
      }

      await frames(1500);
      final catalog = container.read(tailscaleCatalogProvider);
      await catalog.addSource(catalogId: source, label: 'Home');
      final read = await catalog.refreshWithOAuthClient(
        source,
        const OAuthClientCredential(
          clientId: 'r67-client',
          clientSecret: 'r67-not-a-secret',
        ),
        persist: true,
      );
      expect(read.error, isNull);
      // 没存 key 的来源：只有这一次手动读，驱动脚本最后核对它再没发过请求。
      await catalog.addSource(catalogId: noKey, label: 'NoKey');
      expect(
          (await catalog.refreshWithToken(noKey, 'r67-token')).error, isNull);

      // 存了 key 回到「连接」页才开始自动读：真实流程是从设置页存完回来。
      container.read(homeTabProvider.notifier).state = 4;
      await frames(800);
      container.read(homeTabProvider.notifier).state = 0;
      await waitFor(() => row.evaluate().isNotEmpty, '设备行');
      expect(rowSays('在线'), isTrue);
      await shot('01-online');

      // ── F32 本体：设备掉线后，什么都不点，列表自己变 ──
      await serve('offline');
      mark('MARK offline-start');
      final changed = await waitFor(() => rowSays('离线'), '自己变成离线');
      mark('report offline.changedAfter=${changed.inSeconds}s');
      expect(changed.inSeconds, lessThanOrEqualTo(70));
      await shot('02-offline-by-itself');

      // ── 后台一条请求都没有，回前台马上读 ──
      final id = ++ackId;
      mark('MARK bg-start');
      mark('HOME $id');
      await ack(id, const Duration(seconds: 120));
      final beforeResume = attempt()!.at;
      mark('MARK bg-end');
      await frames(500);
      final resumed = await waitFor(
        () => attempt()!.at != beforeResume,
        '回前台后读一次',
        timeout: const Duration(seconds: 20),
      );
      mark('report resume.readAfter=${resumed.inSeconds}s');
      await shot('03-back-in-foreground');

      // ── 三种失败：不弹框、不连着试、手动刷新照旧 ──
      await serve('429');
      await failsQuietly('429');
      await recoverByHand('429');

      await serve('401');
      await failsQuietly('401');
      await recoverByHand('401');

      await serve('down');
      await failsQuietly('down');
      await serve('up');
      await recoverByHand('down');

      mark('DONE');
      await tester.pumpWidget(const SizedBox());
    },
  );
}
