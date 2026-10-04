import 'dart:convert';
import 'dart:typed_data';

/// Mosh 的 SSH 引导：宿主经已核验的 SSH 连接执行固定命令拉起 mosh-server，再从输出里取 UDP 端口和会话 key（docs/16 第 3 步）。
///
/// 这里只有两样纯函数：拼命令（没有任何用户输入能进去）和解析输出（不信任远端、有界、失败即关）。
/// 什么时候执行、经哪条 SSH、失败怎么展示是 X09 的事。
///
/// 会话 key 是秘密：解析结果里的 key 只是字节，[MoshBootstrapResult.toString] 不打印它，错误信息里也从不带原始输出。
/// 原始输出里如果有 key，调用方用完要丢掉（不进日志、不进诊断）。
class MoshBootstrap {
  MoshBootstrap._();

  /// 官方默认端口范围（mosh-server 自己的默认，也是常见防火墙规则放行的范围）。
  static const defaultPortRange = (60001, 60999);

  /// 远端输出最多收这么多字节；超过就不解析、直接失败（防止恶意或失控的输出把宿主撑爆）。
  static const maxOutputBytes = 64 * 1024;

  /// 固定命令。只有端口范围是参数，而且是校验过的整数，不经过任何字符串拼接用户数据。
  ///
  /// - `-s`：mosh-server 绑定到这次 SSH 连接的本地地址（官方 mosh 脚本的默认做法）。
  /// - `-c 256`：告诉服务器客户端支持 256 色（宿主的终端引擎支持）。
  /// - `-l LANG=en_US.UTF-8`：远端默认 locale 不是 UTF-8 时，mosh-server 改用这个；远端没装这个 locale 时，
  ///   mosh-server 会报「needs a UTF-8 native locale」，解析时识别成 [MoshBootstrapFailure.localeUnsupported]。
  /// - 不带 `--` 和要运行的命令：跑用户的登录 shell，和直接 `mosh host` 一样。
  static String command({(int, int) portRange = defaultPortRange}) {
    final (low, high) = portRange;
    if (low < 1 || high > 65535 || low > high) {
      throw ArgumentError.value('$low:$high', 'portRange', 'UDP 端口范围无效');
    }
    final ports = low == high ? '$low' : '$low:$high';
    return 'mosh-server new -s -c 256 -l LANG=en_US.UTF-8 -p $ports';
  }

  static final _prefix = ascii.encode('MOSH CONNECT ');
  static final _mention = ascii.encode('MOSH CONNECT');

  /// 解析 `mosh-server new` 的输出（stdout 和 stderr 合在一起传进来，顺序无所谓）。
  ///
  /// 失败即关：没有恰好一行完整的 `MOSH CONNECT <端口> <key>`、端口不在请求的范围里、key 不是规范的 base64、
  /// 输出过大，都抛 [MoshBootstrapException]，不猜、不取「第一条」。
  ///
  /// 按字节解析，不把整段输出转成字符串：Dart 字符串清不掉，key 一旦进了字符串就会一直留在堆里直到被回收。
  /// 调用方解析完可以把 [output] 清零。
  static MoshBootstrapResult parse(
    List<int> output, {
    (int, int) portRange = defaultPortRange,
  }) {
    if (output.length > maxOutputBytes) {
      throw const MoshBootstrapException(MoshBootstrapFailure.outputTooLarge);
    }
    final bytes = output is Uint8List ? output : Uint8List.fromList(output);
    int? port;
    Uint8List? key;
    var found = 0;
    var mentionsConnect = false;
    var start = 0;
    while (start <= bytes.length) {
      var end = bytes.indexOf(0x0a, start);
      if (end < 0) end = bytes.length;
      // 每行只允许去掉结尾一个 \r（CRLF）。行中间的 \r 会让终端把后半行盖到前面，正好可以用来伪装，所以不认。
      var lineEnd = end;
      if (lineEnd > start && bytes[lineEnd - 1] == 0x0d) lineEnd--;
      final line = Uint8List.sublistView(bytes, start, lineEnd);
      if (_contains(line, _mention)) mentionsConnect = true;
      final parsed = _parseLine(line);
      if (parsed != null) {
        found++;
        port = parsed.$1;
        key?.fillRange(0, key.length, 0);
        key = parsed.$2;
      }
      start = end + 1;
    }
    if (found > 1) {
      // 两条都长得对：可能是 shell 启动文件、motd 或恶意服务器夹带的。分不出哪条是真的就都不用。
      key?.fillRange(0, key.length, 0);
      throw const MoshBootstrapException(MoshBootstrapFailure.ambiguous);
    }
    if (found == 0) {
      throw MoshBootstrapException(_whyNoConnect(bytes, mentionsConnect));
    }
    final (low, high) = portRange;
    if (port! < low || port > high) {
      key!.fillRange(0, key.length, 0);
      throw const MoshBootstrapException(MoshBootstrapFailure.portOutOfRange);
    }
    if (!_canonicalKey(key!)) {
      key.fillRange(0, key.length, 0);
      throw const MoshBootstrapException(MoshBootstrapFailure.badKey);
    }
    return MoshBootstrapResult._(port, key);
  }

