part of 'sftp_screen.dart';

class _SftpPane extends StatefulWidget {
  const _SftpPane({
    super.key,
    required this.label,
    required this.service,
    required this.sources,
    required this.onSourceChanged,
    required this.onPhoneMountChanged,
    required this.clipboard,
    required this.sharedTransferBusy,
    required this.onPaste,
    this.onCopyToOther,
    this.onOpenInTerminal,
  });

  final String label;
  final FileTransferService service;
  final List<FileTransferService> sources;
  final ValueChanged<String> onSourceChanged;
  final VoidCallback onPhoneMountChanged;
  final ValueNotifier<FileSelection?> clipboard;
  final bool sharedTransferBusy;
  final Future<void> Function(FileSelection, FileTransferService, String)
      onPaste;
  final ValueChanged<RemoteEntry>? onCopyToOther;
  final ValueChanged<String>? onOpenInTerminal;

  @override
  State<_SftpPane> createState() => _SftpPaneState();
}

class _SftpPaneState extends State<_SftpPane> {
  late String path = widget.service.rootPath;
  var _loading = false;
  var _listGeneration = 0;
  Object? _error;
  List<RemoteEntry> _entries = const [];
  String? _highlightedEntryPath;
  _TransferProgressSnapshot? _transfer;
  TransferCancellationToken? _transferCancellation;
  bool _extracting = false;
  String _archiveStatus = '正在服务器上解压…';
  bool _selecting = false;
  final _selected = <String>{};
  List<RemoteEntry> get _selection =>
      _entries.where((e) => _selected.contains(e.path)).toList();

