// X08：Dart 候选 dart_mosh 0.0.4 对真实 mosh-server 1.4.0（Alpine 打包）的互操作与安全探测。
// 跑法见 ../README.md。每条都在本机真连容器里的 mosh-server，不是 mock。
import 'dart:typed_data';

import 'package:dart_mosh/dart_mosh.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosh_dart_probe/dart_path.dart';
import 'package:mosh_dart_probe/fixture.dart';
import 'package:mosh_dart_probe/udp_relay.dart';

void main() {
  final fixture = MoshFixture.tryLoad();
  final skip = fixture == null ? '没起 ../up.sh' : null;

  tearDown(() async => fixture?.killAllServers());

  group('VT 重绘：dart_mosh 画出的屏幕 = 官方 mosh-client 画出的屏幕', () {
    // 程序最后都 sleep 住，保证 mosh 路径上程序还活着、屏幕是程序画的最终样子。
    final programs = <String, String>{
      '大量滚动': 'seq 1 3000; sleep 60',
      '中文宽字符与组合字符':
          r'printf "中文宽字符 混排 abc\n组合 e\314\201 x\n表情 \360\237\231\202 y\n"; sleep 60',
      '光标定位与清屏':
          r'printf "\033[2J\033[5;10Hmid\033[1;1Htop\033[24;70Hbottom\033[12;1H"; sleep 60',
      '备用屏与滚动区':
          r'printf "\033[?1049h\033[H\033[2J"; seq 1 10; printf "\033[3;20r\033[20;1H"; seq 100 140; printf "\033[r\033[1;60Hcorner"; sleep 60',
      '颜色与折行':
          r'printf "\033[31mred\033[0m \033[1;44mbold-blue\033[0m\n"; printf "%0150d\n" 0; sleep 60',
    };
    for (final MapEntry(key: name, value: program) in programs.entries) {
      test(name, () async {
        final official = await fixture!.officialClientScreen(program);
        await fixture.killAllServers();
        final run = await DartMoshRun.start(fixture, program);
        final got = await run.settle();
        await run.close();
        expect(got, official);
      }, skip: skip);
    }

    test('大屏多分片：200x60 满屏彩色字符', () async {
      // 一帧远超 1200 字节的 MTU，要拆成多个分片再拼回来。
      const program =
          r'i=0; while [ $i -lt 60 ]; do printf "\033[3%dm%0199d\033[0m\n" $((i % 8)) $i; i=$((i+1)); done; sleep 60';
      final official = await fixture!.officialClientScreen(
        program,
        cols: 200,
        rows: 60,
        settleSeconds: 4,
      );
      await fixture.killAllServers();
      final run = await DartMoshRun.start(
        fixture,
        program,
        cols: 200,
        rows: 60,
      );
      final got = await run.settle(quiet: const Duration(seconds: 2));
      await run.close();
      expect(got, official);
      expect(got, contains('0' * 150));
    }, skip: skip);

    test('改尺寸后再输出', () async {
      const program =
          r'sleep 2; stty size; seq 1 50; printf "\033[1;1H%s" "$(stty size)"; sleep 60';
      final reference = await fixture!.officialClientScreen(
        program,
        cols: 100,
        rows: 30,
        settleSeconds: 5,
      );
      await fixture.killAllServers();
      final run = await DartMoshRun.start(fixture, program);
      // 客户端改尺寸：本地屏幕和远端一起改（宿主会这样做）。
      run.screen.resize(100, 30);
      run.session.resize(100, 30);
      final got = await run.settle(quiet: const Duration(seconds: 2));
      await run.close();
      expect(got, reference);
    }, skip: skip);

    test('vim 交互：开文件、移动、删行、退出', () async {
      final run = await DartMoshRun.start(fixture!, 'sh');
      run.type(
        'printf "a1\\nb2\\nc3\\nd4\\n" > /tmp/x08.txt; vim -u NONE -N /tmp/x08.txt\r',
      );
      var screen = await run.settle();
      expect(screen, contains('a1'));
      run.type('jdd');
      screen = await run.settle();
      expect(screen.split('\n').take(3).toList(), ['a1', 'c3', 'd4']);
      run.type(':wq\r');
      run.type('cat /tmp/x08.txt\r');
      screen = await run.settle();
      await run.close();
      expect(screen, contains('a1\nc3\nd4'));
    }, skip: skip);
  });

  group('网络故障（经本机 UDP 中继）', () {
    test('丢 30%、每包发两次、4 个一组倒序：最终屏幕仍对', () async {
      const program = 'seq 1 3000; sleep 60';
      final reference = await fixture!.officialClientScreen(program);
      await fixture.killAllServers();
      final run = await DartMoshRun.start(fixture, program, viaRelay: true);
      var n = 0;
      final relay = run.relay!;
      relay.drop = (_, _) => (n++ % 10) < 3;
      relay.copies = 2;
      relay.reorderWindow = 4;
      // 屏幕一开始是空的、也「不变」，不能用安静判断；等到和对照一致或超时。
      final sw = Stopwatch()..start();
      await waitFor(
        () => run.screen.text() == reference,
        timeout: const Duration(seconds: 40),
      );
      // ignore: avoid_print
      print(
        'X08 dart_mosh 丢包/重复/乱序下 ${sw.elapsedMilliseconds} ms 收敛，丢了 ${relay.dropped} 个包',
      );
      final got = await run.settle(quiet: const Duration(seconds: 2));
      await run.close();
      expect(got, reference);
      expect(run.relay!.dropped, greaterThan(0));
    }, skip: skip);

    test('篡改服务器发来的包：认证失败的包被丢掉，会话照常', () async {
      final run = await DartMoshRun.start(fixture!, 'sh', viaRelay: true);
      var n = 0;
      run.relay!.mutate = (toServer, p) {
        if (toServer || n++ % 3 != 0) return null;
        final copy = Uint8List.fromList(p);
        copy[copy.length - 20] ^= 0x01;
        return copy;
      };
      run.type('echo corrupt-ok-\$((6*7))\r');
      final ok = await run.settle(
        quiet: const Duration(seconds: 2),
        timeout: const Duration(seconds: 30),
      );
      await run.close();
      expect(ok, contains('corrupt-ok-42'));
      expect(
        run.errors.whereType<MoshException>().where(
          (e) => e.message.contains('authentication'),
        ),
        isNotEmpty,
      );
    }, skip: skip);

    test('重放服务器的旧包：屏幕不变、不重复输出', () async {
      final run = await DartMoshRun.start(fixture!, 'sh', viaRelay: true);
      run.type('echo replay-\$((6*7))\r');
      final before = await run.settle();
      expect(before, contains('replay-42'));
      for (final p in List.of(run.relay!.serverToClient)) {
        run.relay!.injectToClient(p);
      }
      final after = await run.settle();
      await run.close();
      expect(after, before);
    }, skip: skip);

    for (final reflect in [false, true]) {
      test(
        reflect ? '缺陷复现：把客户端自己发出的包反射回去，之后的输入全丢' : '对照：同样断开输入方向再恢复、不反射，输入照常送达',
        () async {
          // mosh 的 nonce 最高位是方向位，官方客户端只收 TO_CLIENT 方向的包（network.cc 的 dos_assert）。
          // 反射回来的包用同一把 key 加密，认证必然通过；只有方向位能挡住它。
          final run = await DartMoshRun.start(fixture!, 'sh', viaRelay: true);
          run.type('echo warm-\$((6*7))\r');
          expect(await run.settle(), contains('warm-42'));
          // 断开客户端到服务器的方向，打几个字：它们在客户端的待确认队列里。
          run.relay!.drop = (toServer, _) => toServer;
          run.type('echo lost-');
          await Future<void>.delayed(const Duration(milliseconds: 600));
          if (reflect) {
            // 攻击者把客户端早先发出的包反射回去（ackNum 是客户端已收到的服务器状态号，远大于服务器确认过的输入号）。
            for (final p in List.of(run.relay!.clientToServer)) {
              run.relay!.injectToClient(p);
            }
          }
          await Future<void>.delayed(const Duration(milliseconds: 300));
          run.relay!.drop = null;
          run.type('\$((6*7))\r');
          final screen = await run.settle(
            quiet: const Duration(seconds: 3),
            timeout: const Duration(seconds: 20),
          );
          await run.close();
          if (!reflect) {
            expect(screen, contains('lost-42'));
          } else {
            // 官方客户端会丢掉反射包（方向位不对），「echo lost-42」照常送达。dart_mosh 0.0.4 不查方向位：
            // 反射包里的 ackNum（客户端收到的服务器状态号）被当成服务器对输入的确认，待发的按键被当成已送达删掉，
            // 之后输入的状态号和服务器对不上，后面打的字也都送不到。哪天这条挂了，说明上游修了，重新评估。
            expect(screen, isNot(contains('lost-42')), reason: screen);
            expect(
              screen,
              isNot(contains('echo lost-')),
              reason: '服务器连「echo lost-」都没收到：$screen',
            );
          }
        },
        skip: skip,
      );
    }
  });

  group('生命周期', () {
    test('远端程序退出：done 完成；mosh-server 随后退出', () async {
      final run = await DartMoshRun.start(fixture!, 'echo bye; sleep 1');
      await run.session.done.timeout(const Duration(seconds: 20));
      await run.close();
      // mosh-server 在发出关闭后要等客户端确认；dart_mosh 收到关闭就停发，不回确认。
      final start = DateTime.now();
      var left = await fixture.serverProcessCount();
      while (left > 0 &&
          DateTime.now().difference(start) < const Duration(seconds: 30)) {
        await Future<void>.delayed(const Duration(seconds: 1));
        left = await fixture.serverProcessCount();
      }
      // ignore: avoid_print
      print(
        'X08 远端退出后 mosh-server 残留进程 $left 个，等了 ${DateTime.now().difference(start).inSeconds} 秒',
      );
      expect(left, 0);
    }, skip: skip);

    test('客户端主动关闭：dart_mosh 不通知服务器，mosh-server 和 shell 留在远端', () async {
      final run = await DartMoshRun.start(fixture!, 'sh');
      run.type('echo hi\r');
      await run.settle();
      await run.close();
      await Future<void>.delayed(const Duration(seconds: 5));
      final left = await fixture.serverProcessCount();
      // ignore: avoid_print
      print('X08 客户端 close() 5 秒后 mosh-server 进程 $left 个');
      expect(left, greaterThan(0), reason: '记录事实：close() 只关本地套接字');
    }, skip: skip);
  });

  group('key 与 bootstrap 解析（dart_mosh 自带的）', () {
    test('解析失败的异常带着整段 bootstrap 输出；解析结果保留原文', () {
      const out = 'junk\nMOSH CONNECT 60101 AAAAAAAAAAAAAAAAAAAAAA\n';
      final config = MoshServerConfig.parse(out, host: 'h');
      expect(config.rawOutput, contains('AAAAAAAAAAAAAAAAAAAAAA'));
      try {
        MoshServerConfig.parse(
          'MOSH CONNECT 60101 shortkey-but-secret',
          host: 'h',
        );
        fail('应当解析失败');
      } on MoshException catch (e) {
        expect('$e', contains('shortkey-but-secret'));
      }
    });

    test('端口 0 和多行时取第一条', () {
      expect(
        () => MoshServerConfig.parse(
          'MOSH CONNECT 0 AAAAAAAAAAAAAAAAAAAAAA',
          host: 'h',
        ),
        throwsA(isA<MoshException>()),
      );
      final c = MoshServerConfig.parse(
        'MOSH CONNECT 60101 AAAAAAAAAAAAAAAAAAAAAA\nMOSH CONNECT 60102 BBBBBBBBBBBBBBBBBBBBBA',
        host: 'h',
      );
      expect(c.port, 60101);
    });
  });

  test('连着时大量输出：seq 1 200000 到最终屏幕', () async {
    // 先等 3 秒再输出，保证输出发生在客户端连上之后（否则 mosh 只送一帧最终画面）。
    final run = await DartMoshRun.start(
      fixture!,
      'sleep 3; seq 1 200000; sleep 60',
    );
    await waitFor(() => run.screen.bytes > 0);
    final sw = Stopwatch()..start();
    final ok = await waitFor(
      () => run.screen.lines()[22] == '200000',
      timeout: const Duration(seconds: 60),
    );
    await run.close();
    // ignore: avoid_print
    print(
      'X08 dart_mosh 连着时 seq 200000：${sw.elapsedMilliseconds} ms 到最终画面，收到 ${run.screen.bytes} 字节（mosh 跳帧，不是逐行）',
    );
    expect(ok, isTrue);
  }, skip: skip);
}
