import 'dart:async';

import 'package:netcatty_mobile/application/external_remote.dart';
import 'package:netcatty_mobile/infrastructure/plugins/uuremote_adapter.dart';

// X06 测试共用：假平台（记下发出的 URI、手动喂回调）和内存存储。

class FakePlatform implements UuRemotePlatform {
  UuProbe probeResult = const UuProbe(
    platformSupported: true,
    officialInstalled: true,
    officialHandlesScheme: true,
    versionName: '4.42.0',
    signers: {'cert-a'},
  );
  final launched = <String>[];
  final signersUsed = <String>[];
  String? failLaunch;
  final _callbacks = StreamController<String>.broadcast();

  void deliver(String raw) => _callbacks.add(raw);

  @override
  Stream<String> get callbacks => _callbacks.stream;

  @override
  Future<UuProbe> probe() async => probeResult;

  @override
  Future<void> launch(String uri, {required String signer}) async {
    if (failLaunch != null) throw UuLaunchFailed(failLaunch!);
    launched.add(uri);
    signersUsed.add(signer);
  }
}

class MemoryBackend implements ProviderSecretBackend {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}