  FileTransferService get service => widget.service;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => refresh());
  }

  @override
  void didUpdateWidget(covariant _SftpPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.service, widget.service)) {
      _selected.clear();
      _selecting = false;
      path = widget.service.rootPath;
      _entries = const [];
      WidgetsBinding.instance.addPostFrameCallback((_) => refresh());
    }
  }

  @override
  Widget build(BuildContext context) {
    final level = prism.SurfaceContext(context).raisedSurfaceLevel;
    return Material(
      shape: prism.AppShape.lg,
      clipBehavior: Clip.antiAlias,
      color: level.colorOf(prism.Theme.of(context).colorScheme),
      child: prism.SurfaceScope(level: level, child: _paneContents()),
    );
  }

  Widget _paneContents() => LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 260;
          final mountable = service is MountableFileTransferService
              ? service as MountableFileTransferService
              : null;
          final localReady = mountable?.isMounted ?? true;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: PopupMenuButton<String>(
                        key: const ValueKey('sftp-source'),
                        tooltip: localized('切换 ${widget.label} 文件来源'),
                        initialValue: service.id,
                        onSelected: widget.onSourceChanged,
                        itemBuilder: (_) => [
                          for (final source in widget.sources)
                            PopupMenuItem(
                              value: source.id,
                              child: ListTile(
                                leading: Icon(source.isLocal
                                    ? Icons.phone_android
                                    : Icons.dns_outlined),
                                title: LText(source.displayName),
                                subtitle: LText(
                                  source is MountableFileTransferService
                                      ? source.usesAppDocuments
                                          ? '文件 App：我的 iPhone/iPad/shun'
                                          : source.isMounted
                                              ? '已挂载：${source.mountedDirectoryName}'
                                              : '点文件夹按钮选择手机目录'
                                      : '已连接 SSH',
                                ),
                              ),
                            ),
                        ],
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 6,
                          ),
                          decoration: ShapeDecoration(
                            color: prism.SurfaceContext(context)
                                .raisedSurfaceLevel
                                .colorOf(prism.Theme.of(context).colorScheme),
                            shape: prism.AppShape.full,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                service.isLocal
                                    ? Icons.phone_android
                                    : Icons.dns_outlined,
                                size: 16,
                              ),
                              const SizedBox(width: 5),
                              Expanded(
                                child: LText(
                                  service.displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: prism.AppTextStyle.caption2
                                      .of(context, emphasized: true),
                                ),
                              ),
                              const Icon(Icons.arrow_drop_down, size: 18),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 3),
                    ShunPill(localizedOf(context, widget.label)),
                  ],
                ),
              ),
              // 没挂载时路径行只会写「尚未选择手机目录」，和上面的「手机目录（未挂载）」、
              // 下面的空列表提示说的是同一件事，不再重复一遍。
              if (localReady)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: LText(
                      service.displayPath(path),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: prism.AppTextStyle.caption2
                          .of(context)
                          .copyWith(fontFamily: 'monospace'),
                    ),
                  ),
                ),
              SizedBox(
                height: 38,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Expanded(
                      child: _toolbar(
                        Icons.arrow_upward,
                        '上级',
                        !localReady || path == service.rootPath ? null : _up,
                      ),
                    ),
                    Expanded(
                      child: _toolbar(
                        Icons.refresh,
                        '刷新',
                        _loading || !localReady ? null : refresh,
                      ),
                    ),
                    if (widget.onOpenInTerminal != null)
                      Expanded(
                        child: _toolbar(
                          Icons.terminal_outlined,
                          '在终端中打开当前目录',
                          _loading
                              ? null
                              : () => widget.onOpenInTerminal!(path),
                        ),
                      ),
                    if (mountable != null && !mountable.usesAppDocuments)
                      Expanded(
                        child: _toolbar(
                          Icons.folder_open_outlined,
                          mountable.isMounted ? '更换挂载目录' : '挂载手机目录',
                          _mountPhoneDirectory,
                        ),
                      ),
                    Expanded(
                      child: _toolbar(
                        service.isLocal
                            ? Icons.add_to_photos
                            : Icons.upload_file,
                        service.isLocal ? '导入其他手机文件' : '上传文件',
                        localReady && _transfer == null ? _importFile : null,
                      ),
                    ),
                    Expanded(
                      child: _toolbar(
                        Icons.create_new_folder_outlined,
                        '新建',
                        localReady ? _mkdir : null,
                      ),
                    ),
                  ],
                ),
              ),
              if (_loading) const LinearProgressIndicator(minHeight: 2),
              ValueListenableBuilder<FileSelection?>(
                  valueListenable: widget.clipboard,
                  builder: (context, clipboard, _) => Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 2,
                          children: [
                            if (_selecting) ...[
                              ShunButton(
                                key: const ValueKey('sftp-select-all'),
                                kind: ShunButtonKind.text,
                                label:
                                    '${localized('全选')} (${_selected.length})',
                                onPressed: () => setState(() {
                                  if (_selected.length == _entries.length) {
                                    _selected.clear();
                                  } else {
                                    _selected
                                        .addAll(_entries.map((e) => e.path));
                                  }
                                }),
                              ),
                              IconButton(
                                  tooltip: localized('复制'),
                                  onPressed: _selected.isEmpty
                                      ? null
                                      : () => _copySelection(false),
                                  icon: const Icon(Icons.copy)),
                              IconButton(
                                  tooltip: localized('剪切'),
                                  onPressed: _selected.isEmpty
                                      ? null
                                      : () => _copySelection(true),
                                  icon: const Icon(Icons.cut)),
                              if (service.isLocal ||
                                  service.supportsArchiveExtraction)
                                IconButton(
                                    tooltip: localized('压缩'),
                                    onPressed: _selected.isEmpty || _extracting
                                        ? null
                                        : _compressSelection,
                                    icon:
                                        const Icon(Icons.folder_zip_outlined)),
                              IconButton(
                                  tooltip: localized('删除所选文件'),
                                  onPressed: _selected.isEmpty
                                      ? null
                                      : _deleteSelection,
                                  icon: const Icon(Icons.delete_outline)),
                              IconButton(
                                  tooltip: localized('取消多选'),
                                  onPressed: () => setState(() {
                                        _selecting = false;
                                        _selected.clear();
                                      }),
                                  icon: const Icon(Icons.close)),
                            ],
                            if (clipboard != null) ...[
                              ShunButton(
                                key: const ValueKey('sftp-paste'),
                                kind: ShunButtonKind.text,
                                icon: Icons.paste,
                                label:
                                    '${localized('粘贴')} (${clipboard.entries.length})',
                                onPressed: () =>
                                    widget.onPaste(clipboard, service, path),
                              ),
                              IconButton(
                                  tooltip: localized('清空文件剪贴板'),
                                  onPressed: () =>
                                      widget.clipboard.value = null,
                                  icon: const Icon(Icons.clear)),
                            ],
                          ])),
              if (_extracting) const LinearProgressIndicator(minHeight: 2),
              if (_extracting)
                LText(
                  _archiveStatus,
                  style: prism.AppTextStyle.caption1.of(context),
                ),
              if (_transfer != null)
                _TransferProgressView(
                  progress: _transfer!,
                  compact: true,
                  onCancel: _transferCancellation?.cancel,
                ),
              if (_error != null)
                InkWell(
                  onTap: refresh,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: LText(
                      '加载失败，点按重试\n$_error',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: prism.AppTextStyle.caption2.of(context).copyWith(
                            color: prism.Theme.of(context).colorScheme.error,
                          ),
                    ),
                  ),
                ),
              Expanded(
                child: _entries.isEmpty && !_loading
                    ? mountable != null &&
                            !mountable.isMounted &&
                            !mountable.usesAppDocuments
                        ? _mountHint()
                        : Center(
                            child: SingleChildScrollView(
                              child: EmptyState(
                                icon: Icons.folder_open_outlined,
                                title: mountable?.usesAppDocuments == true
                                    ? 'shun 文件夹为空'
                                    : service.isLocal
                                        ? '挂载目录为空'
                                        : '目录为空',
                              ),
                            ),
                          )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        itemCount: _entries.length,
                        itemBuilder: (context, index) =>
                            _entryTile(_entries[index], compact),
                      ),
              ),
            ],
          );
        },
      );

  Widget _entryTile(RemoteEntry entry, bool compact) => _FileRow(
        key: ValueKey('sftp-entry-${entry.path}'),
        entry: entry,
        compact: compact,
        selecting: _selecting,
        checked: _selected.contains(entry.path),
        highlighted: entry.path == _highlightedEntryPath,
        onToggle: () => _toggleEntry(entry),
        onTap: () => _selecting
            ? _toggleEntry(entry)
            : entry.isDirectory
                ? _open(entry.path)
                : _edit(entry),
        menu: PopupMenuButton<String>(
          tooltip: localized('文件操作'),
          padding: EdgeInsets.zero,
          onSelected: (value) => _entryAction(value, entry),
          itemBuilder: (_) => [
            const PopupMenuItem(
                value: 'select',
                child: ListTile(
                    leading: Icon(Icons.checklist), title: LText('多选'))),
            if (!service.isLocal &&
                service.supportsArchiveExtraction &&
                !entry.isDirectory &&
                RemoteArchive.extension(entry.name) != null)
              PopupMenuItem(
                value: 'extract',
                enabled: !_extracting,
                child: const ListTile(
                  leading: Icon(Icons.unarchive_outlined),
                  title: LText('解压缩'),
                ),
              ),
            if (widget.onCopyToOther != null)
              const PopupMenuItem(
                value: 'copy',
                child: ListTile(
                  leading: Icon(Icons.compare_arrows),
                  title: LText('传输到另一栏'),
                ),
              ),
            if (!entry.isDirectory)
              const PopupMenuItem(
                value: 'share',
                child: ListTile(
                  leading: Icon(Icons.ios_share_outlined),
                  title: LText('下载 / 分享'),
                ),
              ),
            const PopupMenuItem(
              value: 'copy-path',
              child: ListTile(
                leading: Icon(Icons.content_copy_outlined),
                title: LText('复制文件路径'),
              ),
            ),
            if (service.supportsUnixPermissions)
              const PopupMenuItem(
                value: 'permissions',
                child: ListTile(
                  leading: Icon(Icons.admin_panel_settings_outlined),
                  title: LText('修改文件权限'),
                ),
              ),
            const PopupMenuItem(
              value: 'rename',
              child: ListTile(
                leading: Icon(Icons.drive_file_rename_outline),
                title: LText('重命名'),
              ),
            ),
            const PopupMenuItem(
              value: 'delete',
              child: ListTile(
                leading: Icon(Icons.delete_outline),
                title: LText('删除'),
              ),
            ),
          ],
        ),
      );

  Widget _toolbar(IconData icon, String tooltip, VoidCallback? onPressed) =>
      IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        visualDensity: VisualDensity.compact,
        iconSize: 20,
        icon: Icon(icon),
      );

  Future<void> refresh() async {
    if (!mounted) return;
    final generation = ++_listGeneration;
    final source = service;
    final directory = path;
    bool current() =>
        mounted &&
        generation == _listGeneration &&
        identical(source, service) &&
        directory == path;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await source.list(directory);
      if (current()) {
        setState(() {
          _entries = entries;
          _selected.removeWhere((p) => !entries.any((e) => e.path == p));
        });
      }
    } catch (error) {
      if (current()) setState(() => _error = error);
    } finally {
      if (current()) setState(() => _loading = false);
    }
  }

  void resetAfterPhoneMount() {
    if (!service.isLocal) return;
    setState(() {
      path = service.rootPath;
      _entries = const [];
      _error = null;
      _highlightedEntryPath = null;
    });
    refresh();
  }

  /// 没挂载时那一栏里直接给按钮和系统的限制。以前只写「点上方的文件夹图标」，图标没字，
  /// 选了 Download 被系统拦下来也不知道为什么（R26 所有者报「手机目录无法挂载」）。
  Widget _mountHint() => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ShunButton(
                key: const ValueKey('sftp-mount-phone-directory'),
                kind: ShunButtonKind.tonal,
                icon: Icons.folder_open_outlined,
                label: '选择手机目录',
                onPressed: _mountPhoneDirectory,
              ),
              const SizedBox(height: 8),
              LText(
                _mountLimits,
                textAlign: TextAlign.center,
                style: prism.AppTextStyle.caption1.of(context).copyWith(
                      color:
                          prism.Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      );

  static const _mountLimits = 'Android 不让选整个内部存储和「Download」文件夹本身（「使用此文件夹」是灰的），'
      '选它们下面的一个文件夹；没有就在选择器里新建一个。';
  static const _mountCancelled = '没有选上目录。Android 不让选整个内部存储和「Download」文件夹本身，'
      '选它们下面的一个文件夹；没有就在选择器里新建一个。';

  Future<void> _mountPhoneDirectory() async {
    final mountable = service is MountableFileTransferService
        ? service as MountableFileTransferService
        : null;
    if (mountable == null) return;
    if (widget.sharedTransferBusy ||
        _transfer != null ||
        _extracting ||
        mountable.activeOperations > 0) {
      // 以前这里不声不响地返回，点了像没反应。
      _message('正在传文件，传完再换目录');
      return;
    }
    try {
      if (!await mountable.mount()) {
        if (!mountable.isMounted) _message(_mountCancelled);
        return;
      }
      widget.clipboard.value = null;
      _selected.clear();
      _selecting = false;
      widget.onPhoneMountChanged();
      _message('已挂载手机目录：${mountable.mountedDirectoryName ?? '已选目录'}');
    } catch (error) {
      _message('挂载目录失败：$error');
    }
  }

  void _open(String value) {
    setState(() {
      _selected.clear();
      _selecting = false;
      path = value;
      _entries = const [];
      _highlightedEntryPath = null;
    });
    refresh();
  }

  Future<void> openRemoteFileLocation(String filePath) async {
    if (service.isLocal) return;
    setState(() {
      _selected.clear();
      _selecting = false;
      path = service.parentPath(filePath);
      _entries = const [];
      _error = null;
      _highlightedEntryPath = filePath;
    });
    await refresh();
  }

  void _up() => _open(service.parentPath(path));

  /// 打开文件看 / 改。超过 [previewLimit] 不打开，问要不要下载到手机——不自动下：大文件走的是用户的流量。
  Future<void> _edit(RemoteEntry entry) async {
    final source = service;
    if (entry.size > previewLimit) return _offerDownload(entry);
    try {
      var opened = await source.stamp(entry.path);
      final content = await source.readTextBounded(entry.path);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => Dialog.fullscreen(
          child: SftpEditor(
              name: entry.name,
              content: content,
              onSave: (value) async {
                await _saveEdited(source, entry.path, value, opened);
                opened = await source.stamp(entry.path);
              }),
        ),
      );
      if (mounted && identical(source, service)) await refresh();
    } on PreviewTooLarge {
      // 列表里的大小过时了：文件在变大。只多读了 1 字节就停了。
      if (mounted) await _offerDownload(entry);
    } catch (error) {
      _message('$error');
    }
  }

  Future<void> _offerDownload(RemoteEntry entry) async {
    final size = entry.size > previewLimit ? formatBytes(entry.size) : null;
    final note = localized('超过在 App 里预览的上限（1 MB），没有打开。可以下载到手机，用别的 App 看。');
    final download = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const LText('文件太大，不在这里打开'),
        content: Text('${entry.name}${size == null ? '' : '\n$size'}\n\n$note'),
        actions: _confirmActions(context, '下载'),
      ),
    );
    if (download == true && mounted) await _share(entry);
  }

  /// 编辑器的保存。写之前先看服务器上的文件在打开之后变没变：变了要用户确认才覆盖，
  /// 不然会把别人刚做的修改整个冲掉。
  ///
  /// 原地写（不先写临时文件再换名）：换名会把文件的权限、属主换成新建文件的默认值，
  /// 改个 0600 的配置文件会变成谁都能读。代价是写到一半断线时文件可能只写了一半，所以那种情况说清楚。
  Future<void> _saveEdited(FileTransferService source, String filePath,
      String text, FileStamp? opened) async {
    final now = await source.stamp(filePath);
    if (now != opened) {
      if (!mounted) throw const _NotSaved();
      final overwrite = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const LText('服务器上的文件变了'),
          content:
              const LText('你打开之后，这个文件在服务器上被改过（或被删了）。保存会用编辑器里的内容整个替换它，那些修改就没了。'),
          actions: _confirmActions(context, '仍然保存'),
        ),
      );
      if (overwrite != true) throw const _NotSaved();
    }
    try {
      await source.writeText(filePath, text);
    } on OutcomeUnknown {
      throw const _SaveOutcomeUnknown();
    }
  }

  Future<void> _importFile() async {
    if (_transfer != null) return;
    final result = await FilePicker.platform.pickFiles(withReadStream: true);
    if (result == null) return;
    final file = result.files.single;
    try {
      await _uploadPicked(file);
    } finally {
      // 选择器把要传的文件整份复制在缓存里（可能就是一把私钥），传完、取消、失败都删。
      await discardPickedCopy(file);
    }
  }

  Future<void> _uploadPicked(PlatformFile file) async {
    Stream<Uint8List>? stream;
    if (file.readStream != null) {
      stream = asUint8ListStream(file.readStream!);
    } else if (file.path != null) {
      stream = asUint8ListStream(File(file.path!).openRead());
    } else if (file.bytes != null) {
      stream = Stream.value(file.bytes!);
    }
    if (stream == null) return;
    final target = service;
    final finalPath = target.joinPath(path, file.name);
    // 替不替换、续不续传都由用户定，不替用户猜（R24）。
    final bool replace;
    final bool resume;
    try {
      final existing = await target.stamp(finalPath);
      if (!mounted) return;
      if (existing != null &&
          !await confirmReplaceDialog(context, file.name, existing)) {
        return;
      }
      replace = existing != null;
      if (!mounted) return;
      final choice = await askResumeDialog(
          context, target, uploadPartialPath(finalPath), file.name, file.size);
      if (choice == null) return;
      resume = choice;
    } catch (error) {
      _message('$error');
      return;
    }
    if (!mounted || _transfer != null) return;
    final tracker = _beginTransfer(
      '${service.isLocal ? '导入' : '上传'} ${file.name}',
      file.size,
    );
    try {
      await writeStreamAtomically(
        target,
        finalPath,
        stream,
        totalBytes: file.size,
        onProgress: tracker.update,
        cancellationToken: _transferCancellation,
        resume: resume,
        replace: replace,
      );
      tracker.finish();
      if (identical(target, service)) await refresh();
      _message(target.isLocal ? '已导入到挂载目录' : '上传完成');
    } on TransferCancelledException {
      _message('已取消：目标位置的同名文件没有动过。已传的部分留着，下次传同一个文件时可以选续传。');
    } catch (error) {
      _message('$error');
    } finally {
      _endTransfer();
    }
  }

  Future<void> _share(RemoteEntry entry) async {
    if (_transfer != null) return;
    // 下到一半的临时文件：没下完就删掉，不留在手机缓存里冒充完整文件。
    File? incomplete;
    try {
      late final File file;
      if (service is LocalFileTransferService) {
        file = File(entry.path);
      } else {
        final directory = await getTemporaryDirectory();
        file = incomplete = File(
          '${directory.path}/${DateTime.now().millisecondsSinceEpoch}-${entry.name}',
        );
        final sink = file.openWrite(mode: FileMode.writeOnly);
        final tracker = _beginTransfer('下载 ${entry.name}', entry.size);
        try {
          await sink.addStream(
            cancelOnDemand(
              service.readStream(entry.path, onProgress: tracker.update),
              _transferCancellation,
            ),
          );
          tracker.finish();
        } finally {
          await sink.close();
          _endTransfer();
        }
        incomplete = null;
      }
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], title: entry.name),
      );
    } on TransferCancelledException {
      _message('下载已取消');
    } catch (error) {
      _message('$error');
    } finally {
      if (incomplete case final file?) {
        try {
          await file.delete();
        } catch (_) {
          // 缓存目录系统会自己清；删不掉不影响提示。
        }
      }
    }
  }

  Future<void> _mkdir() async {
    final name = await _ask('新建目录', '目录名');
    if (name == null || name.isEmpty) return;
    try {
      await service.mkdir(service.joinPath(path, name));
      await refresh();
    } catch (error) {
      _message('$error');
    }
  }

  Future<void> _entryAction(String action, RemoteEntry entry) async {
    if (action == 'select') {
      _toggleEntry(entry);
      return;
    }
    if (action == 'extract') {
      final source = service;
      if (source.isLocal || !source.supportsArchiveExtraction || _extracting) {
        return;
      }
      final destination = await _ask(
          '解压缩',
          '新建解压目录的绝对路径（须不存在）',
          source.joinPath(source.parentPath(entry.path),
              RemoteArchive.directoryName(entry.name)));
      if (destination == null || destination.isEmpty || !mounted) return;
      setState(() {
        _extracting = true;
        _archiveStatus = '正在服务器上解压…';
      });
      try {
        await source.extractArchive(entry.path, destination);
        _message('解压完成');
      } catch (error) {
        _message('解压失败：$error');
      } finally {
        if (mounted) {
          setState(() => _extracting = false);
          if (identical(service, source)) await refresh();
        }
      }
      return;
    }
    if (action == 'copy') {
      widget.onCopyToOther?.call(entry);
      return;
    }
    if (action == 'share') return _share(entry);
    if (action == 'copy-path') {
      await Clipboard.setData(ClipboardData(text: entry.path));
      _message('文件路径已复制');
      return;
    }
    try {
      if (action == 'permissions') {
        final mode = await _askPermissions(entry);
        if (mode == null) return;
        await service.setPermissions(entry.path, mode);
        _message('权限已修改为 ${formatUnixPermissions(mode)}');
      } else if (action == 'rename') {
        final name = await _ask('重命名', '新名称', entry.name);
        if (name != null && name.isNotEmpty && name != entry.name) {
          await service.rename(entry.path, service.joinPath(path, name));
        }
      } else if (action == 'delete') {
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: LText('删除 ${entry.name}？'),
            content: LText(service.isLocal
                ? '文件将从当前挂载的手机目录删除，无法撤销。'
                : '此操作会直接修改远程服务器，无法撤销。'),
            actions: _confirmActions(context, '删除'),
          ),
        );
        if (ok == true) await service.delete(entry);
      }
      await refresh();
    } catch (error) {
      _message('$error');
    }
  }

  void _toggleEntry(RemoteEntry entry) => setState(() {
        _selecting = true;
        if (!_selected.remove(entry.path)) _selected.add(entry.path);
      });

  void _copySelection(bool move) {
    widget.clipboard.value = FileSelection(service, _selection, move: move);
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  Future<void> _compressSelection() async {
    final source = service;
    final entries = _selection;
    final directory = path;
    final name = await _ask(
        '压缩',
        source.isLocal ? '压缩文件名（.zip）' : '压缩文件名（.tar.gz 或 .zip）',
        source.isLocal ? 'archive.zip' : 'archive.tar.gz');
    if (name == null || name.isEmpty || !mounted) return;
    if (name.contains('/') || name.contains('\\') || name.contains('\u0000')) {
      _message('文件名不能包含路径分隔符');
      return;
    }
    setState(() {
      _extracting = true;
      _archiveStatus = '正在压缩…';
    });
    source.activeOperations++;
    try {
      if (source.isLocal) {
        await zipSelection(source, entries, source.joinPath(directory, name));
      } else {
        await source.compressEntries(entries, source.joinPath(directory, name));
      }
      _message('压缩完成');
      if (identical(source, service)) await refresh();
    } catch (e) {
      _message('压缩失败：$e');
    } finally {
      source.activeOperations--;
      if (mounted) setState(() => _extracting = false);
    }
  }

  Future<void> _deleteSelection() async {
    final source = service;
    final entries = _selection;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
            title: const LText('删除所选文件'),
            content: LText('${entries.length}\n${localized('此操作无法撤销。')}'),
            actions: _confirmActions(context, '删除')));
    if (confirmed != true) return;
    source.activeOperations++;
    try {
      for (final entry in entries) {
        await source.delete(entry);
      }
    } catch (e) {
      _message('$e');
    } finally {
      source.activeOperations--;
      if (mounted && identical(source, service)) await refresh();
    }
  }

  Future<String?> _ask(String title, String hint, [String initial = '']) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: LText(title),
        content: TextField(
          key: const ValueKey('sftp-dialog-input'),
          controller: controller,
          autofocus: true,
          decoration: LInputDecoration(hintText: hint),
        ),
        actions: [
          ShunButton(
            key: const ValueKey('sftp-dialog-cancel'),
            kind: ShunButtonKind.text,
            label: '取消',
            onPressed: () => Navigator.pop(context),
          ),
          ShunButton(
            key: const ValueKey('sftp-dialog-confirm'),
            label: '确定',
            onPressed: () => Navigator.pop(context, controller.text.trim()),
          ),
        ],
      ),
    );
  }

  Future<int?> _askPermissions(RemoteEntry entry) => showDialog<int>(
        context: context,
        builder: (_) => SftpPermissionsDialog(
            name: entry.name,
            initialMode: formatUnixPermissions(entry.unixMode) ??
                (entry.isDirectory ? '755' : '644')),
      );

  void _message(String value) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: LText(value)));
    }
  }

  _TransferProgressTracker _beginTransfer(String title, int totalBytes) {
    _transferCancellation = TransferCancellationToken();
    final tracker = _TransferProgressTracker(
      title: title,
      totalBytes: totalBytes,
      onChanged: (progress) {
        if (mounted) setState(() => _transfer = progress);
      },
    )..start();
    return tracker;
  }

  void _endTransfer() {
    _transferCancellation = null;
    if (mounted) setState(() => _transfer = null);
  }
}

