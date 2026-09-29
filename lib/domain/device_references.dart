import 'package:plugin_api/plugin_api.dart';

import 'models/host.dart';
import 'plugins/builtin_plugins.dart';

/// 保险库里一台主机对应的设备引用。
///
/// 身份只是主机 id：改名、换地址、换协议都还是同一条引用。名字和地址只用于展示，
/// 另一个 provider（Tailscale 目录、UU、RustDesk）报出同名同 IP 也不会因此合并（DEV01）。
ProviderDeviceRef hostDeviceRef(HostProfile host) => ProviderDeviceRef(
      providerId: BuiltinPlugins.ssh,
      refId: host.id,
      displayName: host.label,
      addresses: [if (host.hostname.isNotEmpty) host.hostname],
    );

/// 一条设备引用此刻能不能用。provider 不可用时引用和它的设置都还在，等用户修复或手动断开（DEV02）。
enum DeviceRefAvailability {
  available,

  /// provider 装着但没批准、被停用、被拒绝或描述符不合规。
  providerNotReady,

  /// provider 被卸载，或从来没装过（比如从备份恢复了关联）。
  providerMissing,
}
