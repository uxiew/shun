import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/app.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/domain/models/vault.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'support/home_navigation.dart';

// R25 「字体可用」：系统字体调大（Android 「字体大小」最大是 1.3 倍，无障碍里的放大可到 2 倍）、竖屏横屏，
// 把保险库（网格里一台带分组的主机）、选类型、编辑主机、终端空页、设置、连接记录走一遍，布局溢出（黄黑条）一处都不许有。
// 终端里的字本来就不跟系统字体变（使用手册第 8 节），不在这里。

const _sizes = {
  '竖屏': Size(412, 892),
  '横屏': Size(892, 412),
};

void main() {
  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'shun',
      packageName: 'top.xdwa.shun',
      version: '1.4.7',
      buildNumber: '26',
      buildSignature: '',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, null);
  });

  for (final scale in [1.3, 2.0]) {
    for (final MapEntry(key: orientation, value: size) in _sizes.entries) {
      testWidgets('系统字体 $scale 倍、$orientation：主要页面没有布局溢出', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

        final overflows = <String>[];
        var where = '启动';
        Object? navigation;
        final previous = FlutterError.onError;
        FlutterError.onError = (details) {
          final message = details.exceptionAsString();
          if (message.contains('overflowed')) {
            // 报错里「The relevant error-causing widget was」后面带着出错组件在 lib 里的位置。
            final source = RegExp(r'package:shun/[^\s:]+\.dart:\d+')
                    .firstMatch(details.toString())
                    ?.group(0) ??
                '';
            overflows.add('$where: ${message.split('\n').first} $source');
            return;
          }
          previous?.call(details);
        };
        try {
          final repository = await VaultRepository.open();
          // 保险库里要有主机：网格卡片的高度是写死的，空保险库撞不到（模拟器上 2 倍字体时超出 13 px）。
          await repository.saveVault(VaultData.fromJson({
            'hosts': [
              HostProfile.create(
                id: 'big-text',
                label: 'production-database-primary',
                hostname: 'db-primary.internal.example.com',
                username: 'deploy',
              ).toJson()
                ..['group'] = 'production',
            ],
          }));
          await tester.pumpWidget(ProviderScope(
            overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
            child: const ShunApp(),
          ));
          await tester.pump(const Duration(seconds: 1));

          // 选类型页、编辑页里有转圈（查插件、查保险库），pumpAndSettle 等不到停。
          Future<void> settle() async {
            for (var i = 0; i < 4; i++) {
              await tester.pump(const Duration(milliseconds: 250));
            }
          }

          // 竖着滚的列表（不算输入框里横着滚的那种），取离 [child] 最近的一层。先认准元素：滚远了
          // [child] 会被懒加载列表回收，再按它找就找不到了。
          Finder listAround(Finder child) {
            final element = find
                .ancestor(
                  of: child,
                  matching: find.byWidgetPredicate((widget) =>
                      widget is Scrollable &&
                      widget.axisDirection == AxisDirection.down),
                )
                .evaluate()
                .first;
            return find.byElementPredicate((candidate) => candidate == element);
          }

          // 半屏半屏往下翻到底，每一段都真的排版一次，再回到顶上。
          Future<void> scrollThrough(Finder list) async {
            final position = tester.state<ScrollableState>(list).position;
            for (var i = 0;
                i < 60 && position.pixels < position.maxScrollExtent;
                i++) {
              position.jumpTo(math.min(
                position.pixels + size.height / 2,
                position.maxScrollExtent,
              ));
              await tester.pump(const Duration(milliseconds: 100));
            }
            position.jumpTo(0);
            await tester.pump(const Duration(milliseconds: 100));
          }

          where = '连接页';
          await tester.pump(const Duration(milliseconds: 300));

          where = '新建连接';
          await tester.tap(find.byTooltip('添加连接'));
          await settle();
          final type = find.byKey(const ValueKey('host-protocol'));
          final form = listAround(type);
          await scrollThrough(form);

          where = '选择连接类型';
          await tester.ensureVisible(type);
          await settle();
          await tester.tap(find.byKey(const ValueKey('host-type-more')));
          await settle();
          final tailscale =
              find.byKey(const ValueKey('connection-type-Tailscale'));
          await scrollThrough(listAround(tailscale));
          await tester.binding.handlePopRoute();
          await settle();

          where = '编辑主机';
          final advanced = find.byKey(const ValueKey('advanced-all'));
          await tester.scrollUntilVisible(advanced, 200, scrollable: form);
          await settle();
          await tester.tap(advanced);
          await settle();
          await scrollThrough(form);
          await tester.binding.handlePopRoute();
          await settle();

          where = '终端（没有会话）';
          await tester.tap(homeNavigationEntry(1));
          await tester.pump(const Duration(milliseconds: 500));

          where = '设置';
          await tester.tap(homeNavigationEntry(4));
          await tester.pump(const Duration(milliseconds: 500));
          final settingsList = listAround(find.text('通用'));
          await scrollThrough(settingsList);

          where = '连接记录';
          await tester.scrollUntilVisible(
            find.byKey(const ValueKey('settings-app-log')),
            200,
            scrollable: settingsList,
          );
          // scrollUntilVisible 只管建出来，可能还在屏幕外的缓冲区里。
          await tester
              .ensureVisible(find.byKey(const ValueKey('settings-app-log')));
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.byKey(const ValueKey('settings-app-log')));
          await settle();
          await tester.binding.handlePopRoute();
          await settle();
        } catch (error) {
          // 走到一半找不到按钮时，先把已经撞到的溢出报出来，别让导航失败把它们盖掉。
          navigation = StateError('在「$where」：$error');
        } finally {
          FlutterError.onError = previous;
        }
        expect(overflows, isEmpty, reason: overflows.toSet().join('\n'));
        if (navigation != null) throw navigation;
        expect(tester.takeException(), isNull);
      });
    }
  }
}