/// 用户在「服务器上的文件变了」里点了取消：编辑器显示这一句，内容留着。
class _NotSaved implements Exception {
  const _NotSaved();

  @override
  String toString() => '没有保存：服务器上的文件在你打开之后变了。编辑器里的内容还在。';
}

/// 原地写到一半连接断了：文件可能只写了一半。
class _SaveOutcomeUnknown implements Exception {
  const _SaveOutcomeUnknown();

  @override
  String toString() =>
      '保存时连接断了：不知道服务器上的文件写完整了没有，可能只写了一半。编辑器里的内容还在：先复制出来，重新连接后核对再保存。不会自动重试。';
}

class _TransferProgressSnapshot {
  const _TransferProgressSnapshot({
    required this.title,
    required this.transferredBytes,
    required this.totalBytes,
    required this.bytesPerSecond,
    required this.preparing,
    this.status,
  });

  final String title;
  final int transferredBytes;
  final int? totalBytes;
  final double bytesPerSecond;
  final bool preparing;
  final String? status;

  double? get value {
    final total = totalBytes;
    if (preparing || total == null || total <= 0) return null;
    return (transferredBytes / total).clamp(0.0, 1.0).toDouble();
  }
}

class _TransferProgressTracker {
  _TransferProgressTracker({
    required this.title,
    required int? totalBytes,
    required ValueChanged<_TransferProgressSnapshot> onChanged,
  })  : _totalBytes = totalBytes,
        _onChanged = onChanged;

