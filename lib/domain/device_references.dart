import 'package:plugin_api/plugin_api.dart';

import 'models/host.dart';
import 'plugins/builtin_plugins.dart';

/// 保险库里一台主机对应的设备引用。
///
/// 身份只是主机 id：改名、换地址、换协议都还是同一条引用。名字和地址只用于展示，
/// 另一个 provider（Tailscale 目录、UU、RustDesk）报出同名同 IP 也不会因此合并（DEV01）。
ProviderDeviceRef hostDeviceRef(HostProfile host) => sshHostRef(
      host.id,
      displayName: host.label,
      hostname: host.hostname,
    );

/// 同 [hostDeviceRef]，给手里只有主机 id、名字、地址的地方用（目录 provider 看不到整条主机记录）。
ProviderDeviceRef sshHostRef(
  String hostId, {
  required String displayName,
  String hostname = '',
}) =>
    ProviderDeviceRef(
      providerId: BuiltinPlugins.ssh,
      refId: hostId,
      displayName: displayName,
      addresses: [if (hostname.isNotEmpty) hostname],
    );

final _catalogId = RegExp(r'^[A-Za-z0-9-]{1,64}$');

/// 本机给 Tailscale 目录来源起的 ID（不是 tailnet 名）。
///
/// 缓存文件名、目录凭据的存储键、主机上的目录绑定、设备引用都用它，规则只写在这一处：
/// 各写一份的话，迟早有一处收了另一处不认的字符，关联就对不上缓存或凭据。
/// 只允许字母数字和连字符，所以拼不出路径，也拼不出别的来源的凭据键，更不含 [catalogRefKey] 的分隔符。
bool isValidCatalogId(String id) => _catalogId.hasMatch(id);

/// Tailscale 目录里一台设备的引用。身份是（来源 ID，设备 ID）：两个来源报出同一个设备 ID
/// 也是两条引用——列设备接口不返回 tailnet 标识，App 无法确认两个来源是不是同一个 tailnet（TSC10）。
ProviderDeviceRef catalogDeviceRef(
  String catalogId,
  String deviceId, {
  String? displayName,
  List<String> addresses = const [],
}) {
  if (!isValidCatalogId(catalogId) || deviceId.isEmpty) {
    throw ArgumentError('目录设备引用无效');
  }
  return ProviderDeviceRef(
    providerId: BuiltinPlugins.tailscale,
    refId: '$catalogId:$deviceId',
    displayName: displayName ?? deviceId,
    addresses: addresses,
  );
}

/// 一条 UU 远程绑定的引用。身份是本 App 给这条绑定起的 ID，**不是** UU 返回的加密设备标识：
/// 那是敏感的不透明值，只存在 UU 绑定自己的安全存储里，不出现在引用、日志或关联里（docs/17）。
ProviderDeviceRef uuBindingRef(String bindingId, {String? displayName}) =>
    ProviderDeviceRef(
      providerId: BuiltinPlugins.uuremote,
      refId: bindingId,
      displayName: displayName ?? 'UU',
    );

/// 一条 RustDesk 关联的引用。身份是本 App 给这条关联起的 ID，不是 RustDesk ID：
/// 两台主机（比如同一台电脑的两个 SSH 账号）可以各自填同一个 RustDesk ID，它们仍是两条引用，
/// 不会因为 ID 相同就被并成一台设备（DEV01）。
ProviderDeviceRef rustDeskPeerRef(String linkId, {String? displayName}) =>
    ProviderDeviceRef(
      providerId: BuiltinPlugins.rustdesk,
      refId: linkId,
      displayName: displayName ?? 'RustDesk',
    );

/// [catalogDeviceRef] 的反向：不是目录引用、或格式不对返回 null。
/// 来源 ID 里不会有冒号，所以按第一个冒号切；设备 ID 里有冒号也不会切错。
({String catalogId, String deviceId})? catalogRefKey(ProviderDeviceRef ref) {
  if (ref.providerId != BuiltinPlugins.tailscale) return null;
  final at = ref.refId.indexOf(':');
  if (at <= 0 || at == ref.refId.length - 1) return null;
  final catalogId = ref.refId.substring(0, at);
  if (!isValidCatalogId(catalogId)) return null;
  return (catalogId: catalogId, deviceId: ref.refId.substring(at + 1));
}

/// 一条设备引用此刻能不能用。provider 不可用时引用和它的设置都还在，等用户修复或手动断开（DEV02）。
enum DeviceRefAvailability {
  available,

  /// provider 装着但没批准、被停用、被拒绝或描述符不合规。
  providerNotReady,

  /// provider 被卸载，或从来没装过（比如从备份恢复了关联）。
  providerMissing,
}
