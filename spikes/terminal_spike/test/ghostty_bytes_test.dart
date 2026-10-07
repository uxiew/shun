import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flterm/flterm.dart';
import 'package:flutter/widgets.dart' hide Key;
import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_spike/guarded_writer.dart';

// 与主工程共用同一份 VT 素材，一件事只放一处。
import '../../../test/fixtures/vt/vt_samples.dart';

// 本机（macOS arm64）加载 fork 从源码编的 Ghostty 原生库直接跑 VT 内核。
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

    // 模拟器（API 35）截图：e+U+0301 显示成裸 e，重音不见了。这里确认终端模型本身没丢，
    // 丢的是绘制——排查从 flterm 的字形绘制/字体回退入手，不是 VT 解析。
    test('组合字符：模型里 e+U+0301 保留（屏幕上缺重音是绘制问题）', () {
      final result = feed([Uint8List.fromList(utf8.encode('é|'))]);
      expect(result.plain, contains('é|'));
    });

    // 真机上按退格，回环页回显的 0x7f 显示成一个方格。VT100 收到 DEL 应当忽略（xterm 也是），
    // Ghostty 却把它当可打印字符存进格子（0.0.12 和上游 main 的 349f0260 都是）。远端程序真输出 0x7f 时也会出方格。
    // R20 起 fork 的 libghostty 在写入前去掉裸 DEL（Terminal.write 的 _withoutDel），这条改成固定修好后的样子；
    // 同步上游后这条挂了，说明补丁丢了，去看 third_party/README.md 的差异表。
    test('裸 DEL（0x7f）被忽略，和 VT100、xterm 一样（fork 的补丁）', () {
      final result = feed([
        Uint8List.fromList([0x61, 0x7f, 0x62]),
      ]);
      expect(result.plain, 'ab');
    });

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

    // R04 问题 1：flterm 0.0.5 这里直接段错误、整个进程崩掉（证据见 plan/v3/evidence/R04.md）。
    // 上游 main 改成抛 StateError，能接住了，但 SSH 迟到的数据照样会抛，所以仍要 GuardedWriter 挡住。
    test('dispose 后 write 抛 StateError，不再段错误', () {
      final controller = TerminalController()..dispose();
      expect(
        () => controller.write(Uint8List.fromList([0x41])),
        throwsStateError,
      );
    });
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
