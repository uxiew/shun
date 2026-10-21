import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'ssh_lease.dart';
import 'ssh_service.dart';
import 'remote_archive.dart';
import 'server_transfer_commands.dart';

class RemoteEntry {
  const RemoteEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.size,
    this.modifiedAt,
    this.unixMode,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int size;
  final DateTime? modifiedAt;
  final int? unixMode;
}

int? parseUnixPermissions(String value) {
  final normalized = value.trim();
  if (!RegExp(r'^[0-7]{3,4}$').hasMatch(normalized)) return null;
  return int.parse(normalized, radix: 8);
}

String? formatUnixPermissions(int? mode) =>
    mode == null ? null : (mode & 0xfff).toRadixString(8).padLeft(3, '0');

/// 「在终端中打开当前目录」要发的 `cd` 命令；目录名里有控制字符（C0、DEL、C1，含 Tab 和换行）时
/// 返回 null，不发。
///
/// 单引号只防得住 shell，防不住终端和 readline：控制字符到它们那里是按键。名字里藏一个 Ctrl-C，
/// 前半截 `cd '…` 被取消，后半截就当一条新命令执行；Tab 会触发补全。所以整条拒绝，
/// 也不替用户删掉那几个字：删了，cd 进去的就是另一个目录。
String? sftpTerminalCdCommand(String path) {
  for (final rune in path.runes) {
    if (rune < 0x20 || rune == 0x7f || (rune >= 0x80 && rune <= 0x9f)) {
      return null;
    }
  }
  return "cd '${path.replaceAll("'", "'\\''")}'";
}

typedef TransferProgressCallback = void Function(int transferredBytes);

class TransferCancelledException implements Exception {
  const TransferCancelledException();

  @override
  String toString() => '传输已取消';
}

class TransferCancellationToken {
  final _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  /// 用户点了取消时完成。传输卡在等服务器回复时也要马上停（[raceCancellation]），不等下一块数据。
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  void throwIfCancelled() {
    if (isCancelled) throw const TransferCancelledException();
  }
}

/// [work] 和用户取消赛跑：点了取消就马上报 [TransferCancelledException]。[work] 在后台自己结束，
/// 调用方不再用它的结果——写的是临时文件，不会被换成目标文件。
Future<T> raceCancellation<T>(
  Future<T> work,
  TransferCancellationToken? token,
) {
  if (token == null) return work;
  final result = Completer<T>();
  work.then(
    (value) {
      if (!result.isCompleted) result.complete(value);
    },
    onError: (Object error, StackTrace stack) {
      if (!result.isCompleted) result.completeError(error, stack);
    },
  );
  token.whenCancelled.then((_) {
    if (!result.isCompleted) {
      result.completeError(const TransferCancelledException());
    }
  });
  return result.future;
}

/// 传到一半连接断了（读源断的、写目标断的都算）。写的是临时文件，所以目标文件一定没动过；
/// 已传的部分留在 [partialPath]。不会自动重传。
class TransferInterrupted implements Exception {
  const TransferInterrupted(this.target, this.partialPath,
      {this.hasPartial = true});

  final String target;
  final String partialPath;

  /// 临时文件里可能已经有内容。一个字节都还没传时为 false。
  final bool hasPartial;

  @override
  String toString() => hasPartial
      ? '传输中断：连接断了，「$target」没有动过。已传的部分留在「$partialPath」；'
          '不会自动重传，下次传同一个文件时可以选择续传。'
      : '传输中断：连接断了，「$target」没有动过。不会自动重传。';
}

/// 目标位置已经有同名文件，用户没同意替换：没有动它。传好的内容留在临时文件里。
class TargetExists implements Exception {
  const TargetExists(this.path);

  final String path;

  @override
  String toString() => '目标已有同名文件「$path」，没有替换。';
}

/// 文件的大小和修改时间（秒，SFTP 给的就是秒）。拿不到修改时间的来源只比大小。
class FileStamp {
  const FileStamp(this.size, this.modifiedSeconds);

  final int? size;
  final int? modifiedSeconds;

  @override
  bool operator ==(Object other) =>
      other is FileStamp &&
      other.size == size &&
      other.modifiedSeconds == modifiedSeconds;

  @override
  int get hashCode => Object.hash(size, modifiedSeconds);
}

/// 预览 / 在 App 里编辑的上限：1 MiB。更大的文件不打开，让用户选择下载到手机再看。
/// 编辑器把整个文件放在一个文本控件里，再大手机上就卡了。
const previewLimit = 1024 * 1024;

/// 文件比预览上限大：没有打开。
class PreviewTooLarge implements Exception {
  const PreviewTooLarge(this.limit);

  final int limit;

  @override
  String toString() => '文件超过预览上限，没有打开';
}

