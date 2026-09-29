import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// 终端原始字节素材。全部由代码生成、内容固定，不依赖外部文件。
///
/// 覆盖：3 字节中文、4 字节 emoji 与 ZWJ 序列、组合字符、SGR 颜色、光标定位、
/// 备用屏进出、bracketed paste 开关、OSC 标题、以及会触发终端回应的 DA 查询。
class VtSamples {
  static final Uint8List cjkAndAnsi = _bytes([
    '\x1b[1;32m中文输出测试\x1b[0m：服务器已连接\r\n',
    '繁體與日本語テキスト、한국어\r\n',
    '\x1b[31m错误\x1b[39m 与 \x1b[4m下划线\x1b[24m\r\n',
  ]);

  static final Uint8List emojiAndCombining = _bytes([
    '表情 🙂👍🏽 家庭 👨‍👩‍👧 旗 🇨🇳\r\n',
    '组合字符 é ä ñ\r\n',
  ]);

  static final Uint8List fullScreen = _bytes([
    '\x1b]0;标题：vim 编辑中\x07',
    '\x1b[?1049h\x1b[2J\x1b[H',
    '\x1b[5;10H全屏中文行\x1b[K',
    '\x1b[?2004h',
    '\x1b[c', // DA 查询：终端会回应，回应必须只发一次
    '\x1b[?2004l',
    '\x1b[?1049l',
    '回到主屏\r\n',
  ]);

  /// 所有样本拼接起来，作为一次完整会话输出。
  static final Uint8List all = Uint8List.fromList([
    ...cjkAndAnsi,
    ...emojiAndCombining,
    ...fullScreen,
  ]);

  /// 真正的非法 UTF-8（孤立的续字节和截断序列）。
  /// 用来确认：非法字节该出几个 U+FFFD 就出几个，不因为切包位置不同而变化。
  static final Uint8List invalidUtf8 = Uint8List.fromList([
    ...utf8.encode('前'),
    0x80,
    ...utf8.encode('中'),
    0xE4, 0xB8, // 截断的 3 字节序列
    ...utf8.encode('后\r\n'),
  ]);

  static Uint8List _bytes(List<String> parts) =>
      Uint8List.fromList(utf8.encode(parts.join()));
}

/// 按固定种子随机切包，模拟网络 chunk 边界。同一 seed 结果可复现。
List<Uint8List> randomChunks(Uint8List bytes, int seed, {int maxChunk = 7}) {
  final random = Random(seed);
  final chunks = <Uint8List>[];
  var offset = 0;
  while (offset < bytes.length) {
    final size = min(1 + random.nextInt(maxChunk), bytes.length - offset);
    chunks.add(Uint8List.sublistView(bytes, offset, offset + size));
    offset += size;
  }
  return chunks;
}

/// 逐字节切包。
List<Uint8List> byteChunks(Uint8List bytes) => [
      for (var i = 0; i < bytes.length; i++)
        Uint8List.sublistView(bytes, i, i + 1)
    ];
