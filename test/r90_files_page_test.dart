// R90 文件页本体（sftp_screen.dart、sftp_screen_pane.dart）迁到 Prism 后的回归：
// 稳定 key 和读屏节点不退化，长文件名不撑破一栏，两栏各管各的、剪贴板共用，
// 确认框按 key 能点、取消不动文件，传输取消后进度条消失、目标位置没有写进东西。
// 只用内存里的文件来源，不连网；真 SFTP 在 integration_ssh_fixture_test 的 R24 组。
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shun/infrastructure/ssh/sftp_service.dart';
import 'package:shun/infrastructure/storage/vault_repository.dart';
import 'package:shun/presentation/screens/sftp_screen.dart';
import 'package:shun/presentation/widgets/empty_state.dart';

import 'support/prism_test_host.dart';

const _longStem =
    'a-very-long-file-name-that-does-not-fit-in-one-pane-2026-11-20';
const _longName = '$_longStem.tar.gz';
const _longPlain = 'a-very-long-file-name-without-any-extension-at-all-2026';
const _longDirectory = 'a-very-long-directory-name-with-dots-in-it.v1.2.3';

Finder _in(String pane, Finder matching) =>
    find.descendant(of: find.byKey(ValueKey(pane)), matching: matching);

Finder _entry(String pane, String path) =>
    _in(pane, find.byKey(ValueKey('sftp-entry-$path')));

