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

enum HostKeyStatus { trusted, unknown, changed }

/// 查 [knownHosts] 里 [hostname]:[port] 的记录，和这次拿到的指纹比对。
({HostKeyStatus status, Map<String, dynamic>? existing}) checkHostKey(
  List<Map<String, dynamic>> knownHosts, {
  required String hostname,
  required int port,
  required String keyType,
  required String fingerprint,
}) {
  final existing = knownHosts
      .where((entry) =>
          entry['hostname'] == hostname &&
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
