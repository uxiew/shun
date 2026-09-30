import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// 网易 UU 远程官方跨 App 协议（X06）。每一条都来自冻结的官方文档，见 plan/v3/docs/17「X06 固定的官方口径」
/// （netease-uuyc/uuremote-integration-guide 提交 be7d8109）。官方改了协议，这里要跟着重新核对，不要凭记忆补字段。
abstract final class UuRemoteProtocol {
  static const package = 'com.netease.uuremote';
  static const scheme = 'uuremote';

  /// 官方：iOS 与 Android 客户端均从 4.42.0 起支持本协议。
  static const minVersion = [4, 42, 0];
  static const minVersionText = '4.42.0';

  /// 本 App 接收回调的地址。官方示例同样用自定义 scheme + host `callback`。
  /// 自定义 scheme 谁都能声明：state/nonce 只防「没发过的请求、重放」，证明不了回调真是 UU 发的（UUR06）。
  static const callbackScheme = 'xwshun-uuremote';
  static const callbackHost = 'callback';

  /// 从官方渠道下载的 UU 远程 APK 读出的签名证书 SHA-256（小写十六进制，无分隔符）。
  ///
  /// 官方文档没有给证书，所以只能自己从官方 APK 读，不能猜。空集合表示还没核对过官方 APK：
  /// 这时手机上的 UU 要用户看过证书后明确批准（和插件批准一样），证书以后再变就要重新批准。
  static const officialSigners = <String>{};

  static const bindErrors = {
    UuBindErrors.noDevice,
    UuBindErrors.userCancel,
    UuBindErrors.timeout,
    UuBindErrors.notLogined,
    UuBindErrors.superseded,
    UuBindErrors.logout,
    UuBindErrors.internalError,
  };

  static const controlReasons = {
    UuReasons.busy,
    UuReasons.deviceOffline,
    UuReasons.deviceNotFound,
    UuReasons.pipUnsupported,
    UuReasons.loginTimeout,
    UuReasons.networkUnavailable,
    UuReasons.notAllowed,
    UuReasons.connectTimeout,
    UuReasons.connectFailed,
    UuReasons.userCancel,
    UuReasons.invalidRequest,
    UuReasons.internalError,
  };
}

/// 绑定失败的错误码（官方 2.5），原文照抄。
abstract final class UuBindErrors {
  static const noDevice = 'no_device';
  static const userCancel = 'user_cancel';
  static const timeout = 'timeout';
  static const notLogined = 'not_logined';
  static const superseded = 'superseded';
  static const logout = 'logout';
  static const internalError = 'internal_error';
}

/// 小窗远控失败的 reason（官方 3.5），原文照抄。
abstract final class UuReasons {
  static const busy = 'busy';
  static const deviceOffline = 'device_offline';
  static const deviceNotFound = 'device_not_found';
  static const pipUnsupported = 'pip_unsupported';
  static const loginTimeout = 'login_timeout';
  static const networkUnavailable = 'network_unavailable';
  static const notAllowed = 'not_allowed';
  static const connectTimeout = 'connect_timeout';
  static const connectFailed = 'connect_failed';
  static const userCancel = 'user_cancel';
  static const invalidRequest = 'invalid_request';
  static const internalError = 'internal_error';
}

enum UuWindow {
  /// 全屏：UU 无论成败都不回调（官方 3.3）。
  fullscreen(0),

  /// 画中画小窗：带 callback 时最终且只回调一次。
  pip(1);

  const UuWindow(this.wire);
  final int wire;
}

enum UuCallbackKind {
  bind('/bind'),
  control('/control');

  const UuCallbackKind(this.path);
  final String path;
}

/// 发给 UU 的请求。参数值只编码一次；`encodeComponent` 和官方 Android 示例用的 `Uri.encode`
/// 一样保留 `-_.!~*'()`、其余都转成 %XX，空格是 %20 而不是 `+`。
abstract final class UuRequests {
  static String callback(UuCallbackKind kind, String state) =>
      '${UuRemoteProtocol.callbackScheme}://${UuRemoteProtocol.callbackHost}'
      '${kind.path}?state=$state';

  static String authorize({required String callback, required String nonce}) =>
      'uuremote://external/device/authorize'
      '?callback=${Uri.encodeComponent(callback)}'
      '&nonce=${Uri.encodeComponent(nonce)}';

