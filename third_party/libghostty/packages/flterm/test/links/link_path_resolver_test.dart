import 'package:flterm/src/links/link_path_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LinkPathResolver', () {
    group('parseFile', () {
      test('resolves POSIX relative paths from file URI cwd', () {
        final file = LinkPathResolver.parseFile(
          './.git/logs/refs/heads/backup',
          'file:///opt/workspace/app',
        )!;

        expect(file.path, './.git/logs/refs/heads/backup');
        expect(
          file.resolvedPath,
          '/opt/workspace/app/.git/logs/refs/heads/backup',
        );
      });

      test('resolves current directory paths from file URI cwd', () {
        final file = LinkPathResolver.parseFile(
          '.',
          'file:///workspace/project',
        )!;

        expect(file.path, '.');
        expect(file.resolvedPath, '/workspace/project');
      });

      test('resolves Windows relative paths from file URI cwd', () {
        final file = LinkPathResolver.parseFile(
          r'.\.git\logs\refs\heads\backup',
          'file:///C:/Project/app',
        )!;

        expect(file.path, r'.\.git\logs\refs\heads\backup');
        expect(
          file.resolvedPath,
          r'C:\Project\app\.git\logs\refs\heads\backup',
        );
      });

      test('parses Windows absolute paths with line and column suffixes', () {
        final file = LinkPathResolver.parseFile(
          r'C:\Project\app\main.dart:12:4',
          null,
        )!;

        expect(file.path, r'C:\Project\app\main.dart');
        expect(file.line, 12);
        expect(file.column, 4);
        expect(file.resolvedPath, r'C:\Project\app\main.dart');
      });

      test('leaves home-relative paths unresolved', () {
        final file = LinkPathResolver.parseFile(
          '~/project/main.dart',
          '/repo',
        )!;

        expect(file.path, '~/project/main.dart');
        expect(file.resolvedPath, isNull);
      });

      test('leaves environment-relative paths unresolved', () {
        final file = LinkPathResolver.parseFile(r'$PWD/main.dart', '/repo')!;

        expect(file.path, r'$PWD/main.dart');
        expect(file.resolvedPath, isNull);
      });
    });
  });
}
