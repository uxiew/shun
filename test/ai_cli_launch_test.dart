import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/ai_cli_launch.dart';

void main() {
  test('new PTY exec command treats paths and arguments as literal data',
      () async {
    final root = await Directory.systemTemp.createTemp('shun-r56-');
    addTearDown(() => root.delete(recursive: true));
    final project =
        await Directory('${root.path}/项目 \' \$(touch INJECTED)').create();
    final marker = File('${project.path}/INJECTED');
    final tool = File("${root.path}/co'dex \$(touch INJECTED)");
    await tool.writeAsString('#!/bin/sh\nprintf "%s\\n" "\$PWD" "\$1"\n');
    expect((await Process.run('chmod', ['+x', tool.path])).exitCode, 0);

    final launch = AiCliLaunchSpec(
      executable: tool.path,
      projectDirectory: project.path,
      arguments: ['arg \' \$(touch INJECTED)'],
    );
    final result = await Process.run('/bin/sh', ['-c', launch.sshCommand]);
    expect(result.exitCode, 0);
    expect(result.stdout, '${project.path}\narg \' \$(touch INJECTED)\n');
    expect(await marker.exists(), isFalse);
    final probe =
        await Process.run('/bin/sh', ['-c', launch.projectProbeScript]);
    expect(probe.exitCode, 0);
    expect(probe.stdout, 'P${await project.resolveSymbolicLinks()}\n');
    expect(await marker.exists(), isFalse);
  });

  test('missing directory and changed executable fail without home fallback',
      () async {
    final root = await Directory.systemTemp.createTemp('shun-r56-');
    addTearDown(() => root.delete(recursive: true));
    final tool = File('${root.path}/tool')
      ..writeAsStringSync('#!/bin/sh\nexit 0\n');
    final missing = AiCliLaunchSpec(
        executable: tool.path, projectDirectory: '${root.path}/missing');
    expect((await Process.run('/bin/sh', ['-c', missing.sshCommand])).exitCode,
        125);
    final notExecutable =
        AiCliLaunchSpec(executable: tool.path, projectDirectory: root.path);
    expect(
        (await Process.run('/bin/sh', ['-c', notExecutable.sshCommand]))
            .exitCode,
        126);
  });

  test('absolute tool, safe directory and bounded arguments are required', () {
    for (final point in [
      ...List.generate(32, (i) => i),
      ...List.generate(33, (i) => 127 + i)
    ]) {
      final control = String.fromCharCode(point);
      expect(
          () => AiCliLaunchSpec(
              executable: '/bin/$control', projectDirectory: '/tmp'),
          throwsFormatException);
      expect(
          () => AiCliLaunchSpec(
              executable: '/bin/codex', projectDirectory: '/tmp/$control'),
          throwsFormatException);
      expect(
          () => AiCliLaunchSpec(
              executable: '/bin/codex',
              projectDirectory: '/tmp',
              arguments: [control]),
          throwsFormatException);
    }
    expect(
        () => AiCliLaunchSpec(executable: '~/codex', projectDirectory: '/tmp'),
        throwsFormatException);
    expect(
        () => AiCliLaunchSpec(executable: '/bin/codex', projectDirectory: ''),
        throwsFormatException);
    expect(
        () => AiCliLaunchSpec(
            executable: '/bin/codex',
            projectDirectory: '/tmp',
            arguments: ['bad\nargument']),
        throwsFormatException);
  });
}