abstract class FileTransferService {
  // A mounted phone source is mutable. Do not rebind it while operations run.
  int activeOperations = 0;
  String get id;
  String get displayName;
  String get rootPath;
  bool get isLocal;
  bool get supportsUnixPermissions => false;
  bool get supportsArchiveExtraction => false;
  bool get supportsServerTransfer => false;
  Future<String> canonicalPath(String path) async => path;
  Future<void> probeServerTransfer(FileTransferService target,
          TransferCancellationToken? cancellationToken) =>
      Future.error(UnsupportedError('Server-side transfer is unavailable'));
  Future<void> copyOnServer(RemoteEntry entry, FileTransferService target,
          String destination, TransferCancellationToken? cancellationToken) =>
      Future.error(UnsupportedError('Server-side transfer is unavailable'));
  Future<void> moveOnServer(String source, String destination,
          TransferCancellationToken? cancellationToken) =>
      Future.error(UnsupportedError('Server-side transfer is unavailable'));
  Future<void> extractArchive(String archive, String destination) =>
      Future<void>.error(UnsupportedError('Remote archives only'));
  Future<void> compressEntries(List<RemoteEntry> entries, String destination) =>
      Future<void>.error(UnsupportedError('Remote archives only'));

  String displayPath(String path);
  String joinPath(String path, String name);
  String parentPath(String path);
  Future<List<RemoteEntry>> list(String path);
  Stream<Uint8List> readStream(
    String path, {
    int startOffset = 0,
    TransferProgressCallback? onProgress,
  });
  Future<void> writeStream(
    String path,
    Stream<Uint8List> stream, {
    int startOffset = 0,
    bool truncate = true,
    TransferProgressCallback? onProgress,
  });
  Future<int?> fileSize(String path);

  /// 文件的大小和修改时间；不存在时为 null。编辑器保存前用它看文件在打开之后有没有被别人改过。
  Future<FileStamp?> stamp(String path) async {
    final size = await fileSize(path);
    return size == null ? null : FileStamp(size, null);
  }

  /// 只读文件的前 [maxBytes] 字节。默认按 [readStream] 读到够了就停。
  Stream<Uint8List> readPrefix(String path, int maxBytes) async* {
    var remaining = maxBytes;
    if (remaining <= 0) return;
    await for (final chunk in readStream(path)) {
      if (chunk.length >= remaining) {
        yield Uint8List.sublistView(chunk, 0, remaining);
        return;
      }
      remaining -= chunk.length;
      yield chunk;
    }
  }

  Future<void> mkdir(String path);
  Future<void> ensureDirectory(String path);
  Future<void> rename(String from, String to);
  Future<void> delete(RemoteEntry entry);
  Future<void> setPermissions(String path, int mode) =>
      Future<void>.error(UnsupportedError('当前文件来源不支持修改权限'));

  /// 读整个文件给预览 / 编辑器用，最多 [limit] 字节。比这大就报 [PreviewTooLarge]：只多读 1 字节来判断，
  /// 不会把大文件整个读进内存（列表里的大小可能已经过时：文件还在变大）。
  Future<Uint8List> readBounded(String path, {int limit = previewLimit}) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in readPrefix(path, limit + 1)) {
      builder.add(chunk);
      if (builder.length > limit) throw PreviewTooLarge(limit);
    }
    return builder.takeBytes();
  }

  Future<String> readTextBounded(String path,
          {int limit = previewLimit}) async =>
      utf8.decode(await readBounded(path, limit: limit), allowMalformed: true);

  Future<void> writeBytes(String path, Uint8List data) =>
      writeStream(path, Stream.value(data));

  Future<void> writeText(String path, String content) =>
      writeBytes(path, Uint8List.fromList(utf8.encode(content)));
}

abstract class MountableFileTransferService extends FileTransferService {
  bool get isMounted;
  String? get mountedDirectoryName;
  bool get usesAppDocuments => false;
  Future<bool> mount();
}

/// 文件页里一台服务器的文件。借的是 [session] 这一代的 SSH 连接（[SshLease]），只用它：
/// 它断了，这里的每一步都报 [ConnectionGone] / [OutcomeUnknown]，不重连、不另开一条；
/// 标签恢复成新连接后，文件页为新连接另建一个（[SftpServiceCache]）。
class SftpService extends FileTransferService {
  SftpService(this.session);

  final ActiveTerminalSession session;
  SshLease? _lease;

  /// 第一次用到时借。连接已经没了就报 [ConnectionGone]（不缓存，反正这个会话对象不会再连上）。
  SshLease get lease => _lease ??= _borrow();

  SshLease _borrow() {
    final lease = SshLease.of(session);
    // 连接一断就关掉 SFTP 客户端：它还在等的请求由 dartssh2 统一报错，不再挂着。
    lease.lost.then((_) {
      final opening = _opening;
      _opening = null;
      if (opening == null) return;
      unawaited(opening.then<void>((client) async {
        try {
          await client.close();
        } catch (_) {
          // 连接已经没了，关不干净也无妨；要的是它把挂着的请求都报错结束。
        }
      }, onError: (Object _) {}));
    });
    return lease;
  }

  @override
  bool get supportsServerTransfer => true;

  @override
  Future<String> canonicalPath(String path) =>
      _read((sftp) => sftp.absolute(path));

