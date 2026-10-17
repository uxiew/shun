import 'package:plugin_api/plugin_api.dart' show AdmissionPolicy;

/// 所有者登记的「官方插件」：pluginId → 只认的签名证书 SHA-256（X12，所有者 2026-10-07 决定）。
///
/// 登记了的 ID，别的证书签的安装包自称它，准入时直接「已拒绝」，不给批准选项
/// （[AdmissionPolicy.reservedOfficialIds]）。真插件照常要用户批准一次。
///
/// 为什么要登记 Mosh：Mosh 连接只按 pluginId 找插件、把这次会话的一次性 key 和 UDP 目标交给它。
/// 不登记的话，别的包自称 `shun.mosh`、用户又在批准框里批了它的证书，key 就到了它手里。
///
/// **以后 Mosh 插件换正式签名，必须同步改这里**：现在登记的是 `plugins/mosh` 用的测试作者证书
/// （仓库外 `.toolchain/plugin-keys/fixture-author.jks`）。正式签名的 Mosh 插件装上后，证书不在这里，
/// 就会被当成冒充者拒掉、连不了 Mosh。证书从实际安装包读，别抄：
/// `apksigner verify --print-certs plugins/mosh/build/outputs/apk/release/mosh-release.apk`。
///
/// 已知局限：这把测试作者密钥还给 `plugins/fixture-*` 下的测试插件签名，用它签、自称 `shun.mosh` 的包照样过这道关。
/// 挡得住的是「别的密钥签的冒充者」。
abstract final class OfficialPlugins {
  /// Mosh 插件的 pluginId，和 `PluginMoshRuntime.pluginId` 相同（有测试核对）。
  static const moshPluginId = 'shun.mosh';

  /// `plugins/mosh` 现在的签名证书：`CN=shun fixture author, O=shun test only`。
  /// 这把测试作者密钥 2026-10-15 在本机重新生成过（原来那把 `ffb53d5a…` 没跟着迁移过来），
  /// 所有者 2026-10-17 决定改认新钥匙。同日从重新编的 mosh-release.apk 用 apksigner 读出。
  /// 用旧钥匙签的 Mosh 插件包从此会被当成冒充者拒掉：手机上装着旧包的，卸掉重装新包。
  static const moshTestAuthorCertSha256 =
      '7feb58259ea7ca210fc268f8df42ed4bd378ae04be2c270e31c559d6180e6e9d';

  static const reserved = <String, Set<String>>{
    moshPluginId: {moshTestAuthorCertSha256},
  };
}
