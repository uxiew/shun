import 'dart:io';

/// Environment variable that overrides source resolution with a local checkout.
const ghosttySrcEnvKey = 'GHOSTTY_SRC';

const _defaultTarballBase = 'https://github.com/ghostty-org/ghostty/archive';

/// Downloads a source tarball, extracts it, and caches the result.
///
/// Uses [tarballUrl] if provided, otherwise builds URL from the pinned commit
/// in `ghostty.version`.
Future<Directory> downloadSource(
  Uri cacheBase, {
  required Uri packageRoot,
  String? tarballUrl,
}) async {
  final commit = pinnedCommit(packageRoot);
  final cacheKey = commit.substring(0, 12);
  final cacheDir = Directory.fromUri(
    cacheBase.resolve('ghostty-source-$cacheKey/'),
  );
  if (cacheDir.existsSync()) return cacheDir;

  tarballUrl ??= '$_defaultTarballBase/$commit.tar.gz';

  final tarball = File.fromUri(cacheBase.resolve('$commit.tar.gz'));
  tarball.parent.createSync(recursive: true);

  final httpClient = HttpClient();
  try {
    final request = await httpClient.getUrl(Uri.parse(tarballUrl));
    final response = await request.close();
    if (response.statusCode != 200) {
      throw Exception(
        'Failed to download Ghostty source: HTTP ${response.statusCode}. '
        'Check your network connection or set '
        '$ghosttySrcEnvKey to a local checkout.',
      );
    }
    final sink = tarball.openWrite();
    await response.pipe(sink);
  } finally {
    httpClient.close();
  }

  cacheDir.createSync(recursive: true);
  final extractResult = Process.runSync('tar', [
    'xzf',
    tarball.path,
    '-C',
    cacheDir.path,
    '--strip-components=1',
  ]);
  if (extractResult.exitCode != 0) {
    cacheDir.deleteSync(recursive: true);
    throw Exception(
      'Failed to extract Ghostty source: ${extractResult.stderr}',
    );
  }

  tarball.deleteSync();

  return cacheDir;
}

/// Reads the pinned Ghostty commit from `ghostty.version` at [packageRoot].
String pinnedCommit(Uri packageRoot) {
  final file = File.fromUri(packageRoot.resolve('ghostty.version'));
  if (!file.existsSync()) {
    throw StateError(
      'ghostty.version not found at ${file.path}. '
      'This file must contain the pinned Ghostty commit hash.',
    );
  }
  return file.readAsStringSync().trim();
}

/// Resolves the Ghostty source directory.
///
/// Resolution order:
/// 1. [ghosttySrcEnvKey] environment variable
/// 2. Local `ghostty/` directory at the workspace root
/// 3. Download from GitHub (cached in [cacheBase])
Future<Directory> resolveSource({
  required Uri packageRoot,
  required Uri cacheBase,
}) async {
  final envPath = Platform.environment[ghosttySrcEnvKey];
  if (envPath != null && envPath.isNotEmpty) {
    final dir = Directory(envPath);
    if (dir.existsSync()) return dir;
  }

  final workspaceRoot = packageRoot.resolve('../../');
  final localGhostty = Directory.fromUri(workspaceRoot.resolve('ghostty/'));
  if (localGhostty.existsSync()) return localGhostty;

  return downloadSource(cacheBase, packageRoot: packageRoot);
}
