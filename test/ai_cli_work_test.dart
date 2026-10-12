import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/ai_cli.dart';
import 'package:shun/domain/ai_cli_work.dart';
import 'package:shun/domain/tmux/ai_cli_tmux_run.dart';
import 'package:shun/domain/tmux/tmux_target.dart';

void main() {
  final claude = AiCliWorkItem(
    id: 'tab-1',
    tool: AiCliKind.claude,
    name: 'Claude Code',
    executable: '/opt/bin/claude',
    projectDirectory: '/repo with space',
    openedAt: DateTime.utc(2026, 10, 12),
    claudeSessionId: '550e8400-e29b-41d4-a716-446655440000',
  );

  test('exact Claude ID and project stay paired across serialization', () {
    final read = AiCliWorkItem.fromJson(claude.toJson())!;
    expect(read.exactResume()!.arguments,
        ['--resume', '550e8400-e29b-41d4-a716-446655440000']);
    expect(read.exactResume()!.projectDirectory, '/repo with space');
    expect(read.historyPicker(), isNull);
  });

  test('Codex offers an explicit picker, never guesses --last', () {
    final codex = AiCliWorkItem(
      id: 'tab-2',
      tool: AiCliKind.codex,
      name: 'Codex',
      executable: '/opt/bin/codex',
      projectDirectory: '/repo',
      openedAt: DateTime.utc(2026, 10, 12),
    );
    expect(codex.exactResume(), isNull);
    expect(codex.historyPicker()!.arguments, ['resume']);
  });

  test('corrupt or mismatched native IDs cannot become resume targets', () {
    expect(
        AiCliWorkItem.fromJson({...claude.toJson(), 'tool': 'codex'}), isNull);
    expect(
        AiCliWorkItem.fromJson(
            {...claude.toJson(), 'claudeSessionId': 'abc; touch /tmp/x'}),
        isNull);
  });

  test('recent work retains exact tmux server, window and pane identity', () {
    final run = AiCliTmuxRun(
      requestId: '550e8400-e29b-41d4-a716-446655440000',
      target: TmuxTarget(
        hostKey: 'host:22',
        unixUser: 'u',
        uid: 1000,
        socket: const TmuxSocketSpec.standard(),
        server: const TmuxServerIdentity(
            socketPath: '/tmp/tmux-1000/default', pid: 123, startTime: 456),
        sessionId: r'$3',
        sessionCreated: 789,
        displayName: 'shun-ai-550e8400-e29b-41d4-a716-446655440000',
      ),
      windowId: '@4',
      paneId: '%5',
      panePid: 222,
    );
    final item = AiCliWorkItem(
      id: 'tab-3',
      tool: AiCliKind.claude,
      name: 'Claude Code',
      executable: '/bin/claude',
      projectDirectory: '/repo',
      openedAt: DateTime.utc(2026, 10, 12),
      claudeSessionId: claude.claudeSessionId,
      tmuxRun: run,
    );
    final read = AiCliWorkItem.fromJson(item.toJson())!;
    expect(read.tmuxRun!.sameAs(run), true);
    final bad = item.toJson();
    (bad['tmuxRun'] as Map<String, Object?>)['paneId'] = 'wrong';
    expect(AiCliWorkItem.fromJson(bad), isNull);
  });
}