  @override
  Future<void> probeServerTransfer(FileTransferService target,
      TransferCancellationToken? cancellationToken) async {
    if (target is! SftpService) throw UnsupportedError('Not an SSH target');
    if (sameTransferStorage(this, target)) {
      await _runFileCommand(
          'command -v cp >/dev/null && command -v mv >/dev/null',
          action: null,
          cancellationToken: cancellationToken,
          timeout: const Duration(seconds: 15));
    } else {
      // Never reinterpret the phone's private routes on a different machine.
      final host = target.session.host;
      if ((host.proxyProfileId?.isNotEmpty ?? false) ||
          host.hostChainIds.isNotEmpty ||
          (host.data['proxyConfig'] is Map &&
              (host.data['proxyConfig'] as Map).isNotEmpty)) {
        throw UnsupportedError(
            'Phone proxy/jump-host routes require phone relay');
      }
      final command =
          ServerTransferCommands.sftp(host.hostname, host.port, host.username);
      await _runFileCommand('exec $command',
          action: null,
          input: 'pwd\nbye\n',
          cancellationToken: cancellationToken,
          timeout: const Duration(seconds: 15));
      await target._runFileCommand('command -v mv >/dev/null',
          action: null,
          cancellationToken: cancellationToken,
          timeout: const Duration(seconds: 15));
    }
  }

  @override
  Future<void> copyOnServer(RemoteEntry entry, FileTransferService target,
      String destination, TransferCancellationToken? cancellationToken) async {
    if (sameTransferStorage(this, target)) {
      await _runFileCommand(
          ServerTransferCommands.copy(entry.path, destination),
          action: '服务器上复制到「$destination」',
          cancellationToken: cancellationToken);
    } else {
      if (target is! SftpService) throw UnsupportedError('Not an SSH target');
      final host = target.session.host;
      final command =
          ServerTransferCommands.sftp(host.hostname, host.port, host.username);
      await _runFileCommand('exec $command',
          action: '服务器直传到「$destination」',
          input: ServerTransferCommands.upload(
              entry.path, destination, entry.isDirectory),
          cancellationToken: cancellationToken);
    }
  }

  @override
  Future<void> moveOnServer(String source, String destination,
          TransferCancellationToken? cancellationToken) =>
      _runFileCommand(ServerTransferCommands.move(source, destination),
          action: '移动「$source」→「$destination」',
          cancellationToken: cancellationToken);

  /// 在服务器上跑一条文件命令。[action] 为 null 的是只读的探测；不为 null 的会改动服务器，
  /// 连接在它执行中途断了就报 [OutcomeUnknown]。
  Future<void> _runFileCommand(String command,
      {required String? action,
      String input = '',
      TransferCancellationToken? cancellationToken,
      Duration? timeout}) {
    cancellationToken?.throwIfCancelled();
    Future<void> run(SSHClient ssh) => _runFileCommandOn(ssh, command,
        input: input, cancellationToken: cancellationToken, timeout: timeout);
    return action == null ? lease.read(run) : lease.write(action, run);
  }

