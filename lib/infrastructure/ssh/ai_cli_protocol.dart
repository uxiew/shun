import '../../domain/ai_cli.dart';

const aiCliProbeMaxBytes = 64 * 1024;
const aiCliProbeMaxInstallations = 64;
const aiCliCommonLocations = [
  '~/.local/bin',
  '~/.npm-global/bin',
  '~/.npm/bin',
  '~/.bun/bin',
  '~/bin',
  '/usr/local/bin',
  '/opt/homebrew/bin',
  '/usr/bin',
  '/bin',
];

String _quote(String value) => "'${value.replaceAll("'", "'\\''")}'";

/// An stdin script for a new, non-PTY /bin/sh channel. No discovered executable
/// is run, including --version. Only bounded adjacent package metadata is read.
String aiCliProbeScript(
  AiCliScanRequest request, {
  List<String> commonLocations = aiCliCommonLocations,
}) {
  for (final path in commonLocations) {
    validateAiCliPath(path);
  }
  final directories = [
    for (final path in commonLocations) 'directory ${_quote(path)} common',
    for (final path in request.directories) 'directory ${_quote(path)} added',
  ].join('\n');
  final custom = [
    for (var i = 0; i < request.customTools.length; i++)
      'expand ${_quote(request.customTools[i].path)}\n'
          'candidate custom$i custom "\$expanded"',
  ].join('\n');
  const prefix = r'''
set -f
LC_ALL=C
export LC_ALL
# Use system utility paths, never a utility from the scanned PATH.
utility() {
  if [ -x "/usr/bin/$1" ]; then printf '/usr/bin/%s' "$1"
  elif [ -x "/bin/$1" ]; then printf '/bin/%s' "$1"
  else return 1; fi
}
idcmd=$(utility id) || exit 71
ddcmd=$(utility dd) || ddcmd=
sedcmd=$(utility sed) || sedcmd=
rlcmd=$(utility readlink) || rlcmd=
printf 'SHUN-AIC-1\000'
printf 'H\000%s\000%s\000\000\000' "$("$idcmd" -un)" "$("$idcmd" -u)"
count=0
seen=''
limited=0
expand() {
  case "$1" in '~/'*) expanded="$HOME/${1#\~/}";; *) expanded=$1;; esac
}
metadata() {
  version=
  [ -n "$ddcmd" ] && [ -n "$sedcmd" ] || return
  case "$1" in
    claude) expected='@anthropic-ai/claude-code';;
    codex) expected='@openai/codex';;
    gemini) expected='@google/gemini-cli';;
    opencode) expected='opencode-ai';;
    *) return;;
  esac
  resolved=$2
  if [ -n "$rlcmd" ]; then
    resolved_path=$("$rlcmd" -f "$2" 2>/dev/null) || resolved_path=
    case "$resolved_path" in /*) resolved=$resolved_path;; esac
  fi
  parent=${resolved%/*}
  # Two explicit adjacent locations; not a directory traversal/search.
  for meta in "$parent/package.json" "$parent/../package.json"; do
    [ -f "$meta" ] && [ -r "$meta" ] || continue
    name=$("$ddcmd" if="$meta" bs=8192 count=1 2>/dev/null |
      "$sedcmd" -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    [ "$name" = "$expected" ] || continue
    version=$("$ddcmd" if="$meta" bs=8192 count=1 2>/dev/null |
      "$sedcmd" -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    [ ${#version} -le 80 ] || version=
    break
  done
}
candidate() {
  [ "$count" -lt 64 ] || { limited=1; return; }
  case "$3" in /*) ;; *) return;; esac
  [ ${#3} -le 2048 ] && [ -f "$3" ] && [ -x "$3" ] || return
  # Exact deduplication, including kind. Reject newlines before line-based set.
  case "$3" in *'
'*) limited=1; return;; esac
  case "
$seen
" in *"
$1:$3
"*) return;; esac
  seen="$seen
$1:$3"
  metadata "$1" "$3"
  printf 'F\000%s\000%s\000%s\000%s\000' "$1" "$2" "$3" "$version"
  count=$((count+1))
}
directory() {
  expand "$1"
  dir=$expanded
  case "$dir" in /*) ;; *) return;; esac
  [ ${#dir} -le 2048 ] || { limited=1; return; }
  for tool in claude codex gemini opencode; do
    candidate "$tool" "$2" "${dir%/}/$tool"
  done
}
rest=${PATH-}
pathcount=0
while [ -n "$rest" ]; do
  [ "$pathcount" -lt 64 ] || { limited=1; break; }
  case "$rest" in *:*) item=${rest%%:*}; rest=${rest#*:};; *) item=$rest; rest=;; esac
  directory "$item" PATH
  pathcount=$((pathcount+1))
done
''';
  const suffix = r'''
printf 'Z\000%s\000\000\000\000' "$limited"
''';
  return '$prefix$directories\n$custom\n$suffix';
}

