import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;

import 'android_key_fallback.dart';
import 'guarded_writer.dart';

/// R04 spike：没有 SSH，用"回环"代替 PTY——终端发出的字节（按键、输入法提交、协议回应）
/// 原样写回终端显示，底部同时列出最近发出的原始字节，真机上用来核对：
/// 中文 composing 只在提交后发一次、方向键是转义序列而不是文字、Ctrl/Alt 组合键编码正确。
void main() => runApp(const SpikeApp());

class SpikeApp extends StatelessWidget {
  const SpikeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'terminal spike',
    theme: ThemeData.dark(),
    home: const LoopbackPage(),
  );
}

class LoopbackPage extends StatefulWidget {
  const LoopbackPage({super.key});

  @override
  State<LoopbackPage> createState() => _LoopbackPageState();
}

class _LoopbackPageState extends State<LoopbackPage> {
  final controller = TerminalController();
  late final writer = GuardedWriter(controller.write);
  final sent = <String>[];

  /// 只记录不拦截（返回 false）：看软键盘/adb 注入的键到底以什么物理键、逻辑键到达 Flutter。
  /// 输入法发来的按键 scanCode 常为 0，终端按物理键查表时会认不出来。
  static bool _logKey(KeyEvent e) {
    debugPrint(
      'SPIKE_KEY ${e.runtimeType} '
      'phys=0x${e.physicalKey.usbHidUsage.toRadixString(16)} '
      'logical=0x${e.logicalKey.keyId.toRadixString(16)} '
      'char=${e.character?.codeUnits}',
    );
    return false;
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_logKey);
    controller.onOutput = (bytes) {
      final copy = Uint8List.fromList(bytes);
      // 同时打到 logcat（adb logcat -s flutter），模拟器上用 adb 驱动软键盘/输入法时靠它逐次核对，
      // 屏幕底部只留最近 8 条，截图核对会漏掉中间的发送。
      debugPrint('SPIKE_SENT ${_describe(copy)}');
      setState(() {
        sent.insert(0, _describe(copy));
        if (sent.length > 8) sent.removeLast();
      });
      // write 期间产生的是协议回应（如 DA），真实场景发往 SSH；回环里只记录、不回显，
      // 否则终端会读到自己的回应。用户输入才模拟 PTY 回显，并经 GuardedWriter 防重入。
      if (!writer.isWriting) writer.write(_echo(copy));
    };
    writer.write(
      Uint8List.fromList(
        utf8.encode(
          'libghostty + flterm 回环测试\r\n中文 / emoji 🙂 / 组合字符 é\r\n\r\n',
        ),
      ),
    );
  }

  /// 模拟一个开着 echo 的 PTY：回车回显成换行，退格（0x7f）回显成"退一格、空格、再退一格"，
  /// 其余原样回显。退格原先原样回显，Ghostty 会把 DEL 画成方格（真机上被当成 bug 报过）；
  /// 真实 PTY 不回送 0x7f。中文占两格时这里只擦一格，和 Linux 行规程一样，只是回环演示。
  static Uint8List _echo(Uint8List bytes) => Uint8List.fromList([
    for (final b in bytes)
      ...switch (b) {
        13 => const [13, 10],
        0x7f => const [8, 32, 8],
        _ => [b],
      },
  ]);

  static String _describe(Uint8List bytes) {
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    final text = utf8
        .decode(bytes, allowMalformed: true)
        .replaceAll('\x1b', '⎋')
        .replaceAll('\r', '⏎');
    return '${bytes.length}B  $hex  「$text」';
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_logKey);
    writer.close(); // 先关写入口：dispose 后 write 会抛 StateError（0.0.5 时直接段错误）
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            // 放在 TerminalView 外层：flterm 认不出的键才会冒泡到这里。
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: (_, e) => androidKeyFallback(controller, e),
              child: TerminalView(controller: controller),
            ),
          ),
          Container(
            width: double.infinity,
            color: Colors.black,
            padding: const EdgeInsets.all(6),
            child: Text(
              sent.isEmpty ? '（还没有发出字节）' : sent.join('\n'),
              key: const ValueKey('sent-bytes'),
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              maxLines: 8,
            ),
          ),
        ],
      ),
    ),
  );
}
