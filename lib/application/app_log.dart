import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/log_scrub.dart';

/// 本机日志（R26 F24：所有者要看应用崩溃、出错和同步事件）。连接事件不在这里：它们记在
/// [ConnectionEventLog]（R25），日志页把两边合在一起显示。
///
/// 和连接记录一样只在这部手机的 App 私有目录：不进备份、不进系统备份，
/// 不上传。写进去之前过一遍 [scrubLogText]，用户复制出去的就是去敏后的。
enum AppLogKind {
  /// App 挂了：Java 层崩溃、原生崩溃、无响应被系统结束、启动失败。都是下次启动才记上的。
  crash,

  /// 没挂，但有代码报了没人接的错；还有系统在后台因为内存不够结束了 App。
  error,

  /// 云端备份的结果。
  sync,
}

class AppLogEntry {
  const AppLogEntry({
    required this.at,
    required this.kind,
    required this.title,
    this.detail,
    this.stack,
    this.count = 1,
  });

  /// 最近一次发生的时间（合并过的是最后一次）。
  final DateTime at;
  final AppLogKind kind;

  /// 一句话：「App 崩溃（Java 层）」「同步失败」…
  final String title;

  /// 报错原文（去敏后）、同步结果这类。
  final String? detail;
  final String? stack;

  /// 同一件事在 [appLogMergeWindow] 里又发生了几次（含第一次）。
  final int count;

  bool sameAs(AppLogEntry other) =>
      kind == other.kind &&
      title == other.title &&
      detail == other.detail &&
      _firstLine(stack) == _firstLine(other.stack);

  Map<String, Object?> toJson() => {
        'at': at.millisecondsSinceEpoch,
        'kind': kind.name,
        'title': title,
        if (detail != null) 'detail': detail,
        if (stack != null) 'stack': stack,
        if (count != 1) 'count': count,
      };

  static AppLogEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = raw['at'];
    final kind =
        AppLogKind.values.where((k) => k.name == raw['kind']).firstOrNull;
    final title = raw['title'];
    if (at is! int || kind == null || title is! String) return null;
    return AppLogEntry(
      at: DateTime.fromMillisecondsSinceEpoch(at),
      kind: kind,
      title: title,
      detail: raw['detail'] is String ? raw['detail'] as String : null,
      stack: raw['stack'] is String ? raw['stack'] as String : null,
      count: raw['count'] is int ? raw['count'] as int : 1,
    );
  }

  static String? _firstLine(String? text) => text
      ?.split('\n')
      .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
}

/// 保留多久、存多少。崩溃往往要隔几天才有人来查，比连接记录（7 天）留得久一点。
const appLogRetention = Duration(days: 14);
const appLogLimit = 300;

/// 同一件事在这段时间里重复，只留一条、计数加一。布局溢出这类错每帧都报，不合并一会儿就把 300 条占满。
const appLogMergeWindow = Duration(minutes: 10);

/// 一条里的报错和堆栈各留多长。堆栈前几十行就够定位，整段留着只会把文件撑大。
const _detailLimit = 2000;
const _stackLimit = 8000;

String _clip(String text, int limit) => text.length <= limit
    ? text
    : '${text.substring(0, limit)}\n… (+${text.length - limit} chars)';

/// 去敏、截短。所有写进日志的都走这里。
AppLogEntry sanitizeAppLogEntry(AppLogEntry entry) => AppLogEntry(
      at: entry.at,
      kind: entry.kind,
      title: scrubLogText(entry.title),
      detail: switch (entry.detail) {
        final d? => _clip(scrubLogText(d.trim()), _detailLimit),
        null => null,
      },
      stack: switch (entry.stack) {
        final s? when s.trim().isNotEmpty =>
          _clip(scrubLogText(s.trim(), stack: true), _stackLimit),
        _ => null,
      },
      count: entry.count,
    );

/// 去掉过了保留期的，按时间排好（旧的在前），超了上限从最旧的删。
List<AppLogEntry> pruneAppLog(List<AppLogEntry> entries, DateTime now) {
  final cutoff = now.subtract(appLogRetention);
  final kept = entries.where((e) => e.at.isAfter(cutoff)).toList()
    ..sort((a, b) => a.at.compareTo(b.at));
  return kept.length <= appLogLimit
      ? kept
      : kept.sublist(kept.length - appLogLimit);
}

/// 文件里除了条目，还记着系统退出记录看到哪了（[AppLog.collectPlatform]），免得每次启动重复记。
class AppLogFile {
  const AppLogFile({this.entries = const [], this.exitsSeenUntil = 0});

  final List<AppLogEntry> entries;
  final int exitsSeenUntil;
}

abstract interface class AppLogStore {
  Future<AppLogFile> load();
  Future<void> save(AppLogFile file);
}

/// 和连接记录放在同一个目录（`…/diagnostics/`，`allowBackup=false`）。不加密：写进来的都去过敏。
class FileAppLogStore implements AppLogStore {
  FileAppLogStore(this._directory);

  final Future<Directory> Function() _directory;

