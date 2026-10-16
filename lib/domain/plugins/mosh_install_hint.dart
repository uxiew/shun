/// 服务器上没有 mosh-server 时给的安装提示（R42）。
///
/// 只读服务器的 `/etc/os-release` 认发行版，给出下面表里**写死**的一条安装命令：远端发来的内容只用来选哪一条，
/// 一个字都不进命令。本 App 不替用户执行、不用 sudo：用户复制，或者填进自己的 SSH 标签（不回车）、
/// 看过了自己按回车。命令照 mosh.org 「Getting Mosh」写；那里没列的发行版在 [MoshInstallHint.note] 里说明来源。
library;

import 'mosh_bootstrap.dart';

/// 远端没有 mosh-server（[MoshBootstrapFailure.serverMissing]），带着按这台服务器的 os-release 选好的安装提示。
/// 是 [MoshBootstrapException] 的一种：只认失败类型的地方（失败页提示、恢复策略）照旧。
class MoshServerMissing extends MoshBootstrapException {
  const MoshServerMissing(this.hint)
      : super(MoshBootstrapFailure.serverMissing);

  final MoshInstallHint hint;
}

/// `/etc/os-release` 里认发行版要用的几项。
class OsRelease {
  const OsRelease({
    required this.id,
    this.idLike = const [],
    this.prettyName = '',
  });

  /// `ID`，小写，只含 `a-z 0-9 . _ -`；不合规矩时为空串。
  final String id;

  /// `ID_LIKE` 拆开的各项，规则同 [id]。
  final List<String> idLike;

  /// `PRETTY_NAME`（没有就用 `NAME`），只给人看：去掉了控制字符和双向文字控制符，截到 80 字。
  final String prettyName;
}

/// 只读 os-release 的固定命令。超过 4 KiB 的部分不要。不经 `sh -c`：一条普通命令在 fish、csh 里也一样跑。
const osReleaseCommand = 'head -c 4096 /etc/os-release';

/// 按 os-release(5) 的写法解析：`KEY=value`，value 可以用单双引号包着。认不出 `ID` 返回 null。
OsRelease? parseOsRelease(String raw) {
  final values = <String, String>{};
  for (final line in raw.split('\n')) {
    final text = line.trim();
    if (text.isEmpty || text.startsWith('#')) continue;
    final at = text.indexOf('=');
    if (at <= 0) continue;
    final key = text.substring(0, at);
    if (!const {'ID', 'ID_LIKE', 'PRETTY_NAME', 'NAME'}.contains(key)) {
      continue;
    }
    var value = text.substring(at + 1);
    if (value.length >= 2 &&
        (value.startsWith('"') && value.endsWith('"') ||
            value.startsWith("'") && value.endsWith("'"))) {
      value = value.substring(1, value.length - 1);
    }
    values.putIfAbsent(key, () => value);
  }
  final id = _token(values['ID'] ?? '');
  if (id.isEmpty) return null;
  return OsRelease(
    id: id,
    idLike: [
      for (final part in (values['ID_LIKE'] ?? '').split(RegExp(r'\s+')))
        if (_token(part) case final token when token.isNotEmpty) token,
    ],
    prettyName: _display(values['PRETTY_NAME'] ?? values['NAME'] ?? ''),
  );
}

String _token(String value) {
  final lower = value.trim().toLowerCase();
  return RegExp(r'^[a-z0-9._-]{1,40}$').hasMatch(lower) ? lower : '';
}

String _display(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    if (buffer.length >= 80) {
      buffer.write('…');
      break;
    }
    final control = rune < 0x20 || rune == 0x7f || (rune >= 0x80 && rune < 0xa0);
    final bidi = (rune >= 0x202a && rune <= 0x202e) ||
        (rune >= 0x2066 && rune <= 0x2069) ||
        rune == 0x200e ||
        rune == 0x200f;
    if (!control && !bidi) buffer.writeCharCode(rune);
  }
  return buffer.toString().trim();
}

