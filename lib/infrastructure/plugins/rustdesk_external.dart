import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// RustDesk 外部客户端联动（X07）。RustDesk 没有第三方接入文档，每一条都来自冻结的源码
/// （rustdesk/rustdesk tag 1.4.9，提交 6c578292），见 plan/v3/docs/17「X07 固定的 RustDesk 口径」。
/// RustDesk 改了链接处理，这里要对着新源码重新核对，不要凭记忆补写法。
abstract final class RustDeskProtocol {
  static const officialPackage = 'com.carriez.flutter_hbb';
  static const scheme = 'rustdesk';

  /// 1.2.4 起清单里才有 rustdesk scheme、才认 connect 这种链接（1.2.3 两样都没有）。
  static const minVersion = [1, 2, 4];
  static const minVersionText = '1.2.4';

  /// 1.4.7 起，改服务器配置、改固定密码的两种链接要构建时打开内置选项才执行。更早的版本不设防：
  /// 任何 App 或网页发一条链接就能改。本 App 从不发那两种链接，这里只用来提醒用户更新。
  static const gatedSince = [1, 4, 7];
  static const gatedSinceText = '1.4.7';

  /// 读过源码的最高版本。更高的版本照常发，但要告诉用户没核对过。
  static const verifiedUpTo = [1, 5, 0];
  static const verifiedUpToText = '1.5.0';

  /// 已核对的发行渠道证书 SHA-256（小写十六进制，无分隔符）。官方包名加上这里的证书就直接可用。
  ///
  /// 都是从各渠道的安装包里读出来的（出处、文件 sha256 见 docs/17「固定的证书」）。F-Droid 自己编译、自己签，
  /// 所以和 GitHub 发行版不是同一张。要加新证书只能从那个渠道的安装包重新读，不能猜：
  /// `apksigner verify --print-certs <apk>`。
  static const knownSigners = <String, RustDeskChannel>{
    'e92d44ba9b65003c7340683b0a9234f617c1b23a1dd90e89f7d04170b72bfc86':
        RustDeskChannel.githubRelease,
    '85366b10ecadff33e10c53250444a125203908285363c27fc62a561f9660fa48':
        RustDeskChannel.fdroid,
  };
}

enum RustDeskChannel { githubRelease, fdroid }

class RustDeskPeerIdRejected implements Exception {
  const RustDeskPeerIdRejected(this.message);
  final String message;
  @override
  String toString() => message;
}

final _numericId = RegExp(r'^[0-9]{1,16}$');
final _customId = RegExp(r'^[A-Za-z][A-Za-z0-9_-]{5,15}$');
final _controlChars = RegExp(r'[\x00-\x1f\x7f]');

/// 平台层发送前也按这条白名单再核一次（`RustDeskBridge.kt` 里有同一条正则）。
final rustDeskConnectUri =
    RegExp(r'^rustdesk://connect/(?:[0-9]{1,16}|[A-Za-z][A-Za-z0-9_-]{5,15})$');

/// 校验过的 RustDesk ID。只能经 [RustDeskPeerId.parse] 得到，所以拼链接的地方拿不到没校验过的字符串（RDX02）。
///
/// 只收两种：纯数字（RustDesk 自动生成的）、字母开头共 6–16 位的字母数字下划线连字符（自定义 ID）。
/// 这些字符放进链接都不用编码——RustDesk 取 ID 时不做百分号解码，编码了反而连错。
/// 不收的：`ID@服务器`、`?key=`（改用别的 ID 服务器）、结尾 `/r`（强制中继）、IP 或域名直连、整条链接。
/// 那些要么改 RustDesk 的网络设置，要么能把别的参数带进链接；用哪台服务器只在 RustDesk 里配。
class RustDeskPeerId {
  const RustDeskPeerId._(this.value);
  final String value;

  static const maxInputLength = 128;