  Future<File> _file() async =>
      File('${(await _directory()).path}/app_log.json');

  @override
  Future<AppLogFile> load() async {
    final file = await _file();
    if (!await file.exists()) return const AppLogFile();
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map || decoded['v'] != 1 || decoded['entries'] is! List) {
      return const AppLogFile();
    }
    return AppLogFile(
      entries: [
        for (final raw in decoded['entries'] as List)
          if (AppLogEntry.fromJson(raw) case final entry?) entry,
      ],
      exitsSeenUntil: decoded['exitsSeenUntil'] is int
          ? decoded['exitsSeenUntil'] as int
          : 0,
    );
  }

  /// 先写临时文件再改名：写到一半被杀，旧记录还在。
  @override
  Future<void> save(AppLogFile log) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      jsonEncode({
        'v': 1,
        'exitsSeenUntil': log.exitsSeenUntil,
        'entries': [for (final entry in log.entries) entry.toJson()],
      }),
      flush: true,
    );
    await temp.rename(file.path);
  }
}

/// 测试用。
class MemoryAppLogStore implements AppLogStore {
  MemoryAppLogStore([this.initial = const AppLogFile()]);

  AppLogFile initial;
  AppLogFile? saved;

  @override
  Future<AppLogFile> load() async => initial;

  @override
  Future<void> save(AppLogFile file) async => saved = file;
}

/// Android 才知道的两样（见 `DiagnosticsChannel.kt`）。
abstract interface class DiagnosticsPlatform {
  /// 上次 Java 层崩溃时写下的堆栈；取一次就删，没有就是 null。`{at, thread, stack}`。
  Future<Map<Object?, Object?>?> takeJavaCrash();

  /// 系统记下的进程退出原因里，比 [since]（毫秒）晚的。Android 11 以下是空的。
  /// `{at, reason, description, trace?}`，reason 是 ApplicationExitInfo.REASON_*。
  Future<List<Map<Object?, Object?>>> exitReasons(int since);
}

class MethodChannelDiagnostics implements DiagnosticsPlatform {
  const MethodChannelDiagnostics();

  static const _channel = MethodChannel('top.xdwa.shun/diagnostics');

  @override
  Future<Map<Object?, Object?>?> takeJavaCrash() async {
    if (!Platform.isAndroid) return null;
    return _channel.invokeMethod<Map<Object?, Object?>>('takeJavaCrash');
  }

  @override
  Future<List<Map<Object?, Object?>>> exitReasons(int since) async {
    if (!Platform.isAndroid) return const [];
    final raw = await _channel.invokeListMethod<Map<Object?, Object?>>(
        'exitReasons', {'since': since});
    return raw ?? const [];
  }
}

/// ApplicationExitInfo 里值得记的几种。用户自己划掉、升级、权限变了这些不记。
/// 数字是 Android 的常量（android.app.ApplicationExitInfo）。
(AppLogKind, String)? exitReasonEntry(int reason) => switch (reason) {
      3 => (AppLogKind.error, '内存不够，系统结束了 App'),
      4 => (AppLogKind.crash, 'App 崩溃（Java 层）'),
      5 => (AppLogKind.crash, 'App 崩溃（原生层）'),
      6 => (AppLogKind.crash, '长时间无响应（ANR），系统结束了 App'),
      7 => (AppLogKind.crash, 'App 启动失败'),
      9 => (AppLogKind.error, '占用资源过多，系统结束了 App'),
      _ => null,
    };

class AppLog extends StateNotifier<List<AppLogEntry>> {
  AppLog(this._store, {DateTime Function()? now})
      : _now = now ?? DateTime.now,
        super(const []) {
    _loaded = _load();
  }

  final AppLogStore _store;
  final DateTime Function() _now;
  late final Future<void> _loaded;
  Future<void> _writes = Future<void>.value();
  int _exitsSeenUntil = 0;

  Future<void> get ready => _loaded;

  Future<void> _load() async {
    AppLogFile stored;
    try {
      stored = await _store.load();
    } on Object {
      // 文件坏了：从空的开始，下次写的时候盖掉。
      stored = const AppLogFile();
    }
    if (!mounted) return;
    _exitsSeenUntil = stored.exitsSeenUntil;
    // 读的这一小会儿可能已经记了新的（启动时就报错），接在读出来的后面。
    state = pruneAppLog([...stored.entries, ...state], _now());
  }

  void record(AppLogEntry entry) {
    if (!mounted) return;
    final clean = sanitizeAppLogEntry(entry);
    final entries = [...state];
    // 只和最近几条比：同一件事一般连着报。
    final start = entries.length > 20 ? entries.length - 20 : 0;
    for (var i = entries.length - 1; i >= start; i--) {
      final earlier = entries[i];
      if (earlier.sameAs(clean) &&
          clean.at.difference(earlier.at).abs() <= appLogMergeWindow) {
        entries[i] = AppLogEntry(
          at: clean.at.isAfter(earlier.at) ? clean.at : earlier.at,
          kind: earlier.kind,
          title: earlier.title,
          detail: earlier.detail,
          stack: earlier.stack,
          count: earlier.count + clean.count,
        );
        state = pruneAppLog(entries, _now());
        unawaited(_persist());
        return;
      }
    }
    state = pruneAppLog([...entries, clean], _now());
    unawaited(_persist());
  }