  Future<void> _runFileCommandOn(SSHClient ssh, String command,
      {required String input,
      TransferCancellationToken? cancellationToken,
      Duration? timeout}) async {
    final interrupted = Completer<void>();
    SSHSession? process;
    var finished = false;
    void interrupt(Object error) {
      if (!finished && !interrupted.isCompleted) {
        interrupted.completeError(error);
      }
    }

    final cancelTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (cancellationToken?.isCancelled ?? false) {
        interrupt(const TransferCancelledException());
      }
    });
    final deadline = timeout == null
        ? null
        : Timer(
            timeout,
            () =>
                interrupt(TimeoutException('Server transfer probe timed out')));
    final output = StringBuffer();
    Future<void> drain(Stream<Uint8List> stream) async {
      await for (final text
          in const Utf8Decoder(allowMalformed: true).bind(stream)) {
        final remaining = 4096 - output.length;
        if (remaining > 0) {
          output.write(text.substring(0, text.length.clamp(0, remaining)));
        }
      }
    }

    Future<void> execute() async {
      final opened = await ssh.execute(command);
      if (finished) {
        opened.close();
        return;
      }
      process = opened;
      Future<void> sendInput() async {
        opened.stdin.add(Uint8List.fromList(utf8.encode(input)));
        await opened.stdin.close();
      }

      await Future.wait([
        drain(opened.stdout),
        drain(opened.stderr),
        sendInput(),
        opened.done,
      ]);
      if (opened.exitCode != 0) {
        throw StateError(output.isEmpty
            ? 'Server transfer command failed'
            : output.toString().trim());
      }
    }

    try {
      await Future.any([execute(), interrupted.future]);
      cancellationToken?.throwIfCancelled();
    } finally {
      finished = true;
      cancelTimer.cancel();
      deadline?.cancel();
      try {
        process?.kill(SSHSignal.TERM);
      } catch (_) {/* Best effort. */}
      process?.close();
    }
  }

  @override
  bool get supportsArchiveExtraction => true;

  @override
  Future<void> extractArchive(String archive, String destination) async {
    final command = RemoteArchive.command(archive, destination);
    await lease.write(
        '解压到「$destination」', (ssh) => _archiveCommand(ssh, command));
  }

  @override
  Future<void> compressEntries(List<RemoteEntry> entries, String destination) =>
      lease.write(
          '压缩到「$destination」',
          (ssh) => _archiveCommand(
              ssh,
              RemoteArchive.compressCommand(
                  entries.map((e) => e.path).toList(), destination)));

  Future<void> _archiveCommand(SSHClient ssh, String command) async {
    final process = await ssh.execute(command);
    final output = StringBuffer();
    Future<void> drain(Stream<Uint8List> stream) async {
      await for (final text
          in const Utf8Decoder(allowMalformed: true).bind(stream)) {
        final remaining = 8192 - output.length;
        if (remaining > 0) {
          output.write(text.substring(0, text.length.clamp(0, remaining)));
        }
      }
    }

    try {
      await process.stdin.close();
      await Future.wait([drain(process.stdout), drain(process.stderr)]);
      await process.done;
      if (process.exitCode == 127) {
        throw StateError('服务器未安装所需解压工具，请安装后重试');
      }
      if (process.exitCode != 0) {
        throw StateError(output.toString().trim().isEmpty
            ? 'Archive extraction failed'
            : output.toString().trim());
      }
    } finally {
      process.close();
    }
  }

  Future<SftpClient>? _opening;

  @override
  String get id => 'ssh:${session.id}';
  @override
  String get displayName => session.host.label;
  @override
  String get rootPath => '/';
  @override
  bool get isLocal => false;
  @override
  bool get supportsUnixPermissions => true;

  /// 这条连接上的 SFTP 客户端，只开一个（同时来的几步共用同一次打开）。打开失败不缓存，下次重开。
  Future<SftpClient> _sftpOn(SSHClient ssh) {
    final opening = _opening ??= _openSftp(ssh);
    opening.then((_) {}, onError: (_) {
      if (identical(_opening, opening)) _opening = null;
    });
    return opening;
  }

  /// 只读的一步：断了报 [ConnectionGone]。
  Future<T> _read<T>(Future<T> Function(SftpClient sftp) work) =>
      lease.read((ssh) async => work(await _sftpOn(ssh)));

  /// 会改动服务器的一步：发出前断了报 [ConnectionGone]，发出后断了报 [OutcomeUnknown]。
  Future<T> _write<T>(
          String action, Future<T> Function(SftpClient sftp) work) =>
      lease.write(action, (ssh) async => work(await _sftpOn(ssh)));

  static const _sftpHandshakeTimeout = Duration(seconds: 10);

  /// dartssh2 2.22.5 发出 SFTP 子系统请求后不看服务器的回复：服务器没开 SFTP（没装 sftp-server、
  /// sshd 没配 Subsystem）时，它会一直等 SFTP 版本回应，界面就无限转圈。
  /// 这里给握手加期限，到期关掉这个通道并说清原因；失败的客户端不缓存，下次重新打开。
  Future<SftpClient> _openSftp(SSHClient ssh) async {
    final client = await ssh.sftp();
    try {
      await client.handshake.timeout(_sftpHandshakeTimeout);
      return client;
    } on TimeoutException {
      unawaited(client.close());
      throw StateError(
        '服务器没有回应 SFTP（${_sftpHandshakeTimeout.inSeconds} 秒）：'
        '可能没有安装 sftp-server，或 sshd 没有配置 Subsystem sftp',
      );
    }
  }

  @override
  String displayPath(String path) => path;

  @override
  String joinPath(String path, String name) => joinRemotePath(path, name);

  @override
  String parentPath(String path) {
    final parts = path.split('/')..removeWhere((value) => value.isEmpty);
    if (parts.isNotEmpty) parts.removeLast();
    return '/${parts.join('/')}';
  }

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final entries = await _read((sftp) => sftp.listdir(path));
    return entries
        .where((item) =>
            item.filename != '.' &&
            item.filename != '..' &&
            !item.filename.endsWith('.shun-part'))
        .map((item) {
      final fullPath = joinPath(path, item.filename);
      final modified = item.attr.modifyTime;
      return RemoteEntry(
        name: item.filename,
        path: fullPath,
        isDirectory: item.attr.mode?.type == SftpFileType.directory,
        size: item.attr.size ?? 0,
        unixMode: item.attr.mode?.value,
        modifiedAt: modified == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(modified * 1000),
      );
    }).toList()
      ..sort(compareFileTransferEntries);
  }

  @override
  Stream<Uint8List> readStream(
    String path, {
    int startOffset = 0,
    TransferProgressCallback? onProgress,
  }) =>
      _guardedRead(path, startOffset: startOffset, onProgress: onProgress);

  /// 只读前 [maxBytes] 字节：只向服务器要这么多，不先把后面的预取进内存。
  @override
  Stream<Uint8List> readPrefix(String path, int maxBytes) =>
      _guardedRead(path, length: maxBytes);

  Stream<Uint8List> _guardedRead(
    String path, {
    int startOffset = 0,
    int? length,
    TransferProgressCallback? onProgress,
  }) {
    final SshLease borrowed;
    try {
      borrowed = lease;
    } on ConnectionGone catch (error) {
      return Stream.error(error);
    }
    return borrowed.readStream(_openRead(
      path,
      startOffset: startOffset,
      length: length,
      onProgress: onProgress,
    ));
  }

  Stream<Uint8List> _openRead(
    String path, {
    required int startOffset,
    required int? length,
    TransferProgressCallback? onProgress,
  }) async* {
    final sftp = await _sftpOn(lease.check());
    final file = await sftp.open(path, mode: SftpFileOpenMode.read);
    try {
      yield* Platform.isIOS
          ? file.read(
              offset: startOffset,
              length: length,
              onProgress: onProgress,
              maxPendingRequests: 8,
            )
          : file.read(
              offset: startOffset, length: length, onProgress: onProgress);
    } finally {
      // 连接已经断了时关句柄等不到回复，不等（没人拿得到它的结果）。
      if (lease.alive) await file.close();
    }
  }

  @override
  Future<void> writeStream(
    String path,
    Stream<Uint8List> stream, {
    int startOffset = 0,
    bool truncate = true,
    TransferProgressCallback? onProgress,
  }) async {
    final mode = truncate
        ? SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate
        : SftpFileOpenMode.create | SftpFileOpenMode.write;
    await _write('写入「$path」', (sftp) async {
      final file = await sftp.open(path, mode: mode);
      try {
        if (Platform.isIOS) {
          await _writeSftpStreamWithLimitedConcurrency(
            file,
            stream,
            startOffset: startOffset,
            onProgress: onProgress,
          );
        } else {
          await file
              .write(
                stream,
                offset: startOffset,
                onProgress: onProgress,
              )
              .done;
        }
      } finally {
        if (lease.alive) await file.close();
      }
    });
  }

  @override
  Future<int?> fileSize(String path) => _read((sftp) async {
        try {
          return (await sftp.stat(path)).size;
        } on SftpStatusError {
          return null;
        }
      });

  @override
  Future<FileStamp?> stamp(String path) => _read((sftp) async {
        try {
          final attrs = await sftp.stat(path);
          return FileStamp(attrs.size, attrs.modifyTime);
        } on SftpStatusError {
          return null;
        }
      });

  @override
  Future<void> mkdir(String path) =>
      _write('新建目录「$path」', (sftp) => sftp.mkdir(path));

  @override
  Future<void> ensureDirectory(String path) =>
      _write('新建目录「$path」', (sftp) async {
        try {
          await sftp.mkdir(path);
        } on SftpStatusError {
          final existing = await sftp.stat(path);
          if (existing.mode?.type != SftpFileType.directory) rethrow;
        }
      });

  /// dartssh2 的 rename 优先用 OpenSSH 的 posix-rename：目标已存在就直接替换，不报错。
  /// 要不要替换由调用方先问用户（[writeStreamAtomically] 的 replace）。
  @override
  Future<void> rename(String from, String to) =>
      _write('改名「$from」→「$to」', (sftp) => sftp.rename(from, to));

  @override
  Future<void> setPermissions(String path, int mode) async {
    if (mode < 0 || mode > 0xfff) {
      throw StateError('Unix 权限必须在 0000 到 7777 之间');
    }
    await _write(
      '改权限「$path」',
      (sftp) => sftp.setStat(
        path,
        SftpFileAttrs(mode: SftpFileMode.value(mode)),
      ),
    );
  }

  /// Retained for callers that copy within this SSH session.
  Future<int> copyEntry(RemoteEntry entry, String targetDirectory) =>
      transferEntry(this, entry, this, targetDirectory);

  /// 删目录是一串请求：中途断了，可能已经删掉了一部分，整体算「结果未知」。
  @override
  Future<void> delete(RemoteEntry entry) =>
      _write('删除「${entry.path}」', (sftp) => _delete(sftp, entry));

  Future<void> _delete(SftpClient sftp, RemoteEntry entry) async {
    if (!entry.isDirectory) return sftp.remove(entry.path);
    for (final child in await list(entry.path)) {
      await _delete(sftp, child);
    }
    await sftp.rmdir(entry.path);
  }
}