  static RustDeskPeerId parse(String input) {
    if (input.length > maxInputLength) {
      throw const RustDeskPeerIdRejected('太长了，不像 RustDesk ID');
    }
    final text = input.trim();
    if (text.isEmpty) throw const RustDeskPeerIdRejected('还没填 RustDesk ID');
    if (_controlChars.hasMatch(text)) {
      throw const RustDeskPeerIdRejected('ID 里有看不见的控制字符，请重新输入');
    }
    // RustDesk 界面把数字 ID 显示成三位一组、中间带空格，连接前它自己去掉。照着抄的人多半带着空格。
    final digits = text.replaceAll(' ', '');
    if (_numericId.hasMatch(digits)) return RustDeskPeerId._(digits);
    if (_customId.hasMatch(text)) return RustDeskPeerId._(text);

    if (text.contains('://')) {
      throw const RustDeskPeerIdRejected('这里只填 ID，不要粘贴链接');
    }
    if (text.contains('@') || text.contains('?')) {
      throw const RustDeskPeerIdRejected(
          '不支持在 ID 后面带服务器或密钥：用哪台服务器请在 RustDesk 里配置');
    }
    if (text.endsWith('/r') || text.endsWith(r'\r')) {
      throw const RustDeskPeerIdRejected('不支持在 ID 结尾加 /r 强制中继：请在 RustDesk 里设置');
    }
    if (text.contains('.') || text.contains(':')) {
      throw const RustDeskPeerIdRejected('不支持按 IP 或域名直连，只能填 RustDesk ID');
    }
    throw const RustDeskPeerIdRejected(
        'ID 只能是纯数字（最多 16 位），或字母开头、共 6 到 16 位的字母、数字、下划线、连字符');
  }

  /// 本 App 发给 RustDesk 的唯一一种链接：远程桌面连接。不带密码、密钥、中继或任何别的参数。
  ///
  /// 用 `connect/<ID>` 而不是 `rustdesk://<ID>`：后者把 ID 放在主机名的位置，URI 解析会把它转成小写，
  /// 而且 ID 恰好叫 config、password、terminal 时会被 RustDesk 当成命令。
  String get connectUri => 'rustdesk://connect/$value';

  /// 数字 ID 按 RustDesk 的习惯三位一组显示，方便和 RustDesk 里看到的对着核。
  String get display {
    if (!_numericId.hasMatch(value)) return value;
    final groups = <String>[];
    // 和 RustDesk 的 formatID 一样从右往左分组，最左边一组可以不足三位。
    for (var end = value.length; end > 0; end -= 3) {
      groups.insert(0, value.substring(end - 3 < 0 ? 0 : end - 3, end));
    }
    return groups.join(' ');
  }

  @override
  String toString() => value;
}

/// versionName 开头的数字段，比如 `1.4.9`、`1.4.9-1`。看不出来返回 null。
List<int>? parseRustDeskVersion(String? versionName) {
  final match =
      RegExp(r'^(\d+)\.(\d+)(?:\.(\d+))?').firstMatch(versionName ?? '');
  if (match == null) return null;
  return [
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3) ?? '0'),
  ];
}

int _compareVersion(List<int> a, List<int> b) {
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
  }
  return 0;
}

/// 装着的版本和核对过的源码对不对得上（RDX05 的支持矩阵，出处见 docs/17 的版本表）。
enum RustDeskVersionSupport {
  /// 低于 1.2.4：不接链接，不发。
  tooOld,

  /// 1.2.4–1.4.6：能连，但这个版本接受任何 App 发来的改密码、改服务器链接。
  deepLinksUngated,

  /// 1.4.7–1.5.0：读过源码。
  verified,

  /// 高于 1.5.0：没读过。照旧写法发，不猜新写法。
  newerUnverified,

  /// 版本号看不懂（自己编译的客户端可能随便写）。既然它声明了 rustdesk://，照常发，但说明没法对照。
  unreadable,
}

RustDeskVersionSupport rustDeskVersionSupport(String? versionName) {
  final v = parseRustDeskVersion(versionName);
  if (v == null) return RustDeskVersionSupport.unreadable;
  if (_compareVersion(v, RustDeskProtocol.minVersion) < 0) {
    return RustDeskVersionSupport.tooOld;
  }
  if (_compareVersion(v, RustDeskProtocol.gatedSince) < 0) {
    return RustDeskVersionSupport.deepLinksUngated;
  }
  if (_compareVersion(v, RustDeskProtocol.verifiedUpTo) > 0) {
    return RustDeskVersionSupport.newerUnverified;
  }
  return RustDeskVersionSupport.verified;
}