  static String control({
    required String anonymousDeviceId,
    required UuWindow window,
    String? callback,
  }) =>
      'uuremote://external/device/control'
      '?anonymous_device_id=${Uri.encodeComponent(anonymousDeviceId)}'
      '&window_type=${window.wire}'
      '${callback == null ? '' : '&callback=${Uri.encodeComponent(callback)}'}';
}

/// 解析后的回调。只说明「结构合法」，是不是本 App 发过的请求由调用方按 state 对。
sealed class UuCallback {
  const UuCallback(this.state);
  final String state;
}

class UuBindCallback extends UuCallback {
  const UuBindCallback(
    super.state, {
    required this.nonce,
    this.anonymousDeviceId,
    this.error,
  });

  final String nonce;

  /// 加密设备标识。不透明：不解密、不猜格式、不写日志（docs/17）。
  final String? anonymousDeviceId;
  final String? error;
}

class UuControlCallback extends UuCallback {
  const UuControlCallback(super.state, {required this.success, this.reason});
  final bool success;

  /// 失败原因原文。未知的也原样保留，调用方按 connect_failed 处理（官方 3.6）。
  final String? reason;
}

class UuCallbackRejected implements Exception {
  const UuCallbackRejected(this.message);
  final String message;
  @override
  String toString() => message;
}

final _state = RegExp(r'^[A-Za-z0-9_-]{22}$');
final _control = RegExp(r'[\x00-\x1f\x7f]');

/// 整条回调的上限。官方没写 anonymous_device_id 多长，给足余量但有界。
const maxCallbackLength = 16 * 1024;
const maxDeviceIdLength = 4096;
const _maxParams = 12;
const _maxShortValue = 128;

/// 解析回调。结构不对一律抛 [UuCallbackRejected]，不做「尽量修复」。
///
/// 查询串自己切、每个值只做一次百分号解码，`+` 按字面：加密 ID 常是 base64，里面的 `+` 按表单规则当成空格
/// 就把 ID 弄坏了；官方要求这类特殊字符编码后传，按字面处理不会误伤编码过的值。同名参数出现两次直接拒收：
/// 官方说结果字段会「覆盖」同名原参数，正常回调不会重复（UUR02）。
UuCallback parseUuCallback(String raw) {
  if (raw.length > maxCallbackLength) {
    throw const UuCallbackRejected('回调太长');
  }
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      uri.scheme != UuRemoteProtocol.callbackScheme ||
      uri.host != UuRemoteProtocol.callbackHost ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      uri.hasFragment) {
    throw const UuCallbackRejected('不是本 App 的 UU 回调地址');
  }
  final kind = UuCallbackKind.values.where((k) => k.path == uri.path);
  if (kind.isEmpty) throw const UuCallbackRejected('回调路径不对');

  final at = raw.indexOf('?');
  final params = _parseQueryOnce(at < 0 ? '' : raw.substring(at + 1));
  String? one(String key, {int max = _maxShortValue}) {
    final values = params[key];
    if (values == null) return null;
    final value = values.single;
    if (value.length > max || _control.hasMatch(value)) {
      throw UuCallbackRejected('回调参数超长或含控制字符：$key');
    }
    return value;
  }

  final state = one('state');
  if (state == null || !_state.hasMatch(state)) {
    throw const UuCallbackRejected('回调里没有本 App 的请求标记');
  }
  switch (kind.single) {
    case UuCallbackKind.bind:
      final nonce = one('nonce');
      final id = one('anonymous_device_id', max: maxDeviceIdLength);
      final error = one('error');
      if (nonce == null) throw const UuCallbackRejected('绑定回调缺 nonce');
      if ((id == null) == (error == null)) {
        throw const UuCallbackRejected('绑定回调的成功和失败要有且只有一个');
      }
      if (id != null && id.isEmpty || error != null && error.isEmpty) {
        throw const UuCallbackRejected('绑定回调的结果是空的');
      }
      return UuBindCallback(state,
          nonce: nonce, anonymousDeviceId: id, error: error);
    case UuCallbackKind.control:
      final status = one('status');
      final reason = one('reason');
      if (status == 'success') {
        if (reason != null) {
          throw const UuCallbackRejected('小窗回调报成功却带了失败原因');
        }
        return UuControlCallback(state, success: true);
      }
      if (status == 'failure') {
        if (reason == null || reason.isEmpty) {
          throw const UuCallbackRejected('小窗回调报失败却没有原因');
        }
        return UuControlCallback(state, success: false, reason: reason);
      }
      throw const UuCallbackRejected('小窗回调的 status 不对');
  }
}

