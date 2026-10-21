// R24 / UX12 设备验证：真 App 页面、真安全存储、真 SSH（测试环境的 ssh-edge / dante / target）。
// 三条路线各走一遍：主机 ⋮ 菜单里的「文件」进文件页 → 点超过 1 MB 的文件（不打开，问要不要下载）→
// 打开小文件，服务器上被改过以后保存（先弹「服务器上的文件变了」）→ 驱动脚本杀掉最后一跳的 sshd 会话，
// 看文件页怎么说、旧一代的文件服务是不是报「已断开」。上传下载、取消要走系统文件选择器，不在这里
// （服务层在 integration_ssh_fixture_test 的 R24 组，界面在 r24_borrowers_test）。
//
// 不是 CI 测试，只用 tool/r24-device.py 跑：它只认项目专用模拟器，负责转端口、传测试环境凭据、
// 按下面的标记截图和杀会话，跑完清掉 App 数据。输出以 "R24 " 开头的行是证据：
//   R24 SHOT <名字>      驱动脚本截一张屏
//   R24 KILL <容器> <n>  驱动脚本杀掉那个容器里的 sshd 会话，杀完在 App 私有目录放 r24-killed-<n>
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shun/app.dart';
import 'package:shun/application/home_navigation.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/sftp_service.dart';
import 'package:shun/infrastructure/ssh/ssh_lease.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/widgets/sftp_editor.dart';

const _raw = String.fromEnvironment('R24_SSH');
final Map<String, dynamic> config =
    _raw.isEmpty ? const {} : jsonDecode(_raw) as Map<String, dynamic>;

void report(String key, Object? value) => debugPrint('R24 $key=$value');

