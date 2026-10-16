// R41：引导命令在各种登录 shell 里真的跑一遍。远端用户的登录 shell 可能是 bash、zsh、dash、csh、ksh，
// 它们先解释整条命令、再把单引号里的脚本交给 sh。这里用假的 mosh-server（只打印参数和一行 MOSH CONNECT），
// 看自动探测的顺序、~/ 展开、locale 和端口参数、找不到时的报错是否在每种 shell 下都一样。
// 真 mosh-server 在 tool/mosh-fixture 里测（test/mosh_fixture_test.dart）。
@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/plugins/mosh_bootstrap.dart';
import 'package:shun/domain/tmux/tmux_target.dart';

const _key = 'v450/k6rhyS3hwDL4ejCIQ';

final _shells = [
  '/bin/sh',
  '/bin/bash',
  '/bin/zsh',
  '/bin/dash',
  '/bin/ksh',
  '/bin/csh',
  '/bin/tcsh',
  '/usr/bin/fish',
  '/opt/homebrew/bin/fish',
].where((path) => File(path).existsSync()).toList();

/// 自动探测里排在 ~/.local/bin 前面、本机又真有 mosh-server 的位置；有的话「探测到 HOME」那条没法验。
final _hostMoshServer = MoshBootstrap.probeLocations
    .takeWhile((path) => !path.startsWith(r'$HOME'))
    .where((path) => File(path).existsSync())
    .toList();

