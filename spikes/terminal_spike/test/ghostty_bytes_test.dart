import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flterm/flterm.dart';
import 'package:flutter/widgets.dart' hide Key;
import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_spike/guarded_writer.dart';

// 与主工程共用同一份 VT 素材，一件事只放一处。
import '../../../test/fixtures/vt/vt_samples.dart';

// 本机（macOS arm64）加载 libghostty-v0.0.12 的原生库直接跑 VT 内核。
// 这证明的是"引擎行为"，不是 Android 真机证据。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ({String plain, String vt, List<List<int>> replies}) feed(
    Iterable<Uint8List> chunks,
  ) {
    final replies = <List<int>>[];
    final controller = TerminalController()
      ..onOutput = (bytes) => replies.add(List.of(bytes));
    for (final chunk in chunks) {
      controller.write(chunk);
    }
    final plain = controller.createFormatter(format: FormatterFormat.plain);
    final vt = controller.createFormatter(format: FormatterFormat.vt);
    final result = (plain: plain.format(), vt: vt.format(), replies: replies);
    plain.dispose();
    vt.dispose();
    controller.dispose();
    return result;
  }

  final samples = {
    'CJK+ANSI': VtSamples.cjkAndAnsi,
    'emoji+组合字符': VtSamples.emojiAndCombining,
    '全屏+DA 查询': VtSamples.fullScreen,
    '全部拼接': VtSamples.all,
    '非法 UTF-8': VtSamples.invalidUtf8,
  };

  group('TER01（Ghostty 路径）：原始字节不经 String，切包位置不影响终端状态', () {
    for (final entry in samples.entries) {
      test(entry.key, () {
        final whole = feed([entry.value]);
        for (final seed in List.generate(20, (i) => i)) {
          final chunked = feed(randomChunks(entry.value, seed));
          expect(chunked.plain, whole.plain, reason: 'seed=$seed');
          expect(chunked.vt, whole.vt, reason: 'seed=$seed');
          expect(chunked.replies, whole.replies, reason: 'seed=$seed');
        }
        final bytewise = feed(byteChunks(entry.value));
        expect(bytewise.plain, whole.plain);
        expect(bytewise.vt, whole.vt);
      });
    }

    test('前提：素材里的中文确实被渲染，DA 查询确实只回应一次', () {
      final result = feed([VtSamples.all]);
      expect(result.plain, contains('回到主屏'));
      expect(result.plain, contains('中文输出测试'));
      expect(result.replies, hasLength(1));
      expect(result.replies.single.take(2), [0x1b, 0x5b]);
    });
  });

  group('GST03：回调内不重入 write，回应保序', () {
    test('onOutput 里再写入会排队，嵌套深度始终为 1', () {
      final controller = TerminalController();
      addTearDown(controller.dispose);
      final writer = GuardedWriter(controller.write);
      final order = <String>[];
      controller.onOutput = (bytes) {
        order.add('reply');
        // 模拟最坏的调用方：在回调里立刻再写。GuardedWriter 必须挡住直接重入。
        writer.write(Uint8List.fromList(utf8.encode('[after-reply]')));
      };
      writer.write(Uint8List.fromList(utf8.encode('before\x1b[cafter')));
      order.add('returned');

      expect(writer.maxDepth, 1);
      expect(order, ['reply', 'returned']);
      final text = controller.createFormatter(format: FormatterFormat.plain);
      addTearDown(text.dispose);
      expect(
        text.format(),
        contains('beforeafter[after-reply]'),
        reason: '排队的数据在当前写入完成后按顺序补写',
      );
    });

    test('关闭后迟到的写入被丢弃，不会碰到已释放的原生对象', () {
      final controller = TerminalController();
      final writer = GuardedWriter(controller.write)
        ..write(Uint8List.fromList([0x41]))
        ..close();
      controller.dispose();
      writer.write(Uint8List.fromList([0x42])); // 模拟 SSH 迟到的数据
      expect(writer.droppedAfterClose, 1);
    });

    test(
      '已知问题：flterm 0.0.5 在 dispose 后 write 会让进程段错误',
      () {
        final controller = TerminalController()..dispose();
        controller.write(Uint8List.fromList([0x41]));
      },
      // 跑这条会直接打崩测试进程（TestDeviceException: segmentation fault），
      // 默认跳过；XWSHUN_RUN_KNOWN_FAILS=1 时单独运行以复现，证据见 plan/v3/evidence/R04.md。
      skip: Platform.environment['XWSHUN_RUN_KNOWN_FAILS'] == '1'
          ? false
          : '会让测试进程段错误；XWSHUN_RUN_KNOWN_FAILS=1 可复现',
    );
  });

  testWidgets('GST03：快速 resize 穿插终端查询，回应保序不丢不重；关闭后不再发送', (tester) async {
    final controller = TerminalController();
    final writer = GuardedWriter(controller.write);
    final events = <String>[];
    var sendAllowed = true;
    controller.onResize = (cols, rows) => events.add('resize $cols x $rows');
    controller.onOutput = (bytes) {
      expect(sendAllowed, isTrue, reason: '关闭后仍有字节要发往远端');
      events.add('reply');
    };

    Future<void> show(double width, double height) => tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: width,
            height: height,
            child: TerminalView(controller: controller, showKeyboard: false),
          ),
        ),
      ),
    );

    const sizes = [
      (800.0, 600.0),
      (400.0, 300.0),
      (640.0, 200.0),
      (320.0, 480.0),
    ];
    var queries = 0;
    for (final (w, h) in sizes) {
      await show(w, h);
      writer.write(Uint8List.fromList('\x1b[c'.codeUnits));
      queries++;
    }
    await tester.pump();

    final replies = events.where((e) => e == 'reply').length;
    final resizes = events.where((e) => e.startsWith('resize')).toList();
    expect(replies, queries, reason: '每个查询恰好一次回应');
    expect(writer.maxDepth, 1);
    expect(
      resizes.toSet().length,
      greaterThanOrEqualTo(sizes.length),
      reason: '每个不同尺寸都通知了后端',
    );

    // 关闭顺序：先关写入口，再移除视图，再 dispose。之后迟到的数据不得触发发送。
    writer.close();
    sendAllowed = false;
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    writer.write(Uint8List.fromList('\x1b[c'.codeUnits));
    expect(writer.droppedAfterClose, 1);
  });

  test('资源基线（本机，仅作方法冻结；不是 Android 数据）', () {
    // 5 MiB 合成输出：中文、颜色、换行混合。
    final unit = utf8.encode(
      '\x1b[32m中文行\x1b[0m plain ascii line 0123456789\r\n',
    );
    final total = 5 * 1024 * 1024;
    final big = Uint8List(total);
    for (var i = 0; i < total; i++) {
      big[i] = unit[i % unit.length];
    }
    final rssBefore = ProcessInfo.currentRss;
    final watch = Stopwatch()..start();
    final controller = TerminalController();
    for (var offset = 0; offset < total; offset += 16384) {
      controller.write(
        Uint8List.sublistView(
          big,
          offset,
          offset + 16384 > total ? total : offset + 16384,
        ),
      );
    }
    final feedMs = watch.elapsedMilliseconds;
    final rssAfterFeed = ProcessInfo.currentRss;
    controller.dispose();

    watch.reset();
    for (var i = 0; i < 100; i++) {
      TerminalController()
        ..write(VtSamples.all)
        ..dispose();
    }
    final cyclesMs = watch.elapsedMilliseconds;
    final rssAfterCycles = ProcessInfo.currentRss;

    final metrics = {
      'host':
          '${Platform.operatingSystem} ${Platform.version.split(' ').first}',
      'feed5MiBMs': feedMs,
      'rssDeltaAfterFeedMiB': (rssAfterFeed - rssBefore) / 1048576,
      'createDispose100Ms': cyclesMs,
      'rssDeltaAfterCyclesMiB': (rssAfterCycles - rssBefore) / 1048576,
    };
    // ignore: avoid_print
    print('SPIKE_METRICS ${jsonEncode(metrics)}');
    expect(feedMs, greaterThan(0));
  });
}
