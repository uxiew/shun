import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/ai_cli.dart';
import 'package:shun/infrastructure/ssh/ai_cli_discovery.dart';
import 'package:shun/infrastructure/ssh/ai_cli_protocol.dart';

String record(List<String> fields) => '${fields.join('\x00')}\x00';
String output(List<List<String>> tools) => 'SHUN-AIC-1\x00${record([
          'H',
          'fixture',
          '1000',
          '',
          ''
        ])}${tools.map(record).join()}${record(['Z', '0', '', '', ''])}';

class ProbeChannel implements AiCliProbeChannel {
  final out = StreamController<Uint8List>();
  final err = StreamController<Uint8List>();
  final ended = Completer<void>();
  String? script;
  bool closed = false;
  @override
  int? exitCode = 0;
  @override
  Stream<Uint8List> get stdout => out.stream;
  @override
  Stream<Uint8List> get stderr => err.stream;
  @override
  Future<void> get done => ended.future;
  @override
  Future<void> writeScript(String value) async {
    script = value;
  }

  void send(String data) => out.add(Uint8List.fromList(utf8.encode(data)));
  void end() {
    unawaited(out.close());
    unawaited(err.close());
    if (!ended.isCompleted) ended.complete();
  }

  @override
  void close() {
    closed = true;
    end();
  }
}