class LocalFileTransferService extends MountableFileTransferService {
  LocalFileTransferService._(
    this.rootPath, {
    this.isMounted = false,
    this.usesAppDocuments = false,
  });

  static Future<LocalFileTransferService> create() async {
    final documents = await getApplicationDocumentsDirectory();
    if (Platform.isIOS) {
      await documents.create(recursive: true);
      return LocalFileTransferService._(
        documents.path,
        isMounted: true,
        usesAppDocuments: true,
      );
    }
    final root = Directory(
      '${documents.path}${Platform.pathSeparator}shun',
    );
    await root.create(recursive: true);
    return LocalFileTransferService._(root.path);
  }

  @override
  String rootPath;
  @override
  bool isMounted;
  @override
  final bool usesAppDocuments;
  @override
  String? get mountedDirectoryName {
    if (!isMounted) return null;
    if (usesAppDocuments) return 'shun';
    return Uri.file(rootPath)
        .pathSegments
        .where((value) => value.isNotEmpty)
        .last;
  }

  @override
  String get id => 'local';
  @override
  String get displayName => usesAppDocuments
      ? '文件：shun'
      : isMounted
          ? '手机：${mountedDirectoryName ?? '已选目录'}'
          : '手机目录（未挂载）';
  @override
  bool get isLocal => true;