  /// 没人接的 Dart 错误（见 [installAppErrorCapture]）。
  void recordError(Object error, StackTrace? stack, {required String title}) =>
      record(AppLogEntry(
        at: _now(),
        kind: AppLogKind.error,
        title: title,
        detail: '$error',
        stack: stack?.toString(),
      ));

  void recordSync({required bool ok, required String detail}) =>
      record(AppLogEntry(
        at: _now(),
        kind: AppLogKind.sync,
        title: ok ? '备份完成' : '备份失败',
        detail: detail,
      ));

  /// 启动时调一次：收上次 Java 崩溃留下的堆栈，和系统记下的、还没看过的退出原因。
  /// 取不到就算了：日志是辅助，不能让启动出错。
  Future<void> collectPlatform(DiagnosticsPlatform platform) async {
    await _loaded;
    if (!mounted) return;
    DateTime? javaCrashAt;
    try {
      final crash = await platform.takeJavaCrash();
      if (crash != null && crash['at'] is int) {
        javaCrashAt = DateTime.fromMillisecondsSinceEpoch(crash['at'] as int);
        final stack = crash['stack']?.toString() ?? '';
        record(AppLogEntry(
          at: javaCrashAt,
          kind: AppLogKind.crash,
          title: 'App 崩溃（Java 层）',
          detail: [
            stack.split('\n').first,
            if (crash['thread'] case final thread?) 'thread: $thread',
          ].join('\n'),
          stack: stack,
        ));
      }
    } on Object {
      // 见上
    }
    try {
      final exits = await platform.exitReasons(_exitsSeenUntil);
      var latest = _exitsSeenUntil;
      for (final exit in exits) {
        final at = exit['at'];
        final reason = exit['reason'];
        if (at is! int || reason is! int) continue;
        if (at > latest) latest = at;
        final mapped = exitReasonEntry(reason);
        if (mapped == null) continue;
        final (kind, title) = mapped;
        final when = DateTime.fromMillisecondsSinceEpoch(at);
        // Java 崩溃自己留了堆栈，系统这条只有一句「crash」，不重复记。
        if (reason == 4 &&
            javaCrashAt != null &&
            when.difference(javaCrashAt).abs() < const Duration(seconds: 30)) {
          continue;
        }
        record(AppLogEntry(
          at: when,
          kind: kind,
          title: title,
          detail: [
            if (exit['description'] case final String d when d.isNotEmpty)
              'description: $d',
            'ApplicationExitInfo reason: $reason',
          ].join('\n'),
          stack: exit['trace']?.toString(),
        ));
      }
      if (latest != _exitsSeenUntil) {
        _exitsSeenUntil = latest;
        await _persist();
      }
    } on Object {
      // 见上
    }
  }

  /// 把过了保留期的删掉（打开日志页时调）。
  Future<void> prune() async {
    await _loaded;
    if (!mounted) return;
    final pruned = pruneAppLog(state, _now());
    if (pruned.length == state.length) return;
    state = pruned;
    await _persist();
  }

  /// 清掉条目；「系统退出记录看到哪了」留着，不然下次启动会把旧的又记回来。
  Future<void> clearAll() async {
    await _loaded;
    if (!mounted) return;
    state = const [];
    await _persist();
  }

  /// 写盘排队、总是写当时最新的；读完之前不写。写不进去不报错。
  Future<void> _persist() => _writes = _writes.then((_) async {
        await _loaded;
        if (!mounted) return;
        try {
          await _store.save(
              AppLogFile(entries: state, exitsSeenUntil: _exitsSeenUntil));
        } on Object {
          // 见上
        }
      });
}

/// 在 main 里建好、用 override 交给 ProviderScope（要在 runApp 之前就接住错误）。
/// 没 override 时（测试）用内存里的，不碰文件。
final appLogProvider = StateNotifierProvider<AppLog, List<AppLogEntry>>(
  (ref) => AppLog(MemoryAppLogStore()),
);

Future<Directory> appLogDirectory() async {
  final base = await getApplicationSupportDirectory();
  return Directory('${base.path}/diagnostics');
}

/// 接住没人处理的 Dart 错误记进日志，再交给原来的处理（开发时照样打到控制台、logcat）。
/// 这些错不会让 App 退出，所以记成「错误」，不是「崩溃」。
void installAppErrorCapture(AppLog log) {
  final previousFlutter = FlutterError.onError;
  FlutterError.onError = (details) {
    log.recordError(details.exception, details.stack, title: '界面出错（Flutter）');
    previousFlutter?.call(details);
  };
  final dispatcher = PlatformDispatcher.instance;
  final previousPlatform = dispatcher.onError;
  dispatcher.onError = (error, stack) {
    log.recordError(error, stack, title: '没接住的错误（Dart）');
    return previousPlatform?.call(error, stack) ?? false;
  };
}
