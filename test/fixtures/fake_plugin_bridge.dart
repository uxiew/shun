import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:shun/infrastructure/plugins/android_plugin_bridge.dart';

/// 插件桥的测试替身（X12）：照 Kotlin 桥的行为——没连着时 ping 报 NOT_CONNECTED、connect 之后才算连着、
/// 一个包只留一条连接——把宿主发给插件的每一下都记下来；插件那一侧的事件、输出由测试按真实顺序发。
class FakePluginBridge extends AndroidPluginBridge {
  var installed = <DiscoveredPackage>[];
  final connected = <String>{};
  final connects = <String>[];
  final disconnects = <String>[];
  final opened =
      <({String package, String handle, int generation, int cols, int rows})>[];
  final writes = <String>[];
  final resizes = <String>[];
  final closed = <String>[];
  final settingsOpened = <String>[];
  PluginBridgeException? connectError;
  PluginBridgeException? openError;
  final _data = StreamController<SessionDataEvent>.broadcast(sync: true);
  final _events = StreamController<SessionBridgeEvent>.broadcast(sync: true);
  final changes = StreamController<PackageChange>.broadcast(sync: true);

  /// 插件回报最近打开的那个会话的状态。
  void event(int sequence, String state) {
    final s = opened.last;
    _events.add(SessionBridgeEvent(
      type: 'sessionEvent',
      packageName: s.package,
      handle: s.handle,
      generation: s.generation,
      sequence: sequence,
      state: state,
    ));
  }

  /// 插件往最近打开的那个会话写一段终端输出。
  void data(String text) {
    final s = opened.last;
    _data.add(SessionDataEvent(s.package, s.handle, s.generation,
        Uint8List.fromList(utf8.encode(text))));
  }

  /// 宿主断开了整个插件连接（停用、撤销、进程死了）。
  void connectionClosed(String cause) {
    final s = opened.last;
    _events.add(SessionBridgeEvent(
      type: 'sessionClosed',
      packageName: s.package,
      handle: s.handle,
      generation: s.generation,
      reason: cause,
      cause: cause,
    ));
  }

  @override
  bool get supported => true;
  @override
  Stream<PackageChange> get packageChanges => changes.stream;
  @override
  Stream<SessionDataEvent> get sessionData => _data.stream;
  @override
  Stream<SessionBridgeEvent> get sessionEvents => _events.stream;
  @override
  Future<List<DiscoveredPackage>> discover() async => installed;
  @override
  Future<List<({String sha256, bool androidDebug})>> hostSigners() async => [];
  @override
  Future<String> connect({
    required String packageName,
    required String serviceClass,
    required String pluginId,
    required String sha256,
  }) async {
    if (connectError != null) throw connectError!;
    connects.add(packageName);
    connected.add(packageName);
    return '';
  }

  @override
  Future<int> ping(String packageName, int nonce) async {
    if (!connected.contains(packageName)) {
      throw const PluginBridgeException('NOT_CONNECTED', '没有连着这个插件');
    }
    return nonce;
  }

  @override
  Future<void> disconnect(String packageName) async {
    disconnects.add(packageName);
    connected.remove(packageName);
  }

  @override
  Future<void> openSettings(String packageName, String activity) async =>
      settingsOpened.add(activity);

  @override
  Future<void> openSession({
    required String packageName,
    required String handle,
    required int generation,
    required int cols,
    required int rows,
    String? moshHost,
    int? moshPort,
    Uint8List? moshKey,
  }) async {
    if (openError != null) throw openError!;
    opened.add((
      package: packageName,
      handle: handle,
      generation: generation,
      cols: cols,
      rows: rows,
    ));
  }

  @override
  Future<void> writeSession(String packageName, String handle, int generation,
          Uint8List bytes) async =>
      writes.add(utf8.decode(bytes));
  @override
  Future<void> resizeSession(String packageName, String handle, int generation,
          int cols, int rows) async =>
      resizes.add('${cols}x$rows');
  @override
  Future<bool> closeSession(
      String packageName, String handle, int generation) async {
    closed.add(handle);
    return true;
  }

  @override
  Future<void> ackSession(
      String packageName, String handle, int generation) async {}
}

/// 一个第三方终端插件的安装包（系统报告的样子）。
DiscoveredPackage terminalPlugin({
  required String package,
  required String pluginId,
  String displayName = 'Hello 终端（样例）',
  String cert = 'author-cert',
  List<String> capabilities = const ['terminal-session'],
  List<String> permissions = const ['own-session-input-output'],
  String? settingsActivity,
}) =>
    DiscoveredPackage(
      packageName: package,
      serviceClass: '$package.ProviderService',
      versionName: '0.1.0',
      versionCode: 1,
      settingsActivity: settingsActivity,
      signers: [(sha256: cert, androidDebug: false)],
      descriptorJson: jsonEncode({
        'schemaVersion': 1,
        'pluginId': pluginId,
        'displayName': displayName,
        'version': '0.1.0',
        'apiMajor': 1,
        'apiMinor': 0,
        'deployment': 'android-service',
        'capabilities': capabilities,
        'supportedRoutes': ['system-default'],
        'platforms': ['android'],
        'permissions': permissions,
        'packageName': package,
        'serviceClass': '$package.ProviderService',
      }),
    );