void main() {
  late Directory root;
  late String home;
  late String pathBin;

  Future<void> fake(String path, String marker) async {
    await File(path).parent.create(recursive: true);
    await File(path).writeAsString(
      '#!/bin/sh\n'
      'echo "$marker ARGS:\$*" >&2\n'
      'echo "MOSH CONNECT 60001 $_key"\n',
    );
    await Process.run('chmod', ['755', path]);
  }

  Future<({String output, int exitCode})> run(String shell, String command,
      {bool withPathBin = false}) async {
    final result = await Process.run(
      shell,
      ['-c', command],
      environment: {
        'HOME': home,
        // 只留系统目录：本机真装了 mosh 的 Homebrew 目录不进 PATH。
        'PATH': [if (withPathBin) pathBin, '/usr/bin', '/bin'].join(':'),
      },
      includeParentEnvironment: false,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    return (
      output: '${result.stdout}${result.stderr}',
      exitCode: result.exitCode,
    );
  }

  MoshBootstrapResult parse(String output) =>
      MoshBootstrap.parse(Uint8List.fromList(utf8.encode(output)));

  setUp(() async {
    root = await Directory.systemTemp.createTemp('shun-mosh-script-');
    home = '${root.path}/home';
    pathBin = '${root.path}/pathbin';
    await Directory(home).create();
  });

  tearDown(() => root.delete(recursive: true));

  test('本机至少有 sh 和另一种登录 shell 可测', () {
    expect(_shells, contains('/bin/sh'));
    expect(_shells.length, greaterThan(1));
  });

  for (final shell in _shells) {
    group(shell, () {
      test('自动：PATH 里有就用 PATH 的，即使常见位置也有', () async {
        await fake('$pathBin/mosh-server', 'PATH');
        await fake('$home/.local/bin/mosh-server', 'HOME');
        final r = await run(shell, MoshBootstrap.command(), withPathBin: true);
        expect(
            r.output,
            contains(
                'PATH ARGS:new -s -c 256 -l LANG=en_US.UTF-8 -p 60001:60999'));
        expect(r.output, isNot(contains('HOME ARGS')));
        expect(parse(r.output).port, 60001);
      });

      test('自动：PATH 里没有就按固定顺序找到 ~/.local/bin', () async {
        await fake('$home/.local/bin/mosh-server', 'HOME');
        await fake('$home/.nix-profile/bin/mosh-server', 'NIX');
        final r = await run(shell, MoshBootstrap.command(locale: 'C.UTF-8'));
        expect(r.output,
            contains('HOME ARGS:new -s -c 256 -l LANG=C.UTF-8 -p 60001:60999'));
        expect(r.output, isNot(contains('NIX ARGS')));
      },
          skip: _hostMoshServer.isEmpty
              ? false
              : '本机已有 $_hostMoshServer，排在 ~/.local/bin 前面');

      test('自动：哪里都没有就报「没装」，退出码 127', () async {
        final r = await run(shell, MoshBootstrap.command());
        expect(r.exitCode, _hostMoshServer.isEmpty ? 127 : isNot(127));
        if (_hostMoshServer.isEmpty) {
          expect(
              () => parse(r.output),
              throwsA(isA<MoshBootstrapException>().having((e) => e.failure,
                  'failure', MoshBootstrapFailure.serverMissing)));
        }
      }, skip: _hostMoshServer.isEmpty ? false : '本机已有 $_hostMoshServer');

      test('指定 ~/ 路径：由远端 HOME 展开；不走自动探测', () async {
        await fake('$pathBin/mosh-server', 'PATH');
        await fake('$home/opt/mosh/bin/mosh-server', 'CUSTOM');
        final r = await run(
          shell,
          MoshBootstrap.command(
            serverPath: '~/opt/mosh/bin/mosh-server',
            locale: 'sr_RS.UTF-8@latin',
            portRange: (60001, 60010),
          ),
          withPathBin: true,
        );
        expect(
            r.output,
            contains(
                'CUSTOM ARGS:new -s -c 256 -l LANG=sr_RS.UTF-8@latin -p 60001:60010'));
        expect(r.output, isNot(contains('PATH ARGS')));
      });

      test('指定绝对路径：原样执行', () async {
        final path = '${root.path}/abs/mosh-server';
        await fake(path, 'ABS');
        final r = await run(shell, MoshBootstrap.command(serverPath: path));
        expect(r.output, contains('ABS ARGS:new -s -c 256'));
      },
          skip:
              MoshBootstrap.isValidServerPath('${Directory.systemTemp.path}/x')
                  ? false
                  : '临时目录路径含白名单外的字符');

      test('指定路径不存在或不能执行：报「路径不对」，不回退到自动探测', () async {
        await fake('$pathBin/mosh-server', 'PATH');
        await File('$home/plain').writeAsString('not executable');
        for (final path in ['~/missing/mosh-server', '~/plain', '~/.']) {
          if (!MoshBootstrap.isValidServerPath(path)) continue;
          final r = await run(shell, MoshBootstrap.command(serverPath: path),
              withPathBin: true);
          expect(r.exitCode, 126, reason: path);
          expect(r.output, isNot(contains('PATH ARGS')), reason: path);
          expect(
              () => parse(r.output),
              throwsA(isA<MoshBootstrapException>().having((e) => e.failure,
                  'failure', MoshBootstrapFailure.serverPathMissing)),
              reason: path);
        }
        // 目录也不算能执行的 mosh-server。
        await Directory('$home/dir').create();
        final r = await run(shell, MoshBootstrap.command(serverPath: '~/dir'));
        expect(r.exitCode, 126);
      });

      // R42：附着 tmux 的变体。假 tmux 只会回 display-message（打印 $HOME/guard 里的串），
      // 假 mosh-server 只打印参数：看核对不过时根本不起 mosh-server，过了时 `--` 后面是按 ID 的 attach。
      group('附着 tmux（R42）', () {
        late ServerSocket socket;
        late String socketPath;
        late int uid;
        const guard = r'$3:4242:1700000000:1700000100';

        TmuxTarget target({int? asUid, String? path}) => TmuxTarget(
              hostKey: '127.0.0.1:22',
              unixUser: 'me',
              uid: asUid ?? uid,
              socket: TmuxSocketSpec.path(path ?? socketPath),
              server: TmuxServerIdentity(
                  socketPath: path ?? socketPath,
                  pid: 4242,
                  startTime: 1700000000),
              sessionId: r'$3',
              sessionCreated: 1700000100,
              displayName: 'work',
            );

        setUp(() async {
          uid = int.parse(
              ((await Process.run('id', ['-u'])).stdout as String).trim());
          socketPath = '${root.path}/s';
          socket = await ServerSocket.bind(
              InternetAddress(socketPath, type: InternetAddressType.unix), 0);
          await fake('$pathBin/mosh-server', 'PATH');
          await File('$pathBin/tmux').writeAsString(
            '#!/bin/sh\n'
            'case "\$*" in *display-message*) cat "\$HOME/guard";; *) echo "TMUX RAN \$*" >&2;; esac\n',
          );
          await Process.run('chmod', ['755', '$pathBin/tmux']);
          await File('$home/guard').writeAsString('$guard\n');
        });

        tearDown(() => socket.close());

        test('核对过了：mosh-server 的子进程是按会话 ID 的 attach，不带 -d、不经 shell', () async {
          final r = await run(shell, MoshBootstrap.command(tmux: target()),
              withPathBin: true);
          expect(r.exitCode, 0, reason: r.output);
          expect(
              r.output,
              contains('PATH ARGS:new -s -c 256 -l LANG=en_US.UTF-8 -p 60001:60999 '
                  '-- $pathBin/tmux -u -S $socketPath attach-session -t \$3'));
          expect(r.output, isNot(contains('TMUX RAN')),
              reason: '核对只调 display-message，附着由 mosh-server 的子进程做');
          expect(parse(r.output).port, 60001);
        });

        test('换了用户：退出 96，mosh-server 一次都不起', () async {
          final r = await run(
              shell, MoshBootstrap.command(tmux: target(asUid: uid + 1)),
              withPathBin: true);
          expect(r.exitCode, 96);
          expect(r.output, isNot(contains('ARGS:')));
        });

        test('socket 不在 / 会话换了（同名重建、server 重启）：退出 97，不起、不建', () async {
          final gone = await run(
              shell,
              MoshBootstrap.command(tmux: target(path: '${root.path}/none')),
              withPathBin: true);
          expect(gone.exitCode, 97);
          expect(gone.output, isNot(contains('ARGS:')));
          for (final other in [
            r'$3:4242:1700000000:1700000999', // 同号新会话
            r'$3:5555:1700000500:1700000100', // server 换了一代
            '', // 3.5a 找不到目标时只输出空字段
          ]) {
            await File('$home/guard').writeAsString('$other\n');
            final r = await run(shell, MoshBootstrap.command(tmux: target()),
                withPathBin: true);
            expect(r.exitCode, 97, reason: other);
            expect(r.output, isNot(contains('ARGS:')), reason: other);
          }
        });

        test('服务器没有 tmux：退出 95', () async {
          await File('$pathBin/tmux').delete();
          final r = await run(shell, MoshBootstrap.command(tmux: target()),
              withPathBin: true);
          expect(r.exitCode, 95);
          expect(r.output, isNot(contains('ARGS:')));
        },
            skip: ['/usr/bin/tmux', '/bin/tmux'].any((p) => File(p).existsSync())
                ? '本机系统目录里有 tmux'
                : false);
      },
          skip: MoshBootstrap.isValidServerPath('${Directory.systemTemp.path}/x')
              ? false
              : '临时目录路径含白名单外的字符');
    });
  }
}