/// 手机上的一个包，系统报告的事实。证书只认系统读出的值。
class RustDeskClient {
  const RustDeskClient({
    required this.package,
    this.versionName,
    this.versionCode,
    this.signers = const {},
  });

  final String package;
  final String? versionName;
  final int? versionCode;
  final Set<String> signers;
}

class RustDeskProbe {
  const RustDeskProbe({
    required this.platformSupported,
    this.handlers = const [],
    this.officialInstalled,
  });

  /// 目前只做了 Android。
  final bool platformSupported;

  /// 声明能打开 `rustdesk://` 的包。声明了不等于可信：发给谁由 [evaluateRustDeskApp] 决定。
  final List<RustDeskClient> handlers;

  /// 官方包名装着（不管它接不接链接）。用来区分「没装」和「装了但版本太旧、不接链接」。
  final RustDeskClient? officialInstalled;
}

/// 用户明确信任的客户端：包名和证书一起记（RDX01）。包名对、证书变了，要重新核对。
class RustDeskTrust {
  const RustDeskTrust({required this.package, required this.signer});
  final String package;
  final String signer;

  Map<String, Object?> toJson() => {'package': package, 'signer': signer};

  static RustDeskTrust? fromJson(Object? json) {
    if (json is! Map) return null;
    final package = json['package'];
    final signer = json['signer'];
    if (package is! String || signer is! String) return null;
    return RustDeskTrust(package: package, signer: signer);
  }
}

/// 证书凭什么算可信。
enum RustDeskTrustSource { githubRelease, fdroid, userApproved }

/// 此刻能不能把请求交给手机上的 RustDesk，交给哪一个。
sealed class RustDeskAppStatus {
  const RustDeskAppStatus([this.others = const []]);

  /// 也声明能打开 `rustdesk://`、但不是当前目标的包。请求不会发给它们；
  /// 其中要是有用户自己编译的客户端，可以在界面上明确信任后改用它。
  final List<RustDeskClient> others;
}

class RustDeskPlatformUnsupported extends RustDeskAppStatus {
  const RustDeskPlatformUnsupported();
}

class RustDeskNotInstalled extends RustDeskAppStatus {
  const RustDeskNotInstalled(super.others);
}

/// 低于 1.2.4，或者装着官方包名但它不接 `rustdesk://`（旧版本，或被停用）。
class RustDeskVersionTooOld extends RustDeskAppStatus {
  const RustDeskVersionTooOld(this.client, super.others);
  final RustDeskClient client;
}

/// 证书不是已核对的发行渠道证书，也没被用户批准过：要用户看过后决定。
class RustDeskSignerNeedsApproval extends RustDeskAppStatus {
  const RustDeskSignerNeedsApproval(this.client, super.others);
  final RustDeskClient client;
  String get signer => client.signers.single;
}

/// 用户批准过的那个包换了签名。
class RustDeskSignerChanged extends RustDeskAppStatus {
  const RustDeskSignerChanged(this.approved, this.client, super.others);
  final String approved;
  final RustDeskClient client;
  String get current => client.signers.single;
}

/// 多张证书共同签名：批准只记一张，与其放宽，不如先不支持（同插件批准，X02）。
class RustDeskSignerUnsupported extends RustDeskAppStatus {
  const RustDeskSignerUnsupported(this.client, super.others);
  final RustDeskClient client;
}

class RustDeskReady extends RustDeskAppStatus {
  const RustDeskReady({
    required this.client,
    required this.source,
    required this.version,
    List<RustDeskClient> others = const [],
  }) : super(others);

  final RustDeskClient client;
  final RustDeskTrustSource source;
  final RustDeskVersionSupport version;
  String get signer => client.signers.single;
}

