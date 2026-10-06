import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mosh/dart_mosh.dart';

import 'fixture.dart';
import 'screen.dart';
import 'udp_relay.dart';

/// 一条 dart_mosh 会话：bootstrap → UDP（可选经中继）→ 屏幕。
class DartMoshRun {
  DartMoshRun._(this.session, this.screen, this.relay, this.errors);

  final MoshSession session;
  final Screen screen;
  final UdpRelay? relay;
  final List<Object> errors;

  static Future<DartMoshRun> start(
    MoshFixture fixture,
    String program, {
    int cols = 80,
    int rows = 24,
    bool viaRelay = false,
  }) async {
    final out = await fixture.startServer(program);
    final server = MoshServerConfig.parse(out, host: fixture.host);
    UdpRelay? relay;
    var target = server;
    if (viaRelay) {
      relay = await UdpRelay.start(InternetAddress.loopbackIPv4, server.port);
      target = MoshServerConfig(
        host: server.host,
        port: relay.port,
        key: server.key,
      );
    }
    final session = await MoshSession.connect(
      server: target,
      cipher: MoshPacketCipher.aesOcb(server.key),
      address: InternetAddress.loopbackIPv4,
      columns: cols,
      rows: rows,
    );
    final screen = Screen(cols, rows);
    final errors = <Object>[];
    session.stdout.listen(screen.feed);
    session.errors.listen(errors.add);
    return DartMoshRun._(session, screen, relay, errors);
  }

  void type(String text) => session.send(utf8.encode(text));

  /// 等屏幕安静 [quiet] 不变（Mosh 只送最终状态，中间帧可能被跳过）。
  Future<String> settle({
    Duration quiet = const Duration(milliseconds: 1200),
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(timeout);
    var last = screen.text();
    var lastBytes = screen.bytes;
    var stableSince = DateTime.now();
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final now = screen.text();
      if (now != last || screen.bytes != lastBytes) {
        last = now;
        lastBytes = screen.bytes;
        stableSince = DateTime.now();
      } else if (DateTime.now().difference(stableSince) >= quiet) {
        break;
      }
    }
    return last;
  }

  Future<void> close() async {
    await session.close();
    relay?.close();
  }
}