/// 给用户看的安装提示。[command] 为 null 表示没有一条能直接跑的命令（没认出发行版，或者要改系统配置，如 NixOS）。
class MoshInstallHint {
  const MoshInstallHint({
    required this.distro,
    this.command,
    this.asRoot = false,
    this.note,
  });

  /// 认出来的发行版，给人看；没认出时是「没认出的系统」。
  final String distro;

  /// 要用户自己在服务器上执行的那一条。本 App 从不替用户执行它。
  final String? command;

  /// mosh.org 上这条写的是 `#` 提示符：要用 root 执行（或自己在前面加 sudo / doas）。
  final bool asRoot;

  /// 补充说明：命令从哪来、要注意什么。
  final String? note;
}

class _Family {
  const _Family(this.ids, this.command, {this.asRoot = false, this.note});
  final Set<String> ids;
  final String? command;
  final bool asRoot;
  final String? note;
}

/// 顺序要紧：先按 `ID` 在整张表里找，再按 `ID_LIKE` 的顺序找。Rocky 的 `ID_LIKE` 是 「rhel centos fedora」，
/// 不先看 `ID` 的话会被当成 Fedora，而它的 mosh 在 EPEL 里。
const _families = [
  _Family({'debian', 'ubuntu'}, 'sudo apt-get install mosh'),
  _Family({'fedora'}, 'sudo dnf install mosh'),
  _Family(
    {'rhel', 'centos', 'rocky', 'almalinux', 'ol', 'amzn'},
    'sudo dnf install epel-release && sudo dnf install mosh',
    note: 'mosh.org 没列这一系；CentOS / Rocky / Alma 的 mosh 在 EPEL 里。'
        'RHEL 本体的 epel-release 不在默认源，先按 EPEL 官方说明启用 EPEL 再装。',
  ),
  _Family({'arch'}, 'pacman -S mosh', asRoot: true),
  _Family({'suse', 'opensuse', 'sles'}, 'sudo zypper in mosh'),
  _Family({'alpine'}, 'apk add mosh', asRoot: true),
  _Family({'gentoo'}, 'emerge net-misc/mosh', asRoot: true),
  _Family(
    {'void'},
    'xbps-install -S mosh',
    asRoot: true,
    note: 'mosh.org 没列 Void；这是 Void 仓库里 mosh 包的装法。',
  ),
  _Family({'freebsd'}, 'pkg install net/mosh', asRoot: true),
  _Family({'guix'}, 'guix package -i mosh'),
  _Family(
    {'nixos'},
    null,
    note: 'NixOS 不建议用命令临时装：在 configuration.nix 里加 programs.mosh.enable = true;，'
        '再 sudo nixos-rebuild switch（它会顺带放行 Mosh 的 UDP 端口）。',
  ),
];

/// [os] 为 null：服务器没有 `/etc/os-release`，或者认不出来。
MoshInstallHint moshInstallHint(OsRelease? os) {
  if (os == null) {
    return const MoshInstallHint(
      distro: '没认出的系统',
      note: '服务器上没有 /etc/os-release，或者认不出是哪个发行版。用它自己的包管理器装 mosh，包名一般就叫 mosh。',
    );
  }
  final name = os.prettyName.isEmpty ? os.id : os.prettyName;
  for (final token in [os.id, ...os.idLike]) {
    for (final family in _families) {
      if (family.ids.contains(token) ||
          (family.ids.contains('opensuse') && token.startsWith('opensuse'))) {
        return MoshInstallHint(
          distro: name,
          command: family.command,
          asRoot: family.asRoot,
          note: family.note,
        );
      }
    }
  }
  return MoshInstallHint(
    distro: name,
    note: '没有这个发行版的现成命令。用它自己的包管理器装 mosh，包名一般就叫 mosh。',
  );
}