  static const _minimumUpdateInterval = Duration(milliseconds: 200);
  static const _minimumByteDelta = 256 * 1024;

  final String title;
  final ValueChanged<_TransferProgressSnapshot> _onChanged;
  final Stopwatch _watch = Stopwatch();
  int? _totalBytes;
  int _transferredBytes = 0;
  int _lastEmittedBytes = 0;
  Duration _lastEmittedAt = Duration.zero;
  double _bytesPerSecond = 0;
  bool _preparing = false;
  String? _status;

  void setStatus(String value) {
    _status = value;
    _preparing = false;
    _emit(_transferredBytes, force: true);
  }

  void start({bool preparing = false}) {
    _preparing = preparing;
    _watch.start();
    _emit(0, force: true);
  }

  void setTotalBytes(int value) {
    _totalBytes = value;
    _preparing = false;
    _emit(_transferredBytes, force: true);
  }

  void update(int value) {
    _preparing = false;
    _emit(value);
  }

  void finish() {
    _emit(_totalBytes ?? _transferredBytes, force: true);
  }

  void _emit(int value, {bool force = false}) {
    final now = _watch.elapsed;
    final elapsedSinceUpdate = now - _lastEmittedAt;
    final byteDelta = value - _lastEmittedBytes;
    final complete = _totalBytes != null && value >= _totalBytes!;
    if (!force &&
        !complete &&
        elapsedSinceUpdate < _minimumUpdateInterval &&
        byteDelta < _minimumByteDelta) {
      return;
    }

    final micros = elapsedSinceUpdate.inMicroseconds;
    if (micros > 0 && byteDelta >= 0) {
      final instantSpeed = byteDelta * Duration.microsecondsPerSecond / micros;
      _bytesPerSecond = _bytesPerSecond == 0
          ? instantSpeed
          : (_bytesPerSecond * .7) + (instantSpeed * .3);
    }
    _transferredBytes = value;
    _lastEmittedBytes = value;
    _lastEmittedAt = now;
    _onChanged(
      _TransferProgressSnapshot(
        title: title,
        transferredBytes: value,
        totalBytes: _totalBytes,
        bytesPerSecond: _bytesPerSecond,
        preparing: _preparing,
        status: _status,
      ),
    );
  }
}