void main() {
  group('AIC01 actual POSIX discovery, without executing any CLI', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('r55-');
    });
    tearDown(() async {
      await tmp.delete(recursive: true);
    });
    Future<String> executable(String relative) async {
      final f = File('${tmp.path}/$relative');
      await f.parent.create(recursive: true);
      // A known-name executable deliberately ignores --version and writes if
      // invoked: discovery must leave this sentinel absent.
      await f.writeAsString('#!/bin/sh\nprintf BAD > "${tmp.path}/executed"\n');
      expect((await Process.run('/bin/chmod', ['+x', f.path])).exitCode, 0);
      return f.path;
    }

    Future<AiCliScanResult> scan(AiCliScanRequest request, String path) async {
      final p = await Process.start('/bin/sh', ['-s'],
          environment: {'PATH': path}, includeParentEnvironment: false);
      final out = p.stdout.transform(utf8.decoder).join();
      final err = p.stderr.transform(utf8.decoder).join();
      p.stdin.write(aiCliProbeScript(request, commonLocations: []));
      await p.stdin.close();
      expect(await p.exitCode, 0, reason: await err);
      return parseAiCliScan(await out, request);
    }

    test(
        'all PATH installations, supplied directories, custom paths and package metadata',
        () async {
      final a = await executable("安装 空'\$(echo bad)/claude");
      final b = await executable('other/claude');
      final native = await executable('pkg/bin/codex');
      await File('${tmp.path}/pkg/package.json').writeAsString(jsonEncode({
        'name': '@openai/codex',
        'version': '0.160.1',
      }));
      // A real executable symlink to an npm-style package installation.
      await Link('${tmp.path}/other/codex').create(native);
      final extra = await executable('extra/gemini');
      final custom = await executable('custom/自定义工具');
      final request = AiCliScanRequest(
          directories: ['${tmp.path}/extra'],
          customTools: [AiCliCustomTool(name: 'Other AI', path: custom)]);
      final result = await scan(request,
          '${File(a).parent.path}:${File(b).parent.path}:${File(a).parent.path}');
      expect(result.installations.map((x) => x.path).toSet(),
          {a, b, '${tmp.path}/other/codex', extra, custom});
      expect(
          result.installations
              .singleWhere((x) => x.kind == AiCliKind.codex)
              .packageVersion,
          '0.160.1');
      expect(
          result.installations
              .where((x) => x.kind == AiCliKind.claude)
              .every((x) => x.packageVersion == null),
          true);
      expect(await File('${tmp.path}/executed').exists(), false);
      expect(
          result.installations
              .singleWhere((x) => x.kind == AiCliKind.custom)
              .source,
          'custom');
    });
    test(
        'custom executable named claude is path-only; supplied shell syntax is literal',
        () async {
      final path = await executable("literal/claude'\$(touch sentinel)");
      final req = AiCliScanRequest(
          customTools: [AiCliCustomTool(name: 'Wrapper', path: path)]);
      final result = await scan(req, '/does-not-exist');
      expect(result.installations.single.kind, AiCliKind.custom);
      expect(result.installations.single.packageVersion, null);
      expect(await File('${tmp.path}/executed').exists(), false);
      expect(await File('sentinel').exists(), false);
    });
    test('missing, non-executable, and relative PATH are not claimed installed',
        () async {
      await File('${tmp.path}/claude').writeAsString('not executable');
      final result = await scan(AiCliScanRequest(), '${tmp.path}:relative:.');
      expect(result.installations, isEmpty);
    });
    test('PATH and candidate limits reported', () async {
      final folders = <String>[];
      for (var i = 0; i < 66; i++) {
        final path = await executable('p$i/codex');
        folders.add(File(path).parent.path);
      }
      final result = await scan(AiCliScanRequest(), folders.join(':'));
      expect(result.installations.length, 64);
      expect(result.limited, true);
      expect(await File('${tmp.path}/executed').exists(), false);
    });
  });
  test('request rejects controls/relative paths and limits custom input', () {
    for (final value in ['relative', '/x\ncommand', '/x\x00', '/x\x1b']) {
      expect(
          () => AiCliScanRequest(directories: [value]), throwsFormatException);
    }
    expect(() => AiCliScanRequest(directories: List.filled(17, '/bin')),
        throwsFormatException);
    expect(
        () => AiCliCustomTool(name: '', path: '/bin/x'), throwsFormatException);
  });
  test(
      'untrusted protocol: unknown, incomplete, duplicated identity, control fields',
      () {
    final req = AiCliScanRequest();
    for (final bad in [
      'banner\n${output([])}',
      output([]).substring(0, 10),
      output([
        ['F', 'unknown', 'PATH', '/x', '']
      ]),
      output([
        ['H', 'other', '2000', '', '']
      ]),
      output([
        ['F', 'claude', 'PATH', '/x\x1b', '']
      ]),
      output([
        ['F', 'claude', 'PATH', 'relative', '']
      ]),
    ]) {
      expect(() => parseAiCliScan(bad, req), throwsA(isA<Exception>()));
    }
    final result = parseAiCliScan(
        output([
          ['F', 'claude', 'PATH', '/bin/claude', 'fake version']
        ]),
        req);
    expect(result.installations.single.packageVersion, null);
  });
  group('AIC02 bounded dedicated query channel', () {
    test('does not open anything after pre-cancel', () async {
      var opened = 0;
      final token = AiCliProbeCancellation()..cancel();
      await expectLater(
          runAiCliProbe(
              open: () async {
                opened++;
                return ProbeChannel();
              },
              script: 'test',
              cancellation: token,
              timeout: const Duration(seconds: 1)),
          throwsA(isA<AiCliDiscoveryException>()));
      expect(opened, 0);
    });
    test('timeout returns before opening and closes a late channel', () async {
      final opening = Completer<AiCliProbeChannel>();
      final channel = ProbeChannel();
      await expectLater(
          runAiCliProbe(
              open: () => opening.future,
              script: 'test',
              cancellation: AiCliProbeCancellation(),
              timeout: const Duration(milliseconds: 30)),
          throwsA(isA<AiCliDiscoveryException>()));
      opening.complete(channel);
      await Future<void>.delayed(Duration.zero);
      expect(channel.closed, true);
      expect(channel.script, null);
    });
    test('cancellation closes own channel without waiting for remote EOF',
        () async {
      final channel = ProbeChannel();
      final token = AiCliProbeCancellation();
      final future = runAiCliProbe(
          open: () async => channel,
          script: 'test',
          cancellation: token,
          timeout: const Duration(seconds: 3));
      final assertion =
          expectLater(future, throwsA(isA<AiCliDiscoveryException>()));
      await Future<void>.delayed(Duration.zero);
      token.cancel();
      await assertion;
      expect(channel.closed, true);
    });
    for (final stderr in [false, true]) {
      test(
          '${stderr ? 'stderr' : 'stdout'} overflow discards result and closes channel',
          () async {
        final channel = ProbeChannel();
        final future = runAiCliProbe(
            open: () async => channel,
            script: 'test',
            cancellation: AiCliProbeCancellation(),
            timeout: const Duration(seconds: 3),
            maxBytes: 10);
        final assertion =
            expectLater(future, throwsA(isA<AiCliDiscoveryException>()));
        await Future<void>.delayed(Duration.zero);
        (stderr ? channel.err : channel.out).add(Uint8List(11));
        await assertion;
        expect(channel.closed, true);
      });
    }
    test('EOF and exit status required; remote stderr is not returned',
        () async {
      final channel = ProbeChannel();
      final future = runAiCliProbe(
          open: () async => channel,
          script: 'test',
          cancellation: AiCliProbeCancellation(),
          timeout: const Duration(seconds: 3));
      await Future<void>.delayed(Duration.zero);
      channel.err.add(Uint8List.fromList(utf8.encode('SECRET')));
      channel.send('safe');
      channel.end();
      expect(await future, 'safe');
      expect(channel.closed, true);
    });
  });
}
