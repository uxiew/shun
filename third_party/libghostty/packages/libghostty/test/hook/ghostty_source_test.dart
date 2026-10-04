@Tags(['ffi'])
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:libghostty/src/hook/ghostty_source.dart';
import 'package:test/test.dart';

import 'helpers/test_server.dart';

void main() {
  group('pinnedCommit', () {
    test('is a 40-character hex string', () {
      final tmpDir = Directory.systemTemp.createTempSync('pinnedCommit_test_');
      addTearDown(() => tmpDir.deleteSync(recursive: true));
      File(
        '${tmpDir.path}/ghostty.version',
      ).writeAsStringSync('861a9cf537a58a380bc6a0784573b3de3a70415e\n');

      final commit = pinnedCommit(tmpDir.uri);
      expect(commit, hasLength(40));
      expect(commit, matches(RegExp(r'^[0-9a-f]{40}$')));
    });

    test('throws when ghostty.version is missing', () {
      final tmpDir = Directory.systemTemp.createTempSync('pinnedCommit_test_');
      addTearDown(() => tmpDir.deleteSync(recursive: true));

      expect(() => pinnedCommit(tmpDir.uri), throwsA(isA<StateError>()));
    });
  });

  group('resolveSource', () {
    late Directory tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('ghostty_source_test_');
    });

    tearDown(() {
      tmpDir.deleteSync(recursive: true);
    });

    test(
      'returns local ghostty/ dir when it exists at workspace root',
      () async {
        final packageRoot = Directory(
          '${tmpDir.path}/workspace/packages/libghostty',
        )..createSync(recursive: true);
        final ghosttyDir = Directory('${tmpDir.path}/workspace/ghostty')
          ..createSync(recursive: true);
        File('${ghosttyDir.path}/build.zig').writeAsStringSync('marker');

        final result = await resolveSource(
          packageRoot: packageRoot.uri,
          cacheBase: Uri.directory('${tmpDir.path}/cache/'),
        );

        expect(result.uri.path, contains('workspace/ghostty'));
      },
    );

    test('resolved local dir contains expected files', () async {
      final packageRoot = Directory(
        '${tmpDir.path}/workspace/packages/libghostty',
      )..createSync(recursive: true);
      final ghosttyDir = Directory('${tmpDir.path}/workspace/ghostty')
        ..createSync(recursive: true);
      File('${ghosttyDir.path}/build.zig').writeAsStringSync('marker');

      final result = await resolveSource(
        packageRoot: packageRoot.uri,
        cacheBase: Uri.directory('${tmpDir.path}/cache/'),
      );

      expect(File('${result.path}/build.zig').existsSync(), isTrue);
    });

    test('falls back to local dir when GHOSTTY_SRC is not set', () async {
      final packageRoot = Directory(
        '${tmpDir.path}/workspace/packages/libghostty',
      )..createSync(recursive: true);
      Directory('${tmpDir.path}/workspace/ghostty').createSync(recursive: true);

      final result = await resolveSource(
        packageRoot: packageRoot.uri,
        cacheBase: Uri.directory('${tmpDir.path}/cache/'),
      );

      expect(result.existsSync(), isTrue);
    });
  });

  group('downloadSource', () {
    late Directory tmpDir;
    late Uri packageRoot;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('download_source_test_');
      packageRoot = Uri.directory('${tmpDir.path}/pkg/');
      Directory.fromUri(packageRoot).createSync(recursive: true);
      File.fromUri(
        packageRoot.resolve('ghostty.version'),
      ).writeAsStringSync('861a9cf537a58a380bc6a0784573b3de3a70415e\n');
    });

    tearDown(() {
      tmpDir.deleteSync(recursive: true);
    });

    // xwshun: downloadSource 会按 ghostty.sha256 核对源码包，测试用的包也要先把 hash 固定下来。
    void pinSha256(File tarball) {
      File.fromUri(
        packageRoot.resolve('ghostty.sha256'),
      ).writeAsStringSync('${sha256.convert(tarball.readAsBytesSync())}\n');
    }

    test('extracts tarball content to cache', () async {
      final contentDir = Directory('${tmpDir.path}/content')..createSync();
      File('${contentDir.path}/build.zig').writeAsStringSync('test marker');

      final tarball = File('${tmpDir.path}/test.tar.gz');
      Process.runSync('tar', ['czf', tarball.path, '-C', contentDir.path, '.']);
      pinSha256(tarball);

      final serverDir = Directory('${tmpDir.path}/server')..createSync();
      tarball.copySync('${serverDir.path}/source.tar.gz');

      final server = await TestServer.start(serverDir);
      addTearDown(server.close);

      final cacheBase = Uri.directory('${tmpDir.path}/cache/');
      final result = await downloadSource(
        cacheBase,
        packageRoot: packageRoot,
        tarballUrl: '${server.baseUrl}/source.tar.gz',
      );

      expect(
        File('${result.path}/build.zig').readAsStringSync(),
        equals('test marker'),
      );
    });

    test('returns cached directory on second call', () async {
      final contentDir = Directory('${tmpDir.path}/content')..createSync();
      File('${contentDir.path}/marker.txt').writeAsStringSync('v1');

      final tarball = File('${tmpDir.path}/test.tar.gz');
      Process.runSync('tar', ['czf', tarball.path, '-C', contentDir.path, '.']);
      pinSha256(tarball);

      final serverDir = Directory('${tmpDir.path}/server')..createSync();
      tarball.copySync('${serverDir.path}/source.tar.gz');

      final server = await TestServer.start(serverDir);
      addTearDown(server.close);

      final cacheBase = Uri.directory('${tmpDir.path}/cache/');
      final tarballUrl = '${server.baseUrl}/source.tar.gz';

      final first = await downloadSource(
        cacheBase,
        packageRoot: packageRoot,
        tarballUrl: tarballUrl,
      );

      File('${serverDir.path}/source.tar.gz').deleteSync();

      final second = await downloadSource(
        cacheBase,
        packageRoot: packageRoot,
        tarballUrl: tarballUrl,
      );

      expect(second.path, equals(first.path));
      expect(
        File('${second.path}/marker.txt').readAsStringSync(),
        equals('v1'),
      );
    });

    test('throws on HTTP error with actionable message', () async {
      File.fromUri(
        packageRoot.resolve('ghostty.sha256'),
      ).writeAsStringSync('${'0' * 64}\n');
      final serverDir = Directory('${tmpDir.path}/empty_server')..createSync();
      final server = await TestServer.start(serverDir);
      addTearDown(server.close);

      final cacheBase = Uri.directory('${tmpDir.path}/cache/');

      expect(
        () => downloadSource(
          cacheBase,
          packageRoot: packageRoot,
          tarballUrl: '${server.baseUrl}/nonexistent.tar.gz',
        ),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('Failed to download'), contains('GHOSTTY_SRC')),
          ),
        ),
      );
    });

    test('cleans up cache dir on extraction failure', () async {
      final serverDir = Directory('${tmpDir.path}/server')..createSync();
      File('${serverDir.path}/bad.tar.gz').writeAsBytesSync([0x00, 0x01, 0x02]);
      // 让核对通过，测的是解包失败。
      pinSha256(File('${serverDir.path}/bad.tar.gz'));

      final server = await TestServer.start(serverDir);
      addTearDown(server.close);

      final cacheBase = Uri.directory('${tmpDir.path}/cache/');

      await expectLater(
        () => downloadSource(
          cacheBase,
          packageRoot: packageRoot,
          tarballUrl: '${server.baseUrl}/bad.tar.gz',
        ),
        throwsA(isA<Exception>()),
      );

      final commit = pinnedCommit(packageRoot);
      final cacheDir = Directory.fromUri(
        cacheBase.resolve('ghostty-source-${commit.substring(0, 12)}-none/'),
      );
      expect(cacheDir.existsSync(), isFalse);
    });

    test('cleans up tarball after successful extraction', () async {
      final contentDir = Directory('${tmpDir.path}/content')..createSync();
      File('${contentDir.path}/file.txt').writeAsStringSync('data');

      final tarball = File('${tmpDir.path}/test.tar.gz');
      Process.runSync('tar', ['czf', tarball.path, '-C', contentDir.path, '.']);
      pinSha256(tarball);

      final serverDir = Directory('${tmpDir.path}/server')..createSync();
      tarball.copySync('${serverDir.path}/source.tar.gz');

      final server = await TestServer.start(serverDir);
      addTearDown(server.close);

      final cacheBase = Uri.directory('${tmpDir.path}/cache/');
      await downloadSource(
        cacheBase,
        packageRoot: packageRoot,
        tarballUrl: '${server.baseUrl}/source.tar.gz',
      );

      final commit = pinnedCommit(packageRoot);
      final tarballInCache = File.fromUri(cacheBase.resolve('$commit.tar.gz'));
      expect(tarballInCache.existsSync(), isFalse);
    });

    // xwshun: 源码包被换掉（或 GitHub 改了打包方式）时必须停下，不能编进 App。
    test(
      'rejects a tarball whose SHA256 differs from ghostty.sha256',
      () async {
        final contentDir = Directory('${tmpDir.path}/content')..createSync();
        File('${contentDir.path}/build.zig').writeAsStringSync('tampered');
        final serverDir = Directory('${tmpDir.path}/server')..createSync();
        final tarball = File('${serverDir.path}/source.tar.gz');
        Process.runSync('tar', [
          'czf',
          tarball.path,
          '-C',
          contentDir.path,
          '.',
        ]);
        File.fromUri(
          packageRoot.resolve('ghostty.sha256'),
        ).writeAsStringSync('${'a' * 64}\n');

        final server = await TestServer.start(serverDir);
        addTearDown(server.close);
        final cacheBase = Uri.directory('${tmpDir.path}/cache/');

        await expectLater(
          () => downloadSource(
            cacheBase,
            packageRoot: packageRoot,
            tarballUrl: '${server.baseUrl}/source.tar.gz',
          ),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              contains('SHA256 mismatch'),
            ),
          ),
        );

        final commit = pinnedCommit(packageRoot);
        expect(
          Directory.fromUri(
            cacheBase.resolve('ghostty-source-${commit.substring(0, 12)}/'),
          ).existsSync(),
          isFalse,
        );
        expect(
          File.fromUri(cacheBase.resolve('$commit.tar.gz')).existsSync(),
          isFalse,
        );
      },
    );

    test('throws before downloading when ghostty.sha256 is missing', () {
      expect(
        () => downloadSource(
          Uri.directory('${tmpDir.path}/cache/'),
          packageRoot: packageRoot,
          tarballUrl: 'http://127.0.0.1:9/never.tar.gz',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('pinnedSourceSha256', () {
    test('this package pins a source SHA256 next to ghostty.version', () {
      final root = Directory.current.uri;
      expect(pinnedSourceSha256(root), matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(pinnedCommit(root), hasLength(40));
    });

    test('rejects a value that is not a SHA256 digest', () {
      final tmpDir = Directory.systemTemp.createTempSync('sha_test_');
      addTearDown(() => tmpDir.deleteSync(recursive: true));
      File('${tmpDir.path}/ghostty.sha256').writeAsStringSync('abc\n');

      expect(() => pinnedSourceSha256(tmpDir.uri), throwsA(isA<StateError>()));
    });
  });
}