class _TransferProgressView extends StatelessWidget {
  const _TransferProgressView({
    required this.progress,
    this.compact = false,
    this.onCancel,
  });

  final _TransferProgressSnapshot progress;
  final bool compact;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final total = progress.totalBytes;
    final percent = progress.value == null
        ? null
        : '${(progress.value! * 100).toStringAsFixed(0)}%';
    final speed = progress.bytesPerSecond <= 0
        ? null
        : '${formatBytes(progress.bytesPerSecond.round())}/s';
    final details = progress.preparing
        ? '正在计算文件大小…'
        : [
            if (progress.status != null) localized(progress.status!),
            if (percent != null) percent,
            if (progress.transferredBytes > 0 || total != null)
              total == null || total <= 0
                  ? formatBytes(progress.transferredBytes)
                  : '${formatBytes(progress.transferredBytes)} / ${formatBytes(total)}',
            if (speed != null) speed,
          ].join(' · ');
    return Semantics(
      label: '${progress.title} $details',
      child: Padding(
        padding: EdgeInsets.fromLTRB(8, compact ? 2 : 0, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: LText(
                    progress.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: (compact
                            ? prism.AppTextStyle.caption2
                            : prism.AppTextStyle.caption1)
                        .of(context, emphasized: true),
                  ),
                ),
                if (onCancel != null)
                  IconButton(
                    key: const ValueKey('sftp-transfer-cancel'),
                    tooltip: localized('取消传输'),
                    onPressed: onCancel,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 30,
                      minHeight: 30,
                    ),
                    iconSize: compact ? 16 : 18,
                    icon: const Icon(Icons.close),
                  ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 3,
                  child: LText(
                    details,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: prism.AppTextStyle.caption2.of(context).copyWith(
                          color: prism.Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant,
                        ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: progress.value,
              minHeight: compact ? 3 : 4,
            ),
          ],
        ),
      ),
    );
  }
}

