/// 服务器上没有 mosh-server 时给的安装提示（R42）。
///
/// 只读服务器的 `/etc/os-release` 认发行版，给出下面表里**写死**的安装、卸载命令：远端发来的内容只用来选哪一条，
/// 一个字都不进命令。用户可以复制、填进自己的 SSH 标签（不回车），或者确认后让 App 新开一个 SSH 标签去执行
///（所有者 2026-10-17 同意的）。就算是 App 执行，sudo 的密码也是用户在那个终端里自己输，App 不经手。
/// 命令照 mosh.org 「Getting Mosh」写；那里没列的发行版、以及卸载命令，照各发行版自己的包管理器写，来源在 [MoshInstallHint.note]。
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
    final control =
        rune < 0x20 || rune == 0x7f || (rune >= 0x80 && rune < 0xa0);
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
    this.uninstall,
    this.asRoot = false,
    this.note,
  });

  /// 认出来的发行版，给人看；没认出时是「没认出的系统」。
  final String distro;

  /// 安装 mosh 的那一条，写法和 mosh.org 一样（带不带 sudo 照原样）。真要执行时用 [runAs] 按登录用户调整。
  final String? command;

  /// 以后不用了、卸掉 mosh 的那一条；和 [command] 一样要 [runAs] 调整。
  final String? uninstall;

  /// mosh.org 上这条写的是 `#` 提示符：要用 root 执行。
  final bool asRoot;

  /// 补充说明：命令从哪来、要注意什么。
  final String? note;

  /// 按登录用户把 [command] 或 [uninstall] 改成能直接跑的样子：
  /// - 用 root 登录：去掉 sudo。精简系统（容器、最小安装的 Debian/Alpine）的 root 常常没有 sudo，
  ///   留着反而报 `sudo: not found`。
  /// - 普通用户登录、这条要 root（[asRoot]）：每一段前面加 sudo。服务器上没有 sudo 的会报错，要用 root 登录或自己换 doas。
  /// `&&` 连着的每一段各自处理；没有这条（null）就返回 null。
  String? runAs(String? which, {required String user}) {
    if (which == null) return null;
    final root = user == 'root';
    return [
      for (final part in which.split(' && '))
        if (part.startsWith('sudo ') || asRoot)
          root
              ? part.replaceFirst(RegExp(r'^sudo '), '')
              : 'sudo ${part.replaceFirst(RegExp(r'^sudo '), '')}'
        else
          part,
    ].join(' && ');
  }
}

class _Family {
  const _Family(
    this.ids,
    this.command,
    this.uninstall, {
    this.asRoot = false,
    this.note,
  });
  final Set<String> ids;
  final String? command;
  final String? uninstall;
  final bool asRoot;
  final String? note;
}

/// 顺序要紧：先按 `ID` 在整张表里找，再按 `ID_LIKE` 的顺序找。Rocky 的 `ID_LIKE` 是 「rhel centos fedora」，
/// 不先看 `ID` 的话会被当成 Fedora，而它的 mosh 在 EPEL 里。
///
/// 卸载只卸 mosh 这一个包。装它时顺带装上、别的程序都不用的依赖，清不清由用户定（使用指南里写了各家怎么清）：
/// 一条命令替用户删别的包，比少删几个依赖代价大。
const _families = [
  _Family({'debian', 'ubuntu'}, 'sudo apt-get install mosh',
      'sudo apt-get remove mosh'),
  _Family({'fedora'}, 'sudo dnf install mosh', 'sudo dnf remove mosh'),
  _Family(
    {'rhel', 'centos', 'rocky', 'almalinux', 'ol', 'amzn'},
    'sudo dnf install epel-release && sudo dnf install mosh',
    'sudo dnf remove mosh',
    note: 'mosh.org 没列这一系；CentOS / Rocky / Alma 的 mosh 在 EPEL 里。'
        'RHEL 本体的 epel-release 不在默认源，先按 EPEL 官方说明启用 EPEL 再装。',
  ),
  _Family({'arch'}, 'pacman -S mosh', 'pacman -R mosh', asRoot: true),
  _Family({'suse', 'opensuse', 'sles'}, 'sudo zypper in mosh',
      'sudo zypper rm mosh'),
  _Family({'alpine'}, 'apk add mosh', 'apk del mosh', asRoot: true),
  _Family(
    {'gentoo'},
    'emerge net-misc/mosh',
    'emerge --deselect net-misc/mosh && emerge --depclean net-misc/mosh',
    asRoot: true,
  ),
  _Family(
    {'void'},
    'xbps-install -S mosh',
    'xbps-remove mosh',
    asRoot: true,
    note: 'mosh.org 没列 Void；这是 Void 仓库里 mosh 包的装法。',
  ),
  _Family({'freebsd'}, 'pkg install net/mosh', 'pkg delete mosh', asRoot: true),
  _Family({'guix'}, 'guix package -i mosh', 'guix package -r mosh'),
  _Family(
    {'nixos'},
    null,
    null,
    note: 'NixOS 不建议用命令临时装：在 configuration.nix 里加 programs.mosh.enable = true;，'
        '再 sudo nixos-rebuild switch（它会顺带放行 Mosh 的 UDP 端口）。不用了就删掉这一行、再 rebuild 一次。',
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
          uninstall: family.uninstall,
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
