import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/tmux/tmux_target.dart';
import 'package:shun/infrastructure/tmux/tmux_protocol.dart';

// R21：tmux 命令构造和输出解析的纯函数测试。真实 tmux 上的行为见 tmux_fixture_test.dart。
void main() {
  const server = TmuxServerIdentity(
      socketPath: '/tmp/tmux-1000/default', pid: 70, startTime: 1700000000);
  const target = TmuxTarget(
    hostKey: '10.0.0.5:22',
    unixUser: 'alice',
    uid: 1000,
    socket: TmuxSocketSpec.standard(),
    server: server,
    sessionId: r'$3',
    sessionCreated: 1700000100,
    displayName: 'work',
  );
  const sep = tmuxRowSeparator;
  String row(String id,
          {int pid = 70,
          int start = 1700000000,
          int created = 1700000100,
          String name = 'work'}) =>
      ['S', pid, start, id, created, 1, 0, created, 0, 'C-b', '', name]
          .join(sep);

  group('命令构造（SEC11）', () {
    test('每个脚本都能原样放进单引号：不含单引号、!、连续反斜杠和换行', () {
      for (final script in [
        tmuxProbeScript,
        tmuxCreateScript,
        tmuxStartupScript,
        tmuxKillScript,
        tmuxMouseOnScript,
        tmuxMouseUnsetScript,
        tmuxDetachScript,
        tmuxAttachScript,
        tmuxClientByParentScript,
        tmuxClientPresentScript,
      ]) {
        expect(isPortableScript(script), isTrue, reason: script);
      }
    });

    test('R42 的两个只读核对：先核目标身份，只列客户端，不分离、不建、不杀', () {
      for (final script in [
        tmuxClientByParentScript,
        tmuxClientPresentScript
      ]) {
        expect(script, contains(r'[ "$g" = "$4" ] || exit 97'));
        expect(script, contains(r'[ "$(id -u)" = "$3" ] || exit 96'));
        expect(script, contains(r'list-clients -t "$5"'));
        for (final verb in [
          'detach-client',
          'kill-',
          'new-session',
          'attach-session',
          'send-keys',
          'set-option',
        ]) {
          expect(script, isNot(contains(verb)), reason: verb);
        }
      }
      expect(
        tmuxClientByParentCommand(target, 4321),
        endsWith(
            r" shun 'D' '-' '1000' '$3:70:1700000000:1700000100' '$3' '4321'"),
      );
      for (final bad in [1, 0, -5]) {
        expect(
            () => tmuxClientByParentCommand(target, bad), throwsArgumentError,
            reason: '$bad');
      }
      const binding = TmuxClientBinding(
          target: target, clientTty: '/dev/pts/4', clientPid: 88);
      expect(
        tmuxClientPresentCommand(binding),
        endsWith(r" '$3' '/dev/pts/4' '88'"),
      );
      expect(
        () => tmuxClientPresentCommand(const TmuxClientBinding(
            target: target, clientTty: '/dev/pts/4; id', clientPid: 88)),
        throwsArgumentError,
      );
    });

    test('按父进程找到的客户端：只认 M 行，终端和 pid 不合规矩的丢掉', () {
      expect(
        parseClientsByParent('M\t/dev/pts/7\t991\n'
            'M\t/dev/pts/7; id\t992\n'
            'M\t/dev/pts/8\t0\n'
            'M\t/dev/pts/9\tabc\n'
            'X\t/dev/pts/1\t5\n'
            'M\t/dev/ttys004\t12\textra\n'
            'garbage\n'),
        [(tty: '/dev/pts/7', pid: 991)],
      );
      expect(parseClientsByParent(''), isEmpty);
    });

    test('会话操作一律按 ID、先核对身份；附着不带 -d、带 -u；没有一处按名字', () {
      for (final script in [
        tmuxStartupScript,
        tmuxKillScript,
        tmuxMouseOnScript,
        tmuxMouseUnsetScript,
        tmuxDetachScript,
        tmuxAttachScript,
      ]) {
        expect(script, contains(r'[ "$g" = "$4" ] || exit 97'));
        expect(script, contains(r'[ "$(id -u)" = "$3" ] || exit 96'));
        expect(script, isNot(contains('=work')));
      }
      expect(tmuxKillScript, endsWith(r'kill-session -t "$5"'));
      expect(tmuxAttachScript,
          endsWith(r'exec tmux -u -S "$s" attach-session -t "$5"'));
      expect(tmuxAttachScript, isNot(contains('attach-session -d')));
      expect(tmuxAttachScript, isNot(contains('mouse')));
      expect(tmuxProbeScript, isNot(contains('new-session')));
      expect(tmuxProbeScript, isNot(contains('start-server')));
    });

    test('参数都按白名单进单引号；ID、tty 不合规就不构造命令', () {
      expect(
        tmuxKillCommand(target),
        endsWith(r" shun 'D' '-' '1000' '$3:70:1700000000:1700000100' '$3'"),
      );
      expect(
        tmuxProbeCommand(TmuxSocketSpec.path('/run/user/1000/tmux.sock')),
        endsWith(" shun 'S' '/run/user/1000/tmux.sock'"),
      );
      TmuxTarget withId(String id) => TmuxTarget(
            hostKey: target.hostKey,
            unixUser: target.unixUser,
            uid: target.uid,
            socket: target.socket,
            server: target.server,
            sessionId: id,
            sessionCreated: target.sessionCreated,
            displayName: target.displayName,
          );
      for (final id in ['work', r"$3'; rm -rf ~; '", r'$3 ', '3', r'$']) {
        expect(() => tmuxKillCommand(withId(id)), throwsArgumentError,
            reason: id);
      }
      for (final tty in ['/dev/pts/1; id', 'not a tty', "/dev/pts/1'"]) {
        expect(
          () => tmuxDetachCommand(
              TmuxClientBinding(target: target, clientTty: tty, clientPid: 5)),
          throwsArgumentError,
          reason: tty,
        );
      }
    });

    test('socket 名和路径的白名单', () {
      expect(TmuxSocketSpec.named('work-1.x').value, 'work-1.x');
      expect(
          TmuxSocketSpec.path('/tmp/a@b+c/x.sock').value, '/tmp/a@b+c/x.sock');
      for (final bad in [
        '',
        '..',
        '.',
        'a/b',
        'a b',
        "a'b",
        r'a$b',
        'x' * 65
      ]) {
        expect(() => TmuxSocketSpec.named(bad), throwsFormatException,
            reason: bad);
      }
      for (final bad in [
        'relative/x',
        '/tmp/x; touch /tmp/pwned',
        '/tmp/../etc/x',
        "/tmp/q'",
        '/tmp/a b',
        '/tmp/\$(id)',
        '/${'x' * 240}',
      ]) {
        expect(() => TmuxSocketSpec.path(bad), throwsFormatException,
            reason: bad);
      }
    });

    test('新建名字的白名单：中文、空格可以；# : . 引号 分号 通配 控制字符不行', () {
      expect(validateNewSessionName(' 工作 1 '), '工作 1');
      expect(validateNewSessionName('a_b-c'), 'a_b-c');
      for (final bad in [
        '#(id)',
        '##',
        'a:b',
        'a.b',
        "a'b",
        'a"b',
        'a;b',
        'a*',
        'a?',
        '[a]',
        'a\tb',
        'a\nb',
        r'$x',
        '-x',
        'x ' * 40,
        '',
      ]) {
        expect(() => validateNewSessionName(bad), throwsFormatException,
            reason: bad);
      }
    });
  });

  group('版本', () {
    test('认得出的和认不出的', () {
      expect(TmuxVersion.parse('tmux 3.5a').toString(), '3.5a');
      expect(TmuxVersion.parse('tmux 2.4')! >= tmuxOldestTested, isTrue);
      expect(TmuxVersion.parse('tmux 2.3')! >= tmuxOldestTested, isFalse);
      expect(TmuxVersion.parse('tmux 1.8')! >= tmuxOldestTested, isFalse);
      expect(TmuxVersion.parse('tmux next-3.6')!.toString(), '3.6');
      expect(TmuxVersion.parse('tmux 10.0')! >= tmuxOldestTested, isTrue);
      for (final line in [
        'tmux master',
        'tmux openbsd-7.5',
        'screen 4.9',
        '',
        'tmux 3.5a extra'
      ]) {
        expect(TmuxVersion.parse(line), isNull, reason: line);
      }
    });
  });

  group('查询输出解析', () {
    String probe(List<String> lines) => '${lines.join('\n')}\n';
    const head = [
      'U\talice\t1000',
      'V\ttmux 3.5a',
      'P\t/tmp/tmux-1000/default'
    ];

    test('没有 tmux、版本太老、没有 server', () {
      expect(
          parseTmuxProbe(probe(['U\talice\t1000', 'X\tmissing'])).availability,
          TmuxAvailability.missing);
      final old = parseTmuxProbe(
          probe(['U\talice\t1000', 'V\ttmux 1.8', 'X\tnoserver']));
      expect(old.availability, TmuxAvailability.unsupported);
      expect(old.canOperate, isFalse);
      final none = parseTmuxProbe(probe([...head, 'X\tnoserver']));
      expect(none.availability, TmuxAvailability.noServer);
      expect(none.canOperate, isTrue);
    });

    test('正常列表：身份字段、名字里的分隔符并回名字', () {
      final result = parseTmuxProbe(probe([
        ...head,
        row(r'$0', name: 'a|~|b'),
        row(r'$3'),
        'R\t0',
        'X\tend',
      ]));
      expect(result.availability, TmuxAvailability.ready);
      expect(result.server, server);
      expect(result.sessions.map((s) => s.sessionId), [r'$0', r'$3']);
      expect(result.sessions.first.name, 'a|~|b');
      expect(result.truncated, isFalse);
    });

    test('坏行丢掉并计数；两个 server、重复 ID 时整表不可信', () {
      final skipped = parseTmuxProbe(probe([
        ...head,
        row(r'$0'),
        'S${sep}x${sep}y',
        ['S', 'abc', 1, r'$1', 1, 1, 0, 1, 0, 'C-b', '', 'n'].join(sep),
        'R\t0',
        'X\tend',
      ]));
      expect(skipped.availability, TmuxAvailability.ready);
      expect(skipped.sessions, hasLength(1));
      expect(skipped.skippedLines, 2);

      final forged = parseTmuxProbe(probe([
        ...head,
        row(r'$0'),
        row(r'$7', pid: 99999),
        'R\t0',
        'X\tend',
      ]));
      expect(forged.availability, TmuxAvailability.failed);
      expect(forged.canOperate, isFalse);

      final duplicate = parseTmuxProbe(probe([
        ...head,
        row(r'$0'),
        row(r'$0', name: 'other'),
        'R\t0',
        'X\tend',
      ]));
      expect(duplicate.availability, TmuxAvailability.failed);
    });

    test('截断：远端 head 吃掉了退出码那一行，或 App 读到上限', () {
      final remote = parseTmuxProbe(probe([...head, row(r'$0'), 'X\tend']));
      expect(remote.truncated, isTrue);
      expect(remote.availability, TmuxAvailability.ready);
      final local =
          parseTmuxProbe(probe([...head, row(r'$0')]), truncated: true);
      expect(local.truncated, isTrue);
      expect(local.sessions, hasLength(1));
      final cut = parseTmuxProbe(probe([...head, row(r'$0')]));
      expect(cut.availability, TmuxAvailability.failed, reason: '没截断却没结尾：中途断了');
    });

    test('socket 残留、没有 session、tmux 报错', () {
      expect(
        parseTmuxProbe(probe([
          ...head,
          'no server running on /tmp/tmux-1000/default',
          'R\t1',
          'X\tend',
        ])).availability,
        TmuxAvailability.noServer,
      );
      expect(
        parseTmuxProbe(probe([...head, 'no sessions', 'R\t1', 'X\tend']))
            .availability,
        TmuxAvailability.ready,
      );
      final failed = parseTmuxProbe(
          probe([...head, 'server exited unexpectedly', 'R\t1', 'X\tend']));
      expect(failed.availability, TmuxAvailability.failed);
      expect(failed.problem, contains('server exited unexpectedly'));
    });

    test('认不出的输出：失败而不是当成空列表', () {
      expect(parseTmuxProbe('garbage\n').availability, TmuxAvailability.failed);
      expect(parseTmuxProbe('').availability, TmuxAvailability.failed);
    });

    test('新建的回报：拿到身份；tmux 报错时给出原因', () {
      final messages = <String>[];
      final created = parseCreatedSession(
          probe(['P\t/tmp/tmux-1000/default', row(r'$5', name: 'new')]),
          messages);
      expect(created!.sessionId, r'$5');
      expect(created.server.socketPath, '/tmp/tmux-1000/default');
      final errors = <String>[];
      expect(
        parseCreatedSession(
            probe(['P\t/tmp/tmux-1000/default', 'duplicate session: new']),
            errors),
        isNull,
      );
      expect(errors.single, 'duplicate session: new');
    });
  });

  test('显示用文字：控制字符和双向控制符看得见、去得掉，长度有限', () {
    expect(displaySafe('a\tb\nc\x1b[2J\x07'), r'a\tb\nc\x1b[2J\x07');
    expect(displaySafe('abc\u202Edef'), 'abc�def');
    expect(displaySafe('x' * 500, max: 10), '${'x' * 10}…');
    expect(displaySafe('中文\u0085'), r'中文\x85');
  });

  test('会话详情：窗口和客户端，认不出的行丢掉', () {
    final details = parseTmuxDetails([
      ['W', 0, 2, 1, 'editor'].join(sep),
      ['W', 'x', 1, 0, 'bad'].join(sep),
      ['C', 4321, '/dev/pts/3'].join(sep),
      ['C', 1, 'not a tty'].join(sep),
      'garbage',
    ].join('\n'));
    expect(details.windows.single.name, 'editor');
    expect(details.windows.single.panes, 2);
    expect(details.clients.single.tty, '/dev/pts/3');
  });

  test('附着握手那一行', () {
    expect(parseAttachMarker('$tmuxAttachMarker /dev/pts/3 4567'),
        (tty: '/dev/pts/3', pid: 4567));
    expect(parseAttachMarker('$tmuxAttachMarker not a tty 4567'), isNull);
    expect(parseAttachMarker('$tmuxAttachMarker /dev/pts/3;id 4567'), isNull);
    expect(parseAttachMarker('nothing'), isNull);
  });

  test('退出码的说法：不在了、换了用户算「目标不在」，恢复据此停下', () {
    expect(tmuxExitError(0, ''), isNull);
    expect(tmuxExitError(97, ''), isA<TmuxTargetGoneException>());
    expect(tmuxExitError(96, ''), isA<TmuxTargetGoneException>());
    expect(tmuxExitError(95, '')!.exitCode, TmuxExit.missing);
    expect(tmuxExitError(98, ''), isNot(isA<TmuxTargetGoneException>()));
    expect(tmuxExitError(1, "can't find session: \$9\x1b[2J").toString(),
        r"tmux 命令失败：can't find session: $9\x1b[2J");
    expect(tmuxExitError(null, ''), isA<TmuxCommandException>());
  });

  test('目标的同一性：任何一项不同都不算同一个', () {
    TmuxTarget copy({
      String hostKey = '10.0.0.5:22',
      int uid = 1000,
      TmuxSocketSpec socket = const TmuxSocketSpec.standard(),
      TmuxServerIdentity server = server,
      String id = r'$3',
      int created = 1700000100,
      String name = 'renamed',
    }) =>
        TmuxTarget(
          hostKey: hostKey,
          unixUser: 'alice',
          uid: uid,
          socket: socket,
          server: server,
          sessionId: id,
          sessionCreated: created,
          displayName: name,
        );
    expect(copy().sameAs(target), isTrue, reason: '改名不影响同一性');
    expect(copy(hostKey: '10.0.0.6:22').sameAs(target), isFalse);
    expect(copy(uid: 1001).sameAs(target), isFalse);
    expect(copy(socket: TmuxSocketSpec.named('x')).sameAs(target), isFalse);
    expect(
        copy(
                server: const TmuxServerIdentity(
                    socketPath: '/tmp/tmux-1000/default',
                    pid: 71,
                    startTime: 1700000000))
            .sameAs(target),
        isFalse);
    expect(copy(id: r'$4').sameAs(target), isFalse);
    expect(copy(created: 1700000101).sameAs(target), isFalse);
  });
}