  @override
  Future<bool> mount() async {
    if (usesAppDocuments) {
      await Directory(rootPath).create(recursive: true);
      isMounted = true;
      return true;
    }
    final selected = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择要挂载到 SFTP 的手机目录',
    );
    if (selected == null || selected.isEmpty) return false;
    rootPath = selected;
    isMounted = true;
    return true;
  }

  @override
  String displayPath(String path) {
    if (!isMounted) return '尚未选择手机目录';
    if (path == rootPath) return '/';
    final relative = path.substring(rootPath.length).replaceAll('\\', '/');
    return relative.startsWith('/') ? relative : '/$relative';
  }

  @override
  String joinPath(String path, String name) =>
      '$path${Platform.pathSeparator}$name';

  @override
  String parentPath(String path) {
    if (path == rootPath) return rootPath;
    final parent = Directory(path).parent.path;
    return parent.length < rootPath.length ? rootPath : parent;
  }

  @override
  Future<List<RemoteEntry>> list(String path) async {
    if (!isMounted) return const [];
    final directory = Directory(path);
    if (!await directory.exists()) throw StateError('手机目录不存在');
    final result = <RemoteEntry>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity.path.endsWith('.shun-part')) continue;
      final stat = await entity.stat();
      result.add(
        RemoteEntry(
          name: entity.uri.pathSegments.where((value) => value.isNotEmpty).last,
          path: entity.path,
          isDirectory: stat.type == FileSystemEntityType.directory,
          size: stat.type == FileSystemEntityType.file ? stat.size : 0,
          modifiedAt: stat.modified,
        ),
      );
    }
    return result..sort(compareFileTransferEntries);
  }

  @override
  Stream<Uint8List> readStream(
    String path, {
    int startOffset = 0,
    TransferProgressCallback? onProgress,
  }) {
    final stream = asUint8ListStream(File(path).openRead(startOffset));
    return onProgress == null
        ? stream
        : trackTransferProgress(stream, onProgress);
  }

  @override
  Future<void> writeStream(
    String path,
    Stream<Uint8List> stream, {
    int startOffset = 0,
    bool truncate = true,
    TransferProgressCallback? onProgress,
  }) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    if (!truncate && await file.exists()) {
      final length = await file.length();
      if (length != startOffset) throw StateError('续传文件长度已变化');
    }
    final sink = file.openWrite(
      mode: truncate ? FileMode.writeOnly : FileMode.writeOnlyAppend,
    );
    try {
      await sink.addStream(
        onProgress == null ? stream : trackTransferProgress(stream, onProgress),
      );
    } finally {
      await sink.close();
    }
  }

  @override
  Future<int?> fileSize(String path) async {
    final file = File(path);
    return await file.exists() ? file.length() : null;
  }

  @override
  Future<FileStamp?> stamp(String path) async {
    final stat = await FileStat.stat(path);
    if (stat.type == FileSystemEntityType.notFound) return null;
    return FileStamp(stat.size, stat.modified.millisecondsSinceEpoch ~/ 1000);
  }

  @override
  Future<void> mkdir(String path) => Directory(path).create();

  @override
  Future<void> ensureDirectory(String path) =>
      Directory(path).create(recursive: true);

  @override
  Future<void> rename(String from, String to) async {
    final type = await FileSystemEntity.type(from, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await Directory(from).rename(to);
    } else {
      await File(from).rename(to);
    }
  }

  @override
  Future<void> delete(RemoteEntry entry) => entry.isDirectory
      ? Directory(entry.path).delete(recursive: true)
      : File(entry.path).delete();
}

Future<int> calculateTransferSize(
  FileTransferService source,
  RemoteEntry entry, {
  TransferCancellationToken? cancellationToken,
}) async {
  cancellationToken?.throwIfCancelled();
  if (!entry.isDirectory) return entry.size;
  var total = 0;
  for (final child in await source.list(entry.path)) {
    cancellationToken?.throwIfCancelled();
    total += await calculateTransferSize(
      source,
      child,
      cancellationToken: cancellationToken,
    );
  }
  return total;
}

/// Multiple tabs or duplicate profiles can point at the same endpoint.
bool sameTransferStorage(FileTransferService a, FileTransferService b) {
  if (a.id == b.id) return true;
  if (a is! SftpService || b is! SftpService) return false;
  final left = a.session.host;
  final right = b.session.host;
  return left.hostname.isNotEmpty &&
      left.hostname == right.hostname &&
      left.port == right.port &&
      left.username == right.username &&
      jsonEncode(left.data['hostChain']) ==
          jsonEncode(right.data['hostChain']) &&
      left.proxyProfileId == right.proxyProfileId &&
      jsonEncode(left.data['proxyConfig']) ==
          jsonEncode(right.data['proxyConfig']);
}