Map<String, List<String>> _parseQueryOnce(String query) {
  final out = <String, List<String>>{};
  if (query.isEmpty) return out;
  final parts = query.split('&');
  if (parts.length > _maxParams) {
    throw const UuCallbackRejected('回调参数太多');
  }
  for (final part in parts) {
    if (part.isEmpty) throw const UuCallbackRejected('回调参数格式不对');
    final eq = part.indexOf('=');
    final String key;
    final String value;
    try {
      key = Uri.decodeComponent(eq < 0 ? part : part.substring(0, eq));
      value = eq < 0 ? '' : Uri.decodeComponent(part.substring(eq + 1));
    } on ArgumentError {
      throw const UuCallbackRejected('回调参数的编码不对');
    } on FormatException {
      throw const UuCallbackRejected('回调参数的编码不对');
    }
    final values = out.putIfAbsent(key, () => []);
    if (values.isNotEmpty) {
      throw UuCallbackRejected('回调参数重复出现：$key');
    }
    values.add(value);
  }
  return out;
}

/// versionName 开头的数字段，比如 `4.42.0`、`4.42.0.1234`、`4.42.0-beta`。看不出来返回 null。
List<int>? parseUuVersion(String? versionName) {
  final match =
      RegExp(r'^(\d+)\.(\d+)(?:\.(\d+))?').firstMatch(versionName ?? '');
  if (match == null) return null;
  return [
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3) ?? '0'),
  ];
}

bool uuVersionSupported(String? versionName) {
  final v = parseUuVersion(versionName);
  if (v == null) return false;
  for (var i = 0; i < 3; i++) {
    if (v[i] != UuRemoteProtocol.minVersion[i]) {
      return v[i] > UuRemoteProtocol.minVersion[i];
    }
  }
  return true;
}

/// 系统报告的、手机上和 UU 有关的事实。证书只认系统读出的值。
class UuProbe {
  const UuProbe({
    required this.platformSupported,
    this.officialInstalled = false,
    this.officialHandlesScheme = false,
    this.versionName,
    this.versionCode,
    this.signers = const {},
    this.otherHandlers = const [],
  });

  /// 目前只做了 Android。
  final bool platformSupported;
  final bool officialInstalled;

  /// `uuremote://external` 能不能解析到官方包（官方要求的检测方式）。
  final bool officialHandlesScheme;
  final String? versionName;
  final int? versionCode;
  final Set<String> signers;

  /// 也声明能打开 `uuremote://` 的其他包。请求不会发给它们，只用来提醒用户。
  final List<String> otherHandlers;
}

/// 此刻能不能把请求交给手机上的 UU 远程。
sealed class UuAppStatus {
  const UuAppStatus();
}

class UuPlatformUnsupported extends UuAppStatus {
  const UuPlatformUnsupported();
}

class UuNotInstalled extends UuAppStatus {
  const UuNotInstalled(this.otherHandlers);
  final List<String> otherHandlers;
}

/// 装了官方包名，但 `uuremote://` 解析不到它（版本太旧、或被停用）。
class UuSchemeNotHandled extends UuAppStatus {
  const UuSchemeNotHandled(this.versionName);
  final String? versionName;
}

class UuVersionTooOld extends UuAppStatus {
  const UuVersionTooOld(this.versionName);
  final String? versionName;
}

/// 证书不是已核对的官方证书，也没被用户批准过：要用户看过后决定。
class UuSignerNeedsApproval extends UuAppStatus {
  const UuSignerNeedsApproval(this.signer, this.versionName);
  final String signer;
  final String? versionName;
}

/// 用户批准过另一张证书，手机上的 UU 换了签名。
class UuSignerChanged extends UuAppStatus {
  const UuSignerChanged(this.approved, this.current);
  final String approved;
  final String current;
}

/// 多张证书共同签名：批准只记一张，与其放宽，不如先不支持（同插件批准，X02）。
class UuSignerUnsupported extends UuAppStatus {
  const UuSignerUnsupported(this.signers);
  final Set<String> signers;
}