Future<void> _open(WidgetTester tester, _Phone phone,
    {Size size = const Size(412, 892)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final repository = await VaultRepository.open();
  await tester.pumpWidget(ProviderScope(
    overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
    child: MaterialApp(
      localizationsDelegates: prismTestDelegates,
      builder: prismTestBuilder,
      home: Scaffold(body: SftpScreen(localService: Future.value(phone))),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('窄屏大字：两栏空目录可以切成一栏，页头动作仍可点', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _open(tester, _Phone(), size: const Size(320, 640));
    final toggle = find.byKey(const ValueKey('sftp-pane-mode-toggle'));
    expect(find.byType(EmptyState), findsNWidgets(2));
    expect(toggle.hitTestable(), findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text('shun 文件夹为空'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('原有 key 都在；文件行、来源、多选、粘贴各有稳定 key', (tester) async {
    final phone = _Phone()
      ..put('/a.txt', 2)
      ..directories.add('/docs');
    await _open(tester, phone);
    for (final key in [
      'sftp-title-bar',
      'sftp-pane-mode-toggle',
      'sftp-left-pane',
      'sftp-right-pane',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }
    expect(find.byKey(const ValueKey('sftp-source')), findsNWidgets(2));
    expect(_entry('sftp-left-pane', '/a.txt'), findsOneWidget);
    expect(_entry('sftp-right-pane', '/docs'), findsOneWidget);

    await tester.longPress(_entry('sftp-left-pane', '/a.txt'));
    await tester.pumpAndSettle();
    expect(_in('sftp-left-pane', find.byKey(const ValueKey('sftp-select-all'))),
        findsOneWidget);
    expect(
        _in('sftp-right-pane', find.byKey(const ValueKey('sftp-select-all'))),
        findsNothing,
        reason: '多选只在长按的那一栏');
    await tester.tap(_in('sftp-left-pane', find.byTooltip('复制')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sftp-paste')), findsNWidgets(2),
        reason: '剪贴板两栏共用');
  });

  testWidgets('读屏：文件行是一个按钮节点，勾选框和 ⋮ 是它下面独立的节点', (tester) async {
    final handle = tester.ensureSemantics();
    final phone = _Phone()..put('/a.txt', 2);
    await _open(tester, phone);
    await tester.tap(find.byKey(const ValueKey('sftp-pane-mode-toggle')));
    await tester.pumpAndSettle();

    final row = _entry('sftp-left-pane', '/a.txt');
    expect(
      tester.getSemantics(row),
      matchesSemantics(
        label: 'a.txt, 2 B',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasSelectedState: true,
        hasTapAction: true,
        hasLongPressAction: true,
        hasFocusAction: true,
        children: [
          matchesSemantics(
            tooltip: '文件操作',
            isButton: true,
            hasEnabledState: true,
            isEnabled: true,
            isFocusable: true,
            hasExpandedState: true,
            hasTapAction: true,
            hasFocusAction: true,
          ),
        ],
      ),
    );
    expect(find.bySemanticsLabel('SFTP文件管理'), findsOneWidget);
    expect(
        tester
            .getSemantics(find.text('SFTP文件管理'))
            .getSemanticsData()
            .flagsCollection
            .isHeader,
        isTrue);

    // 读屏的长按进多选：这一行报「已选中」，下面多出一个勾上的勾选框。
    tester.semantics.longPress(find.semantics.byLabel('a.txt, 2 B'));
    await tester.pumpAndSettle();
    final data = tester.getSemantics(row).getSemanticsData();
    expect(data.flagsCollection.isSelected, Tristate.isTrue);
    final box = tester.widget<Checkbox>(find.byType(Checkbox));
    expect(box.value, isTrue);
    expect(
      tester.getSemantics(find.byType(Checkbox)),
      matchesSemantics(
        hasCheckedState: true,
        isChecked: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );

    // 点勾选框取消这一项：还在多选里，数量回到 0。
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
    expect(
        tester.getSemantics(row).getSemanticsData().flagsCollection.isSelected,
        Tristate.isFalse);
    expect(find.text('全选 (0)'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('长文件名：双栏、单栏都压成一行，扩展名一直露着，不溢出，读屏念全名，⋮ 还点得到', (tester) async {
    final handle = tester.ensureSemantics();
    final phone = _Phone()
      ..put('/$_longName', 5)
      ..put('/$_longPlain', 5)
      ..directories.add('/$_longDirectory')
      ..put('/s.txt', 5);
    await _open(tester, phone);
    for (final pane in ['sftp-left-pane', 'sftp-right-pane']) {
      final paneBox = tester.getRect(find.byKey(ValueKey(pane)));
      final row = tester.getRect(_entry(pane, '/$_longName'));
      expect(row.left, greaterThanOrEqualTo(paneBox.left));
      expect(row.right, lessThanOrEqualTo(paneBox.right));
      expect(row.height, tester.getRect(_entry(pane, '/s.txt')).height,
          reason: '和短名字的行一样高：一行，没有折行');
      // 放不下：省略的是中间，`.tar.gz` 整个露在 ⋮ 左边。
      final extension = find.descendant(
          of: _entry(pane, '/$_longName'), matching: find.text('.tar.gz'));
      expect(extension, findsOneWidget, reason: '扩展名没被省略掉');
      final stem = find.descendant(
          of: _entry(pane, '/$_longName'), matching: find.text(_longStem));
      expect(stem, findsOneWidget);
      expect(tester.widget<Text>(stem).overflow, TextOverflow.ellipsis);
      final menu = tester.getRect(find.descendant(
          of: _entry(pane, '/$_longName'), matching: find.byTooltip('文件操作')));
      final shown = tester.getRect(extension);
      expect(tester.getRect(stem).right, lessThanOrEqualTo(shown.left));
      expect(shown.width, tester.getSize(extension).width);
      expect(shown.width, greaterThan(0));
      expect(shown.right, lessThanOrEqualTo(menu.left), reason: '名字不压到 ⋮ 上');
      expect(menu.right, lessThanOrEqualTo(paneBox.right));
      // 放得下的名字还是一个 Text，按名字找它的测试和设备脚本不受影响。
      expect(_in(pane, find.text('s.txt')), findsOneWidget);
      // 没有扩展名的、目录：照旧末尾省略，不拆。
      expect(_in(pane, find.text(_longPlain)), findsOneWidget);
      expect(_in(pane, find.text(_longDirectory)), findsOneWidget);
      expect(_in(pane, find.text('.3')), findsNothing);
    }
    expect(find.bySemanticsLabel(_longName), findsNWidgets(2));
    expect(tester.takeException(), isNull);

    await tester.tap(find.descendant(
        of: _entry('sftp-right-pane', '/$_longName'),
        matching: find.byTooltip('文件操作')));
    await tester.pumpAndSettle();
    expect(find.text('重命名'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('sftp-pane-mode-toggle')));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('$_longName, 5 B'), findsOneWidget);
    expect(tester.getRect(_entry('sftp-left-pane', '/$_longName')).height,
        tester.getRect(_entry('sftp-left-pane', '/s.txt')).height);
    expect(_in('sftp-left-pane', find.text('.tar.gz')), findsOneWidget,
        reason: '单栏 412dp 也放不下这个名字，扩展名同样露着');
    expect(tester.takeException(), isNull);
    handle.dispose();
  });

  testWidgets('长文件名放得下时不拆：宽屏单栏是完整的一个名字', (tester) async {
    final phone = _Phone()..put('/$_longName', 5);
    await _open(tester, phone, size: const Size(1600, 892));
    await tester.tap(find.byKey(const ValueKey('sftp-pane-mode-toggle')));
    await tester.pumpAndSettle();
    expect(_in('sftp-left-pane', find.text(_longName)), findsOneWidget);
    expect(_in('sftp-left-pane', find.text('.tar.gz')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('两栏各管各的目录和多选，删除只动确认的那一个文件', (tester) async {
    final phone = _Phone()
      ..directories.add('/docs')
      ..put('/docs/inner.txt', 1)
      ..put('/a.txt', 2)
      ..put('/b.txt', 3);
    await _open(tester, phone);

    await tester.tap(_entry('sftp-left-pane', '/docs'));
    await tester.pumpAndSettle();
    expect(_entry('sftp-left-pane', '/docs/inner.txt'), findsOneWidget);
    expect(_entry('sftp-right-pane', '/docs/inner.txt'), findsNothing,
        reason: '右栏还在根目录');
    expect(_entry('sftp-right-pane', '/a.txt'), findsOneWidget);

    // 右栏删 a.txt：先点取消，文件还在；再确认，只少这一个。
    Future<void> askDelete() async {
      await tester.tap(find.descendant(
          of: _entry('sftp-right-pane', '/a.txt'),
          matching: find.byTooltip('文件操作')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('删除 a.txt？'), findsOneWidget);
    }

    await askDelete();
    await tester.tap(find.byKey(const ValueKey('sftp-dialog-cancel')));
    await tester.pumpAndSettle();
    expect(phone.files.keys, containsAll(['/a.txt', '/b.txt']));
    await askDelete();
    await tester.tap(find.byKey(const ValueKey('sftp-dialog-confirm')));
    await tester.pumpAndSettle();
    expect(phone.files.containsKey('/a.txt'), isFalse);
    expect(phone.files.keys, containsAll(['/b.txt', '/docs/inner.txt']));
    expect(_entry('sftp-left-pane', '/docs/inner.txt'), findsOneWidget,
        reason: '左栏没被带回根目录');
  });

  testWidgets('新建目录：输入框和按钮按 key 操作，取消不建', (tester) async {
    final phone = _Phone();
    await _open(tester, phone);
    await tester.tap(_in('sftp-left-pane', find.byTooltip('新建')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('sftp-dialog-input')), 'skip');
    await tester.tap(find.byKey(const ValueKey('sftp-dialog-cancel')));
    await tester.pumpAndSettle();
    expect(phone.directories, {'/'});

    await tester.tap(_in('sftp-left-pane', find.byTooltip('新建')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('sftp-dialog-input')), ' made ');
    await tester.tap(find.byKey(const ValueKey('sftp-dialog-confirm')));
    await tester.pumpAndSettle();
    expect(phone.directories, contains('/made'));
    expect(_entry('sftp-left-pane', '/made'), findsOneWidget);
  });

  testWidgets('传输进行中能取消：进度条消失，目标位置没有写进东西，之后来的数据也不写', (tester) async {
    final phone = _Phone()
      ..directories.add('/target')
      ..put('/big.bin', 4);
    final feed = phone.holdRead('/big.bin');
    await _open(tester, phone);

    await tester.longPress(_entry('sftp-left-pane', '/big.bin'));
    await tester.pumpAndSettle();
    await tester.tap(_in('sftp-left-pane', find.byTooltip('复制')));
    await tester.pumpAndSettle();
    await tester.tap(_entry('sftp-right-pane', '/target'));
    await tester.pumpAndSettle();
    await tester
        .tap(_in('sftp-right-pane', find.byKey(const ValueKey('sftp-paste'))));
    // 先弹「续传还是重新传」之类的询问时这里会停住：内存来源没有半截文件，不该问。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    feed.add(Uint8List(2));
    await tester.pump(const Duration(milliseconds: 300));

    final cancel = find.byKey(const ValueKey('sftp-transfer-cancel'));
    expect(cancel, findsOneWidget, reason: '传输中标题栏下有进度和取消');
    final toggle = find.byKey(const ValueKey('sftp-pane-mode-toggle'));
    bool canSwitch() => tester
        .getSemantics(toggle)
        .getSemanticsData()
        .hasAction(SemanticsAction.tap);
    expect(canSwitch(), isFalse, reason: '传输中不让切单/双栏');
    expect(phone.writing, isNotEmpty);

    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(cancel, findsNothing);
    expect(find.textContaining('已取消'), findsOneWidget);
    expect(canSwitch(), isTrue);
    expect(
        phone.files.keys.where((path) => path.startsWith('/target/')), isEmpty,
        reason: '取消的那一项没有放到目标位置');

    // 取消以后源那头再来数据，也不会被写进去。
    if (!feed.isClosed) feed.add(Uint8List(2));
    await tester.pumpAndSettle();
    expect(
        phone.files.keys.where((path) => path.startsWith('/target/')), isEmpty);
    expect(phone.files['/big.bin']!.length, 4, reason: '源文件没动');
    unawaited(feed.close());
  });
}

/// 内存里的手机目录（已挂载）。[holdRead] 让某个文件读到一半停住，等测试自己喂数据。
class _Phone extends FileTransferService
    implements MountableFileTransferService {
  _Phone() {
    directories.add('/');
  }

  final files = <String, Uint8List>{};
  final directories = <String>{};
  final _held = <String, StreamController<Uint8List>>{};

  /// 正在写、还没写完的目标路径。
  final writing = <String>{};

  void put(String path, int size) => files[path] = Uint8List(size);

  StreamController<Uint8List> holdRead(String path) =>
      _held[path] = StreamController<Uint8List>();

  @override
  String get id => 'local';
  @override
  String get displayName => 'phone';
  @override
  String get rootPath => '/';
  @override
  bool get isLocal => true;
  @override
  bool get isMounted => true;
  @override
  String? get mountedDirectoryName => 'phone';
  @override
  bool get usesAppDocuments => true;
  @override
  Future<bool> mount() async => true;
  @override
  String displayPath(String path) => path;
  @override
  String joinPath(String path, String name) =>
      path == '/' ? '/$name' : '$path/$name';
  @override
  String parentPath(String path) {
    final at = path.lastIndexOf('/');
    return at <= 0 ? '/' : path.substring(0, at);
  }

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final prefix = path == '/' ? '/' : '$path/';
    bool child(String candidate) =>
        candidate != path &&
        candidate.startsWith(prefix) &&
        !candidate.substring(prefix.length).contains('/');
    return [
      for (final directory in directories.where(child))
        RemoteEntry(
          name: directory.substring(prefix.length),
          path: directory,
          isDirectory: true,
          size: 0,
        ),
      for (final file in files.entries.where((e) => child(e.key)))
        RemoteEntry(
          name: file.key.substring(prefix.length),
          path: file.key,
          isDirectory: false,
          size: file.value.length,
        ),
    ];
  }

  @override
  Stream<Uint8List> readStream(
    String path, {
    int startOffset = 0,
    TransferProgressCallback? onProgress,
  }) {
    final stream =
        _held[path]?.stream ?? Stream.value(files[path]!.sublist(startOffset));
    return onProgress == null
        ? stream
        : trackTransferProgress(stream, onProgress);
  }

  @override
  Future<void> writeStream(
    String path,
    Stream<Uint8List> stream, {
    int startOffset = 0,
    bool truncate = true,
    TransferProgressCallback? onProgress,
  }) async {
    final builder = BytesBuilder(copy: false);
    writing.add(path);
    await for (final chunk in stream) {
      builder.add(chunk);
      onProgress?.call(builder.length);
    }
    files[path] = builder.takeBytes();
  }

  @override
  Future<int?> fileSize(String path) async => files[path]?.length;
  @override
  Future<void> mkdir(String path) async => directories.add(path);
  @override
  Future<void> ensureDirectory(String path) async => directories.add(path);
  @override
  Future<void> rename(String from, String to) async {
    final file = files.remove(from);
    if (file != null) files[to] = file;
  }

  @override
  Future<void> delete(RemoteEntry entry) async {
    files.remove(entry.path);
    directories.remove(entry.path);
  }
}