  /// 整行必须恰好是 `MOSH CONNECT <1–5 位、不以 0 开头的端口> <22 个 base64 字符>`，前后不许夹别的字节。
  static (int, Uint8List)? _parseLine(Uint8List line) {
    const keyLength = 22;
    if (line.length < _prefix.length + 1 + 1 + keyLength) return null;
    for (var i = 0; i < _prefix.length; i++) {
      if (line[i] != _prefix[i]) return null;
    }
    var i = _prefix.length;
    var port = 0;
    final digitsStart = i;
    while (i < line.length && line[i] >= 0x30 && line[i] <= 0x39) {
      if (i - digitsStart == 5) return null;
      port = port * 10 + (line[i] - 0x30);
      i++;
    }
    if (i == digitsStart || line[digitsStart] == 0x30 || port > 65535) {
      return null;
    }
    if (i >= line.length || line[i] != 0x20) return null;
    i++;
    if (line.length - i != keyLength) return null;
    for (var j = i; j < line.length; j++) {
      if (_base64Value(line[j]) < 0) return null;
    }
    return (port, Uint8List.fromList(Uint8List.sublistView(line, i)));
  }

  static int _base64Value(int c) {
    if (c >= 0x41 && c <= 0x5a) return c - 0x41; // A-Z
    if (c >= 0x61 && c <= 0x7a) return c - 0x61 + 26; // a-z
    if (c >= 0x30 && c <= 0x39) return c - 0x30 + 52; // 0-9
    if (c == 0x2b) return 62; // +
    if (c == 0x2f) return 63; // /
    return -1;
  }

  /// 22 个字符 = 132 位，key 只有 128 位：最后一个字符的低 4 位必须是 0，否则同一把 key 有多种写法（不是规范 base64）。
  static bool _canonicalKey(Uint8List key) =>
      (_base64Value(key.last) & 0x0f) == 0;

  static bool _contains(Uint8List haystack, List<int> needle) {
    outer:
    for (var i = 0; i + needle.length <= haystack.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return true;
    }
    return false;
  }

  static MoshBootstrapFailure _whyNoConnect(
      Uint8List bytes, bool mentionsConnect) {
    if (_contains(bytes, ascii.encode('needs a UTF-8 native locale'))) {
      return MoshBootstrapFailure.localeUnsupported;
    }
    // sh/bash/zsh 的说法各不一样，都带「mosh-server」和「not found」。
    if (_contains(bytes, ascii.encode('mosh-server: not found')) ||
        _contains(bytes, ascii.encode('mosh-server: command not found')) ||
        _contains(bytes, ascii.encode('command not found: mosh-server'))) {
      return MoshBootstrapFailure.serverMissing;
    }
    return mentionsConnect
        ? MoshBootstrapFailure.malformed
        : MoshBootstrapFailure.noConnectLine;
  }
}

enum MoshBootstrapFailure {
  /// 远端输出超过 [MoshBootstrap.maxOutputBytes]。
  outputTooLarge('mosh-server 的输出过长，已停止解析'),

  /// 有不止一行看起来像 `MOSH CONNECT`。
  ambiguous('mosh-server 的输出里有多条连接信息，无法确定哪条可信'),

  /// 提到了 MOSH CONNECT 但格式不对（端口、key 长度或字符不对，或者同一行夹了别的东西）。
  malformed('mosh-server 返回的连接信息格式不对'),

  /// 完全没有连接信息。
  noConnectLine('没有收到 mosh-server 的连接信息'),

  /// 端口不在请求的范围内。
  portOutOfRange('mosh-server 返回的端口不在请求的范围内'),

  /// key 不是规范的 16 字节 base64。
  badKey('mosh-server 返回的会话密钥格式不对'),

  /// 远端没有可用的 UTF-8 locale。
  localeUnsupported(
      '远端没有可用的 UTF-8 语言环境，mosh-server 拒绝启动（需要在服务器上生成 en_US.UTF-8 等 UTF-8 locale）'),

  /// 远端没装 mosh-server。
  serverMissing('远端没有安装 mosh-server');

  const MoshBootstrapFailure(this.message);
  final String message;
}

class MoshBootstrapException implements Exception {
  const MoshBootstrapException(this.failure);
  final MoshBootstrapFailure failure;

  /// 只说是哪一类问题，从不带远端原始输出（里面可能有 key）。
  @override
  String toString() => failure.message;
}

/// 解析出的连接材料。key 是 22 个 base64 字符的 ASCII 字节，交给插件后调用 [wipe]。
class MoshBootstrapResult {
  MoshBootstrapResult._(this.port, this._key);

  final int port;
  final Uint8List _key;
  var _wiped = false;

  /// 要交给插件时取；拿到的是同一份字节，[wipe] 之后全是 0。
  Uint8List get printableKey {
    if (_wiped) throw StateError('会话密钥已清除');
    return _key;
  }

  void wipe() {
    _key.fillRange(0, _key.length, 0);
    _wiped = true;
  }

  @override
  String toString() => 'MoshBootstrapResult(port: $port, key: <已隐藏>)';
}

/// 交给 Mosh 插件的一次会话目标：宿主按路由解析好的数字 IP + 这次 bootstrap 的结果。
/// 只允许直连（docs/16：SOCKS / 跳板承载不了 UDP，由路由判定在 bootstrap 之前就拒绝）。
class MoshSessionTarget {
  const MoshSessionTarget(this.udpHost, this.material);

  /// 数字形式的 IPv4/IPv6。插件不做 DNS，给主机名会被拒绝。
  final String udpHost;
  final MoshBootstrapResult material;
}
