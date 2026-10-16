import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/widgets/host_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('host editor keeps full sheet height when keyboard is visible',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(viewInsets: EdgeInsets.only(bottom: 300)),
            child: HostEditor(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.getSize(find.byType(Scaffold)).height, greaterThan(800));
    expect(find.byType(ListView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('advanced timeout descriptions use complete responsive rows',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(home: HostEditor()),
      ),
    );
    await tester.pump();

    // R41：超时与保活是高级里默认收起的一组。
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('advanced-timeouts')),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('advanced-timeouts')));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('认证超时'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    expect(find.text('Keepalive 间隔'), findsOneWidget);
    expect(find.text('连接超时'), findsOneWidget);
    expect(find.text('认证超时'), findsOneWidget);
    expect(find.text('每隔多少秒发送一次保活消息'), findsOneWidget);
    expect(find.text('建立 TCP 连接的最长等待时间'), findsOneWidget);
    expect(find.text('SSH 身份认证的最长等待时间'), findsOneWidget);
    expect(
      tester.getCenter(find.text('Keepalive 间隔')).dy,
      lessThan(tester.getCenter(find.text('连接超时')).dy),
    );
    expect(
      tester.getCenter(find.text('连接超时')).dy,
      lessThan(tester.getCenter(find.text('认证超时')).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('existing host exposes delete action with callback',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    var deleted = false;
    final host = HostProfile.create(
      id: 'host-1',
      label: 'Example',
      hostname: 'example.com',
      username: 'root',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          home: HostEditor(
            host: host,
            onDelete: () async {
              deleted = true;
              return false;
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('delete-host-from-editor')),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('delete-host-from-editor')));
    await tester.pump();

    expect(deleted, isTrue);
  });

  testWidgets('successful host deletion closes the editor sheet',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    final host = HostProfile.create(
      id: 'host-1',
      label: 'Example',
      hostname: 'example.com',
      username: 'root',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => HostEditor(
                    host: host,
                    onDelete: () async => true,
                  ),
                ),
                child: const Text('Edit'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('delete-host-from-editor')),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    // scrollUntilVisible 最后的 ensureVisible 只改了滚动位置，不 pump 就点的是旧坐标，
    // 会点到底部操作栏上。
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('delete-host-from-editor')));
    await tester.pumpAndSettle();

    expect(find.byType(HostEditor), findsNothing);
    expect(find.text('Edit'), findsOneWidget);
  });
}
