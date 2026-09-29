/// 主机指纹信任：连接时 dartssh2 拿到服务器指纹后调这里，决定放行还是断开。
///
/// 信任记录存在保险库 `extras.knownHosts`（和桌面端同步），按**逻辑主机名 + 端口**记，
/// 不按实际拨出的地址——经代理或跳板时拨的是 127.0.0.1 或代理端口，按那个记就会张冠李戴（SEC01）。
///
/// 三种情况：
/// - 已信任且指纹一致：直接放行，不打扰用户。
/// - 第一次见：必须让用户核对后接受才记住（不自动信任，也不因为「在 Tailnet 里」就信任，SEC03）。
/// - 指纹变了：**一律拒绝**，不给「确认更新」这种一点就过的按钮（SEC02）。
///   用户确认是服务器正常换钥后，只能选择删除旧指纹；这次连接照样断开，
///   重连时按「第一次见」重新核对——相当于 OpenSSH 的先 `ssh-keygen -R` 再连。
library;

import 'dart:io';

enum HostKeyStatus { trusted, unknown, changed }

/// 比对信任记录时主机名的规范写法：去掉首尾空白、IPv6 的方括号、结尾的点，IP 按标准写法，其余转小写。
///
/// 域名不区分大小写，OpenSSH 的 known_hosts 也按小写记。不规范化的话，把「Web.Example.com」
/// 改成「web.example.com」会被当成一台没见过的机器，用户被迫再点一次「信任」，
/// 久了就养成不看指纹直接点的习惯（SEC04）。只做写法上的等价，不做 DNS 解析：
/// 两个不同的名字即使指向同一个 IP，也各自需要核对——别名只能显式建立。
String trustHostName(String hostname) {
  var value = hostname.trim();
  if (value.startsWith('[') && value.endsWith(']')) {
    value = value.substring(1, value.length - 1);
  }
  if (value.endsWith('.')) value = value.substring(0, value.length - 1);
  final address = InternetAddress.tryParse(value);
  // tryParse(...).address 只是把原文还回来；用原始字节重建才是标准写法（0:0::1 → ::1）。
  if (address != null) {
    return InternetAddress.fromRawAddress(address.rawAddress).address;
  }
  return value.toLowerCase();
}

/// 查 [knownHosts] 里 [hostname]:[port] 的记录，和这次拿到的指纹比对。
({HostKeyStatus status, Map<String, dynamic>? existing}) checkHostKey(
  List<Map<String, dynamic>> knownHosts, {
  required String hostname,
  required int port,
  required String keyType,
  required String fingerprint,
}) {
  final name = trustHostName(hostname);
  final existing = knownHosts
      .where((entry) =>
          trustHostName('${entry['hostname'] ?? ''}') == name &&
          ((entry['port'] as num?)?.toInt() ?? 22) == port)
      .firstOrNull;
  if (existing == null) return (status: HostKeyStatus.unknown, existing: null);
  final same =
      existing['fingerprint'] == fingerprint && existing['keyType'] == keyType;
  return (
    status: same ? HostKeyStatus.trusted : HostKeyStatus.changed,
    existing: existing,
  );
}

/// 完整的决定流程。界面相关的动作都由调用方传入，这里只管规则，便于测试：
/// - [confirmNew]：第一次见时让用户核对，返回是否接受。
/// - [onChanged]：指纹变了时告诉用户已阻止，参数是旧指纹；返回用户是否要删除旧指纹。
/// - [save]：写回新的 knownHosts 列表。
///
/// 返回 true 才放行。指纹变了时无论用户点什么都返回 false。
Future<bool> verifyHostKeyWithKnownHosts({
  required List<Map<String, dynamic>> knownHosts,
  required String hostname,
  required int port,
  required String keyType,
  required String fingerprint,
  required Future<bool> Function() confirmNew,
  required Future<bool> Function(String oldFingerprint) onChanged,
  required Future<void> Function(List<Map<String, dynamic>> knownHosts) save,
  DateTime Function() now = DateTime.now,
}) async {
  final check = checkHostKey(
    knownHosts,
    hostname: hostname,
    port: port,
    keyType: keyType,
    fingerprint: fingerprint,
  );
  switch (check.status) {
    case HostKeyStatus.trusted:
      return true;
    case HostKeyStatus.changed:
      final existing = check.existing!;
      if (await onChanged('${existing['fingerprint']}')) {
        await save([
          for (final entry in knownHosts)
            if (!identical(entry, existing)) entry,
        ]);
      }
      return false;
    case HostKeyStatus.unknown:
      if (!await confirmNew()) return false;
      await save([
        ...knownHosts,
        {
          'hostname': hostname,
          'port': port,
          'keyType': keyType,
          'fingerprint': fingerprint,
          'acceptedAt': now().millisecondsSinceEpoch,
        },
      ]);
      return true;
  }
}