AiCliScanResult parseAiCliScan(String output, AiCliScanRequest request) {
  final parts = output.split('\x00');
  if (parts.length < 12 ||
      parts.first != 'SHUN-AIC-1' ||
      parts.last.isNotEmpty ||
      (parts.length - 2) % 5 != 0) {
    throw const AiCliDiscoveryException('无法识别检测结果，未采用远端输出');
  }
  String? user, uid;
  var ended = false, limited = false;
  final items = <AiCliInstallation>[];
  final seen = <String>{};
  final controls = RegExp(r'[\x00-\x1f\x7f-\x9f]');
  for (var i = 1; i < parts.length - 1; i += 5) {
    final row = parts.sublist(i, i + 5);
    if (ended || row.any((x) => x.length > 2048 || controls.hasMatch(x))) {
      throw const AiCliDiscoveryException('检测结果包含无效或超限字段');
    }
    switch (row[0]) {
      case 'H':
        if (user != null ||
            items.isNotEmpty ||
            row[1].isEmpty ||
            !RegExp(r'^\d+$').hasMatch(row[2]) ||
            row[3].isNotEmpty ||
            row[4].isNotEmpty) {
          throw const AiCliDiscoveryException('检测用户信息无效');
        }
        user = row[1];
        uid = row[2];
      case 'F':
        if (user == null ||
            items.length >= aiCliProbeMaxInstallations ||
            !['PATH', 'common', 'added', 'custom'].contains(row[2])) {
          throw const AiCliDiscoveryException('检测工具记录无效');
        }
        validateAiCliPath(row[3]);
        if (!row[3].startsWith('/')) {
          throw const AiCliDiscoveryException('检测未返回绝对工具路径');
        }
        var kind = AiCliKind.values
            .where((k) => k != AiCliKind.custom && k.command == row[1])
            .firstOrNull;
        String name;
        if (kind == null) {
          final index = RegExp(r'^custom(\d+)$').firstMatch(row[1]);
          final n = index == null ? -1 : int.tryParse(index[1]!) ?? -1;
          if (n < 0 || n >= request.customTools.length || row[2] != 'custom') {
            throw const AiCliDiscoveryException('检测返回了未请求的工具');
          }
          kind = AiCliKind.custom;
          name = request.customTools[n].name;
        } else {
          name = kind.label;
        }
        if (!seen.add('${row[1]}\x00${row[3]}')) continue;
        final version = row[4];
        items.add(AiCliInstallation(
            kind: kind,
            name: name,
            path: row[3],
            source: row[2],
            packageVersion: RegExp(r'^\d+\.\d+\.\d+(?:[-+][a-zA-Z0-9.-]+)?$')
                    .hasMatch(version)
                ? version
                : null));
      case 'Z':
        if (user == null ||
            !['0', '1'].contains(row[1]) ||
            row.skip(2).any((x) => x.isNotEmpty)) {
          throw const AiCliDiscoveryException('检测结束信息无效');
        }
        ended = true;
        limited = row[1] == '1';
      default:
        throw const AiCliDiscoveryException('检测返回未知记录');
    }
  }
  if (!ended || user == null || uid == null) {
    throw const AiCliDiscoveryException('检测未完成，请重新检测');
  }
  return AiCliScanResult(
      unixUser: user,
      uid: uid,
      installations: items,
      scannedAt: DateTime.now(),
      limited: limited);
}