/// 文件页确认框的两个按钮：左边取消（返回 false），右边 [confirm]（返回 true）。
/// 同一时刻只开一个确认框，key 各框通用。
List<Widget> _confirmActions(BuildContext context, String confirm) => [
      ShunButton(
        key: const ValueKey('sftp-dialog-cancel'),
        kind: ShunButtonKind.text,
        label: '取消',
        onPressed: () => Navigator.pop(context, false),
      ),
      ShunButton(
        key: const ValueKey('sftp-dialog-confirm'),
        label: confirm,
        onPressed: () => Navigator.pop(context, true),
      ),
    ];

/// 文件列表的一行，排版用 Prism 的 ListRow。
///
/// 没用 ShunListRow：它左右留白固定 16dp、标题不限行数，双栏时一栏只有两百 dp 左右，
/// 文件名要压成一行。读屏和迁移前一样：名字和大小合成一个按钮节点（点按、长按都在它上面，
/// 报选没选中），勾选框和 ⋮ 是它下面各自独立的节点。
class _FileRow extends StatelessWidget {
  const _FileRow({
    super.key,
    required this.entry,
    required this.compact,
    required this.selecting,
    required this.checked,
    required this.highlighted,
    required this.onTap,
    required this.onToggle,
    required this.menu,
  });