/// 把 [entry]（文件或整个目录）从 [source] 复制到 [target] 的 [targetDirectory] 里，经手机中转。
///
/// 每个文件先写到同目录的 `.名字.shun-part`，写完再换名：取消、断线时目标文件没动过
/// （[TransferCancelledException] / [TransferInterrupted]）；只有断在换名那一步才是结果未知（[OutcomeUnknown]）。
/// [resume] 接着已有的临时文件往后写，只有用户确认那是同一个文件传了一半时才传 true：
/// 临时文件只按名字认，认不出是不是另一个同名文件留下的。目标已有同名文件时不替换（[TargetExists]）。
Future<int> transferEntry(
  FileTransferService source,
  RemoteEntry entry,
  FileTransferService target,
  String targetDirectory, {
  TransferProgressCallback? onProgress,
  TransferCancellationToken? cancellationToken,
  bool resume = false,
}) async {
  cancellationToken?.throwIfCancelled();
  final targetPath = target.joinPath(targetDirectory, entry.name);
  final separator = source.isLocal ? Platform.pathSeparator : '/';
  if (sameTransferStorage(source, target) &&
      (targetPath == entry.path ||
          targetPath.startsWith('${entry.path}$separator'))) {
    throw StateError('不能把文件或目录复制到自身');
  }

  var transferred = 0;

  Future<void> copy(RemoteEntry current, String directory) async {
    cancellationToken?.throwIfCancelled();
    final currentTargetPath = target.joinPath(directory, current.name);
    if (current.isDirectory) {
      await target.ensureDirectory(currentTargetPath);
      for (final child in await source.list(current.path)) {
        cancellationToken?.throwIfCancelled();
        await copy(child, currentTargetPath);
      }
      return;
    }

    final partialPath = copyPartialPath(target, directory, current.name);
    var resumeOffset = resume ? await target.fileSize(partialPath) ?? 0 : 0;
    if (resumeOffset < 0 || resumeOffset > current.size) {
      resumeOffset = 0;
    }
    final baseline = transferred + resumeOffset;
    if (resumeOffset > 0) onProgress?.call(baseline);
    var fileProgress = 0;
    await _writePartial(
      currentTargetPath,
      partialPath,
      hasPartial: () => resumeOffset + fileProgress > 0,
      () => raceCancellation(
        target.writeStream(
          partialPath,
          cancelOnDemand(
            source.readStream(current.path, startOffset: resumeOffset),
            cancellationToken,
          ),
          startOffset: resumeOffset,
          truncate: resumeOffset == 0,
          onProgress: (value) {
            fileProgress = value;
            onProgress?.call(baseline + value);
          },
        ),
        cancellationToken,
      ),
    );
    cancellationToken?.throwIfCancelled();
    await _publish(target, partialPath, currentTargetPath, replace: false);
    transferred = baseline + fileProgress;
  }

  await copy(entry, targetDirectory);
  return transferred;
}

/// 把 [source] 交出去，用户一点取消就报 [TransferCancelledException] 并结束——不等下一块数据到
/// （服务器卡住时下一块可能永远不来）。
Stream<Uint8List> cancelOnDemand(
  Stream<Uint8List> source,
  TransferCancellationToken? token,
) {
  if (token == null) return source;
  late final StreamController<Uint8List> controller;
  StreamSubscription<Uint8List>? subscription;
  void cancelled() {
    if (controller.isClosed) return;
    controller.addError(const TransferCancelledException());
    unawaited(controller.close());
    unawaited(subscription?.cancel());
  }

  controller = StreamController<Uint8List>(
    onListen: () {
      if (token.isCancelled) return cancelled();
      subscription = source.listen(
        (chunk) {
          if (token.isCancelled) return cancelled();
          if (!controller.isClosed) controller.add(chunk);
        },
        onError: (Object error, StackTrace stack) {
          if (!controller.isClosed) controller.addError(error, stack);
        },
        onDone: () {
          if (token.isCancelled) return cancelled();
          if (!controller.isClosed) unawaited(controller.close());
        },
      );
      token.whenCancelled.then((_) => cancelled());
    },
    onPause: () => subscription?.pause(),
    onResume: () => subscription?.resume(),
    onCancel: () {
      unawaited(subscription?.cancel());
    },
  );
  return controller.stream;
}

/// 「传到另一栏」用的临时文件：目标目录里的 `.名字.shun-part`。
String copyPartialPath(
        FileTransferService target, String directory, String name) =>
    target.joinPath(directory, '.$name.shun-part');

/// 上传用的临时文件：`目标.shun-part`。
String uploadPartialPath(String finalPath) => '$finalPath.shun-part';