/// 决定请求发给谁。
///
/// 用户明确信任过的包还装着、还接链接，就用它（那是用户自己的选择，比如自己编译的客户端）；
/// 否则只认官方包名。别的包声明了 `rustdesk://` 只会被列出来，不会因为「只有它能打开」就拿到请求。
RustDeskAppStatus evaluateRustDeskApp(
  RustDeskProbe probe, {
  RustDeskTrust? trust,
  Map<String, RustDeskChannel> known = RustDeskProtocol.knownSigners,
}) {
  if (!probe.platformSupported) return const RustDeskPlatformUnsupported();
  RustDeskClient? handler(String? package) =>
      probe.handlers.where((c) => c.package == package).firstOrNull;
  final target =
      handler(trust?.package) ?? handler(RustDeskProtocol.officialPackage);
  final others = [
    for (final c in probe.handlers)
      if (c.package != target?.package) c,
  ];
  if (target == null) {
    final installed = probe.officialInstalled;
    return installed == null
        ? RustDeskNotInstalled(others)
        : RustDeskVersionTooOld(installed, others);
  }
  final version = rustDeskVersionSupport(target.versionName);
  if (version == RustDeskVersionSupport.tooOld) {
    return RustDeskVersionTooOld(target, others);
  }
  if (target.signers.length != 1) {
    return RustDeskSignerUnsupported(target, others);
  }
  final signer = target.signers.single;
  // 发行渠道的证书只对官方包名算数：别的包名即使报出同一张证书，也要用户明确信任。
  final channel =
      target.package == RustDeskProtocol.officialPackage ? known[signer] : null;
  if (channel != null) {
    return RustDeskReady(
      client: target,
      source: switch (channel) {
        RustDeskChannel.githubRelease => RustDeskTrustSource.githubRelease,
        RustDeskChannel.fdroid => RustDeskTrustSource.fdroid,
      },
      version: version,
      others: others,
    );
  }
  if (trust == null || trust.package != target.package) {
    return RustDeskSignerNeedsApproval(target, others);
  }
  if (trust.signer != signer) {
    return RustDeskSignerChanged(trust.signer, target, others);
  }
  return RustDeskReady(
    client: target,
    source: RustDeskTrustSource.userApproved,
    version: version,
    others: others,
  );
}

class RustDeskLaunchFailed implements Exception {
  const RustDeskLaunchFailed(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 平台边界。测试里换成假的。
abstract interface class RustDeskPlatform {
  Future<RustDeskProbe> probe();

  /// 用显式包名把 [uri] 交给 [package]。发之前平台层再核一次：链接是白名单里的写法、
  /// 这个包此刻的证书是 [signer]；不是就抛 [RustDeskLaunchFailed]，什么都不发。
  ///
  /// 正常返回只说明系统接下了这次启动，不说明 RustDesk 连上了什么（RDX03）。
  Future<void> launch(
    String uri, {
    required String package,
    required String signer,
  });
}

/// Android 实现（`RustDeskBridge.kt`）。其他平台一律「不支持」。
class AndroidRustDeskPlatform implements RustDeskPlatform {
  static const _channel = MethodChannel('top.xdwa.shun/rustdesk');

  static bool get _supported => Platform.isAndroid;

  static RustDeskClient? _client(Object? raw) {
    if (raw is! Map) return null;
    final package = raw['package'];
    if (package is! String) return null;
    return RustDeskClient(
      package: package,
      versionName: raw['versionName'] as String?,
      versionCode: (raw['versionCode'] as num?)?.toInt(),
      signers: {
        for (final s in (raw['signers'] as List? ?? const []))
          if (s is String) s,
      },
    );
  }

  @override
  Future<RustDeskProbe> probe() async {
    if (!_supported) return const RustDeskProbe(platformSupported: false);
    final map = await _channel.invokeMapMethod<String, Object?>('probe');
    if (map == null) return const RustDeskProbe(platformSupported: true);
    return RustDeskProbe(
      platformSupported: true,
      handlers: [
        for (final raw in (map['handlers'] as List? ?? const []))
          if (_client(raw) case final client?) client,
      ],
      officialInstalled: _client(map['official']),
    );
  }

  @override
  Future<void> launch(
    String uri, {
    required String package,
    required String signer,
  }) async {
    if (!_supported) throw const RustDeskLaunchFailed('只支持 Android');
    try {
      await _channel.invokeMethod<void>(
          'launch', {'uri': uri, 'package': package, 'sha256': signer});
    } on PlatformException catch (e) {
      throw RustDeskLaunchFailed(e.message ?? e.code);
    }
  }
}