  final RemoteEntry entry;

  /// 一栏窄于 260dp（手机竖屏双栏）：字小一号，不显示大小。
  final bool compact;
  final bool selecting;
  final bool checked;

  /// 「在文件页中显示」定位到的那个文件。
  final bool highlighted;
  final VoidCallback onTap;

  /// 长按、点勾选框：进多选并切换这一项。
  final VoidCallback onToggle;
  final Widget menu;

  static const _compactRowHeight = 38.0;

  @override
  Widget build(BuildContext context) {
    final colors = prism.Theme.of(context).colorScheme;
    final name = localizedOf(context, entry.name);
    final size = entry.isDirectory
        ? localizedOf(context, '目录')
        : formatBytes(entry.size);
    // 整行是一个节点，勾选框和 ⋮ 是它的子节点：和迁移前的 ListTile 一样，读屏先念文件名。
    return Semantics(
      container: true,
      button: true,
      enabled: true,
      selected: checked || highlighted,
      label: compact ? name : '$name, $size',
      onTap: onTap,
      onLongPress: onToggle,
      child: Material(
        color: checked || highlighted
            ? prism.SurfaceContext(context).raisedSurfaceLevel.colorOf(colors)
            : Colors.transparent,
        shape: prism.AppShape.md,
        clipBehavior: Clip.antiAlias,
        // 点按范围是整行（和 ListTile 一样）；勾选框、⋮ 自己接自己的点按。
        child: InkWell(
          onTap: onTap,
          onLongPress: onToggle,
          excludeFromSemantics: true,
          child: Row(
            children: [
              if (selecting)
                Checkbox(
                  value: checked,
                  onChanged: (_) => onToggle(),
                  visualDensity: VisualDensity.compact,
                ),
              Expanded(
                child: prism.ListRow(
                  padding:
                      EdgeInsets.only(left: selecting ? 0 : (compact ? 4 : 8)),
                  horizontalTitleGap: compact ? 4 : 12,
                  minVerticalPadding: compact ? 2 : 6,
                  minHeight: compact ? _compactRowHeight : 48,
                  leading: selecting
                      ? null
                      : ExcludeSemantics(
                          child: Icon(
                            entry.isDirectory
                                ? Icons.folder
                                : _fileIcon(entry.name),
                            size: compact ? 20 : 23,
                            color: highlighted
                                ? colors.primary
                                : colors.onSurfaceVariant,
                          ),
                        ),
                  title: ExcludeSemantics(
                    child: _FileName(
                      name: name,
                      extension: entry.isDirectory ? '' : _nameExtension(name),
                      style: (compact
                              ? prism.AppTextStyle.footnote
                              : prism.AppTextStyle.subheadline)
                          .of(context)
                          .copyWith(color: colors.onSurface),
                    ),
                  ),
                  subtitle: compact
                      ? null
                      : ExcludeSemantics(
                          child: Text(
                            size,
                            maxLines: 1,
                            style: prism.AppTextStyle.caption1
                                .of(context)
                                .copyWith(color: colors.onSurfaceVariant),
                          ),
                        ),
                ),
              ),
              // 窄栏里一屏要多看几行：⋮ 的宽度照旧 48dp，高度跟着行高走（迁移前 ListTile 也是这样）。
              if (compact)
                SizedBox(height: _compactRowHeight, child: menu)
              else
                menu,
            ],
          ),
        ),
      ),
    );
  }
}