/// 真实时钟下一帧一帧地等：终端光标在闪，pumpAndSettle 等不到「静止」。
Future<void> waitFor(WidgetTester tester, bool Function() condition,
    {Duration timeout = const Duration(seconds: 30),
    String what = '条件'}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待$what超时');
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> settle(WidgetTester tester, [int ms = 600]) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;
  final skip = config.isEmpty ? '没给 R24_SSH，用 tool/r24-device.py 跑' : false;

  testWidgets('R24 文件入口：Direct / SOCKS / Jump 下浏览、预览上限、保存核对、断线与换代',
      (tester) async {
    final repository = await VaultRepository.open();
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const ShunApp(),
    ));
    await settle(tester, 1500);

    final vault = container.read(vaultControllerProvider.notifier);
    final controller = container.read(sessionControllerProvider.notifier);
    final private = (await getApplicationSupportDirectory()).path;
    Finder key(String value) => find.byKey(ValueKey(value));
    final leftPane = key('sftp-left-pane');
    String texts(Finder within) => tester
        .widgetList<Text>(find.descendant(
            of: within, matching: find.byType(Text), matchRoot: true))
        .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
        .where((t) => t.isNotEmpty)
        .join(' | ');
    Future<void> shot(String name) async {
      await settle(tester, 800);
      debugPrint('R24 SHOT $name');
      await settle(tester, 1200);
    }

    Future<void> clearSnackBars() async {
      for (final m in tester
          .stateList<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))) {
        m.clearSnackBars();
      }
      await settle(tester, 300);
    }

    final fingerprints = {
      '127.0.0.1': config['edgeFingerprint'],
      config['targetName']: config['targetFingerprint'],
    };
    Future<bool> verify(HostProfile host, String _, String fingerprint) async =>
        fingerprint == fingerprints[host.hostname];

    HostProfile login(Map<String, Object?> data) => HostProfile({
          'username': config['user'],
          'password': config['password'],
          'authMethod': 'password',
          'protocol': 'ssh',
          ...data,
        });
    final direct = login({
      'id': 'r24-direct',
      'label': 'R24 直连',
      'hostname': '127.0.0.1',
      'port': config['edgePort'],
    });
    final socks = login({
      'id': 'r24-socks',
      'label': 'R24 SOCKS',
      'hostname': config['targetName'],
      'port': config['targetPort'],
      'proxyConfig': {
        'type': 'socks5',
        'host': '127.0.0.1',
        'port': config['socksPort'],
        'username': config['socksUser'],
        'password': config['socksPassword'],
      },
    });
    final jump = login({
      'id': 'r24-jump',
      'label': 'R24 跳板',
      'hostname': config['targetName'],
      'port': config['targetPort'],
      'hostChain': {
        'hostIds': ['r24-direct'],
      },
    });
    for (final host in [direct, socks, jump]) {
      await vault.upsertHost(host);
    }
    await settle(tester, 800);

    var kills = 0;
    Future<void> kill(String service) async {
      final done = File('$private/r24-killed-${++kills}');
      if (done.existsSync()) done.deleteSync();
      debugPrint('R24 KILL $service $kills');
      await waitFor(tester, done.existsSync, what: '驱动脚本杀会话');
    }

    Future<void> route(String name, HostProfile host, String lastHop) async {
      const dir = '/tmp/r24-dev';
      expect(await controller.connect(host, verify), isTrue, reason: name);
      final old = controller.state.sessions.single;
      await waitFor(tester, () => old.terminal.allText().contains(r'$'),
          what: '$name 远端提示符');
      Future<String> remote(String command) =>
          old.sshClient!.run(command).then((out) => utf8.decode(out).trim());
      await remote('rm -rf $dir && mkdir -p $dir && '
          'head -c ${previewLimit + 1} /dev/zero > $dir/big.bin && '
          'printf original > $dir/keep.txt && hostname');
      report('$name.hostname', await remote('hostname'));

      // 从主机 ⋮ 菜单进文件页：左栏就是这个标签的 SSH，不另开连接。
      container.read(homeTabProvider.notifier).state = 0;
      await settle(tester, 1000);
      final menu = key('vault-host-menu-${host.id}');
      await Scrollable.ensureVisible(tester.element(menu), alignment: 0.5);
      await settle(tester, 300);
      await tester.tap(menu);
      await waitFor(tester, () => key('host-menu-files').evaluate().isNotEmpty,
          what: '⋮ 菜单');
      await settle(tester);
      await tester.tap(key('host-menu-files'));
      await waitFor(tester, () => container.read(homeTabProvider) == 2,
          what: '切到文件页');
      await waitFor(
          tester, () => container.read(sftpNavigationRequestProvider) == null,
          what: '文件页接住请求');
      await settle(tester, 1500);
      expect(texts(leftPane), contains(host.label));
      expect(controller.state.sessions, hasLength(1), reason: '没有另开连接');
      // 跳到测试目录（和系统管理里「打开配置文件」同一个入口）
      container.read(sftpNavigationRequestProvider.notifier).state =
          SftpNavigationRequest(sessionId: old.id, filePath: '$dir/keep.txt');
      final big = find.descendant(of: leftPane, matching: find.text('big.bin'));
      await waitFor(tester, () => big.evaluate().isNotEmpty,
          what: '$name 列出测试目录');
      await settle(tester);
      report('$name.pane', texts(leftPane).split(' | ').take(10).join(' | '));
      await shot('$name-01-browse');

      // 超过上限：不打开，问要不要下载
      await tester.tap(big);
      await waitFor(
          tester, () => find.text('文件太大，不在这里打开').evaluate().isNotEmpty,
          what: '$name 超限提示');
      expect(find.byType(SftpEditor), findsNothing);
      report('$name.tooLarge', texts(find.byType(AlertDialog)));
      await shot('$name-02-too-large');
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await settle(tester);

      // 打开小文件；服务器上被改过以后保存，先问
      await tester
          .tap(find.descendant(of: leftPane, matching: find.text('keep.txt')));
      await waitFor(tester, () => find.byType(SftpEditor).evaluate().isNotEmpty,
          what: '$name 编辑器');
      await settle(tester);
      final field = key('sftp-editor-field');
      expect(tester.widget<TextField>(field).controller!.text, 'original');
      // 改成不同长度：同一秒里改完、大小又恰好一样时，只看大小和改时间是看不出来的（见证据）
      await remote('printf changed-on-server > $dir/keep.txt');
      await tester.enterText(field, 'from-phone');
      await settle(tester);
      await tester.tap(find.widgetWithText(TextButton, '保存'));
      await waitFor(tester, () => find.text('服务器上的文件变了').evaluate().isNotEmpty,
          what: '$name 保存前核对');
      report('$name.saveCheck', await remote('cat $dir/keep.txt'));
      await shot('$name-03-changed-on-server');
      await tester.tap(find.widgetWithText(FilledButton, '仍然保存'));
      await waitFor(tester, () => find.text('服务器上的文件变了').evaluate().isEmpty,
          what: '关掉确认框');
      await waitFor(tester, () => find.text('保存中…').evaluate().isEmpty,
          what: '$name 保存完');
      await settle(tester);
      final saved = await remote('cat $dir/keep.txt');
      report('$name.saved', saved);
      expect(saved, 'from-phone');
      await tester.tap(find
          .descendant(
              of: find.byType(SftpEditor), matching: find.byIcon(Icons.close))
          .first);
      await waitFor(tester, () => find.byType(SftpEditor).evaluate().isEmpty,
          what: '关编辑器');
      await clearSnackBars();

      // 杀掉最后一跳的 sshd 会话：文件页说清楚，旧一代的文件服务报「已断开」，标签自己恢复成新连接
      final oldFiles = SftpService(old);
      await kill(lastHop);
      final notice = find.descendant(
          of: find.byType(SnackBar),
          matching: find.textContaining(RegExp('换成了新连接|SSH 连接断开了')));
      await waitFor(tester, () => notice.evaluate().isNotEmpty,
          timeout: const Duration(seconds: 40), what: '$name 文件页断线提示');
      report('$name.notice', texts(notice.first));
      await shot('$name-04-dropped');
      await expectLater(oldFiles.list(dir), throwsA(isA<ConnectionGone>()));
      report('$name.oldGeneration', 'ConnectionGone');
      await waitFor(tester, () {
        final now = controller.state.sessions.single;
        return !identical(now, old) && now.connected;
      }, timeout: const Duration(seconds: 60), what: '$name 标签自动恢复');
      await expectLater(oldFiles.list(dir), throwsA(isA<ConnectionGone>()),
          reason: '恢复以后旧一代也不接到新连接上');
      final fresh = controller.state.sessions.single;
      report('$name.recovered', fresh.connected);
      await fresh.sshClient!.run('rm -rf $dir');
      await clearSnackBars();
      await controller.close(0);
      await settle(tester, 1000);
    }

    await route('direct', direct, 'ssh-edge');
    await route('socks', socks, 'target');
    await route('jump', jump, 'target');
  }, skip: skip != false, timeout: const Timeout(Duration(minutes: 8)));
}