/// 先写到 [uploadPartialPath]，写完再换成 [finalPath]：中途取消、断线，[finalPath] 都没动过。
///
/// [resume]：接着已有的临时文件往后写。只有用户确认那是同一个文件传了一半时才传 true（见 [transferEntry]）。
/// [replace]：[finalPath] 已经存在时替换它。为 false 时换名前再查一次，有了就报 [TargetExists]。
/// 查完到换名之间别人放进来的同名文件仍会被替换：dartssh2 的改名在 OpenSSH 上走 posix-rename，
/// 没有「不替换」的写法（窗口是一次请求来回）。
Future<int> writeStreamAtomically(
  FileTransferService target,
  String finalPath,
  Stream<Uint8List> source, {
  required int totalBytes,
  TransferProgressCallback? onProgress,
  TransferCancellationToken? cancellationToken,
  bool resume = false,
  bool replace = false,
}) async {
  final partialPath = uploadPartialPath(finalPath);
  var resumeOffset = resume ? await target.fileSize(partialPath) ?? 0 : 0;
  if (resumeOffset < 0 || resumeOffset > totalBytes) resumeOffset = 0;
  if (resumeOffset > 0) onProgress?.call(resumeOffset);
  var written = 0;
  await _writePartial(
    finalPath,
    partialPath,
    hasPartial: () => resumeOffset + written > 0,
    () => raceCancellation(
      target.writeStream(
        partialPath,
        cancelOnDemand(
          _skipBytes(source, resumeOffset),
          cancellationToken,
        ),
        startOffset: resumeOffset,
        truncate: resumeOffset == 0,
        onProgress: (value) {
          written = value;
          onProgress?.call(resumeOffset + value);
        },
      ),
      cancellationToken,
    ),
  );
  cancellationToken?.throwIfCancelled();
  await _publish(target, partialPath, finalPath, replace: replace);
  return resumeOffset + written;
}

/// 写临时文件这一段。连接断了（读源断的、写目标断的都算），目标文件都没动过 → [TransferInterrupted]。
/// 一个字节都没写、连接在发出前就没了的，原样报 [ConnectionGone]（什么都没做）。
Future<void> _writePartial(
  String finalPath,
  String partialPath,
  Future<void> Function() write, {
  required bool Function() hasPartial,
}) async {
  try {
    await write();
  } on OutcomeUnknown {
    throw TransferInterrupted(finalPath, partialPath, hasPartial: hasPartial());
  } on ConnectionGone {
    if (!hasPartial()) rethrow;
    throw TransferInterrupted(finalPath, partialPath);
  }
}

/// 把写好的临时文件换成目标。只有这一步会动目标：断在这里是「结果未知」（[OutcomeUnknown]）。
Future<void> _publish(
  FileTransferService target,
  String partialPath,
  String finalPath, {
  required bool replace,
}) async {
  if (!replace) {
    final int? existing;
    try {
      existing = await target.fileSize(finalPath);
    } on ConnectionGone {
      throw TransferInterrupted(finalPath, partialPath);
    }
    if (existing != null) throw TargetExists(finalPath);
  }
  try {
    await target.rename(partialPath, finalPath);
  } on ConnectionGone {
    // 还没发出去：目标没动，写完的内容都在临时文件里。
    throw TransferInterrupted(finalPath, partialPath);
  }
}

Stream<Uint8List> _skipBytes(Stream<Uint8List> source, int count) async* {
  var remaining = count;
  await for (final chunk in source) {
    if (remaining >= chunk.length) {
      remaining -= chunk.length;
      continue;
    }
    if (remaining > 0) {
      yield Uint8List.sublistView(chunk, remaining);
      remaining = 0;
    } else {
      yield chunk;
    }
  }
  if (remaining > 0) throw StateError('源文件长度不足，无法继续传输');
}

Stream<Uint8List> asUint8ListStream(Stream<List<int>> source) => source.map(
      (chunk) => chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
    );

Stream<Uint8List> trackTransferProgress(
  Stream<Uint8List> source,
  TransferProgressCallback onProgress,
) async* {
  var transferred = 0;
  await for (final chunk in source) {
    yield chunk;
    transferred += chunk.length;
    onProgress(transferred);
  }
}

Future<void> _writeSftpStreamWithLimitedConcurrency(
  SftpFile file,
  Stream<Uint8List> stream, {
  int startOffset = 0,
  TransferProgressCallback? onProgress,
  int maxPendingWrites = 8,
}) async {
  const maxChunkSize = 16 * 1024;
  var offset = startOffset;
  var acknowledged = 0;
  var batch = <Future<int>>[];

  Future<void> flushBatch() async {
    if (batch.isEmpty) return;
    final completed = await Future.wait(batch);
    acknowledged += completed.fold(0, (total, value) => total + value);
    onProgress?.call(acknowledged);
    batch = <Future<int>>[];
  }

  await for (final chunk in _splitByteChunks(stream, maxChunkSize)) {
    final writeOffset = offset;
    offset += chunk.length;
    batch.add(
      file.writeBytes(chunk, offset: writeOffset).then((_) => chunk.length),
    );
    if (batch.length >= maxPendingWrites) await flushBatch();
  }
  await flushBatch();
}

Stream<Uint8List> _splitByteChunks(
  Stream<Uint8List> source,
  int maxChunkSize,
) async* {
  await for (final chunk in source) {
    if (chunk.length <= maxChunkSize) {
      yield chunk;
      continue;
    }
    for (var offset = 0; offset < chunk.length; offset += maxChunkSize) {
      final end = (offset + maxChunkSize).clamp(0, chunk.length);
      yield Uint8List.sublistView(chunk, offset, end);
    }
  }
}

String joinRemotePath(String path, String name) =>
    path == '/' ? '/$name' : '$path/$name';

int compareFileTransferEntries(RemoteEntry a, RemoteEntry b) {
  if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}