class UuReady extends UuAppStatus {
  const UuReady({
    required this.signer,
    required this.official,
    this.versionName,
    this.otherHandlers = const [],
  });
  final String signer;

  /// true：和从官方 APK 读出的证书一致；false：用户看过后批准的。
  final bool official;
  final String? versionName;
  final List<String> otherHandlers;
}

UuAppStatus evaluateUuApp(
  UuProbe probe, {
  Set<String> official = UuRemoteProtocol.officialSigners,
  String? approvedSigner,
}) {
  if (!probe.platformSupported) return const UuPlatformUnsupported();
  if (!probe.officialInstalled) return UuNotInstalled(probe.otherHandlers);
  if (!uuVersionSupported(probe.versionName)) {
    return UuVersionTooOld(probe.versionName);
  }
  if (!probe.officialHandlesScheme) {
    return UuSchemeNotHandled(probe.versionName);
  }
  if (probe.signers.length != 1) return UuSignerUnsupported(probe.signers);
  final signer = probe.signers.single;
  if (official.contains(signer)) {
    return UuReady(
      signer: signer,
      official: true,
      versionName: probe.versionName,
      otherHandlers: probe.otherHandlers,
    );
  }
  if (approvedSigner == null) {
    return UuSignerNeedsApproval(signer, probe.versionName);
  }
  if (approvedSigner != signer) return UuSignerChanged(approvedSigner, signer);
  return UuReady(
    signer: signer,
    official: false,
    versionName: probe.versionName,
    otherHandlers: probe.otherHandlers,
  );
}

class UuLaunchFailed implements Exception {
  const UuLaunchFailed(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 平台边界。测试里换成假的。
abstract interface class UuRemotePlatform {
  Future<UuProbe> probe();

  /// 用显式包名把 [uri] 交给官方包。发之前平台层再核一次证书是 [signer]，不是就抛 [UuLaunchFailed]。
  Future<void> launch(String uri, {required String signer});

  /// 收到的回调原文（未解码）。冷启动和 App 已在运行时收到的走同一条流。
  Stream<String> get callbacks;
}

/// Android 实现（`UuRemoteBridge.kt`）。其他平台一律「不支持」。
class AndroidUuRemotePlatform implements UuRemotePlatform {
  AndroidUuRemotePlatform() {
    if (!_supported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'callbacksAvailable') await _drain();
      return null;
    });
    unawaited(_drain());
  }

  static const _channel = MethodChannel('top.xdwa.xwshun/uuremote');
  final _callbacks = StreamController<String>.broadcast();
  final _early = <String>[];
  var _listening = false;

  static bool get _supported => Platform.isAndroid;

  /// 平台层先把回调排队，这里取走。Dart 还没监听时先攒着，第一个监听者一来就补发，冷启动的回调不会丢。
  Future<void> _drain() async {
    final list = await _channel.invokeListMethod<String>('takeCallbacks');
    for (final raw in list ?? const <String>[]) {
      _listening ? _callbacks.add(raw) : _early.add(raw);
    }
  }

  @override
  Stream<String> get callbacks {
    if (!_listening) {
      _listening = true;
      scheduleMicrotask(() {
        for (final raw in _early) {
          _callbacks.add(raw);
        }
        _early.clear();
      });
    }
    return _callbacks.stream;
  }

  @override
  Future<UuProbe> probe() async {
    if (!_supported) return const UuProbe(platformSupported: false);
    final map = await _channel.invokeMapMethod<String, Object?>('probe');
    if (map == null) return const UuProbe(platformSupported: true);
    return UuProbe(
      platformSupported: true,
      officialInstalled: map['installed'] == true,
      officialHandlesScheme: map['handlesScheme'] == true,
      versionName: map['versionName'] as String?,
      versionCode: (map['versionCode'] as num?)?.toInt(),
      signers: {
        for (final s in (map['signers'] as List? ?? const []))
          if (s is String) s,
      },
      otherHandlers: [
        for (final s in (map['otherHandlers'] as List? ?? const []))
          if (s is String) s,
      ],
    );
  }

  @override
  Future<void> launch(String uri, {required String signer}) async {
    if (!_supported) throw const UuLaunchFailed('只支持 Android');
    try {
      await _channel
          .invokeMethod<void>('launch', {'uri': uri, 'sha256': signer});
    } on PlatformException catch (e) {
      throw UuLaunchFailed(e.message ?? e.code);
    }
  }
}