/// 文件名里放不下也要露着的那一段：最后一个扩展名，前面是 `.tar` 时连它一起（`.tar.gz`）。
/// 没有扩展名、以点开头的名字（`.bashrc`）、扩展名长过 12 个字符的，返回空串，照旧在末尾省略。
String _nameExtension(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  final before = name.lastIndexOf('.', dot - 1);
  final start =
      before > 0 && name.substring(before, dot).toLowerCase() == '.tar'
          ? before
          : dot;
  final extension = name.substring(start);
  return extension.length > 12 || extension.contains(' ') ? '' : extension;
}

/// 一行文件名。放得下就是一个 Text（按名字找它的测试和脚本照旧）；放不下时省略中间、
/// 留住 [extension]：`backup-2026….tar.gz`，不然一排长名字看不出各是什么文件。
/// 扩展名之外连省略号都放不下时退回末尾省略。
class _FileName extends StatelessWidget {
  const _FileName({
    required this.name,
    required this.extension,
    required this.style,
  });

  final String name;
  final String extension;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final whole = Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          );
          if (extension.isEmpty || !constraints.hasBoundedWidth) return whole;
          double widthOf(String text) {
            final painter = TextPainter(
              text: TextSpan(text: text, style: style),
              maxLines: 1,
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            )..layout();
            final width = painter.width;
            painter.dispose();
            return width;
          }

          if (widthOf(name) <= constraints.maxWidth) return whole;
          // 扩展名之外连省略号都放不下：拆了会溢出，退回末尾省略。
          if (constraints.maxWidth - widthOf(extension) < widthOf('…')) {
            return whole;
          }
          return Row(
            children: [
              Flexible(
                child: Text(
                  name.substring(0, name.length - extension.length),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
              ),
              Text(extension, maxLines: 1, softWrap: false, style: style),
            ],
          );
        },
      );
}

IconData _fileIcon(String name) =>
    RegExp(r'\.(png|jpg|jpeg|gif|webp)$', caseSensitive: false).hasMatch(name)
        ? Icons.image_outlined
        : RegExp(
            r'\.(dart|js|ts|py|sh|json|ya?ml|conf)$',
            caseSensitive: false,
          ).hasMatch(name)
            ? Icons.code
            : Icons.description_outlined;
