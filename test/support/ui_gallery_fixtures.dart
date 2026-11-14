import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/session_controller.dart';
import 'package:shun/application/tailscale_catalog_refresh.dart';
import 'package:shun/application/vault_controller.dart';
import 'package:shun/domain/connection_route.dart';
import 'package:shun/domain/models/host.dart';
import 'package:shun/infrastructure/ssh/sftp_service.dart';
import 'package:shun/infrastructure/ssh/ssh_service.dart';
import 'package:shun/infrastructure/tailscale/catalog_cache.dart';
import 'package:shun/infrastructure/tailscale/tailscale_device.dart';

import 'test_terminal.dart';

/// HomeShell 的隐藏本机文件服务仍会初始化；只允许它访问本次拥有的临时目录。
/// 使用 path_provider 的 MethodChannel 测试入口，不改生产服务或依赖。
class UiGalleryPaths {
  UiGalleryPaths._(this.root);

  static const _channel = MethodChannel('plugins.flutter.io/path_provider');
  final Directory root;
  int documentsRequests = 0;

  String get documentsPath => '${root.path}/documents';
  String get supportPath => '${root.path}/support';
  String get cachePath => '${root.path}/cache';

  static Future<UiGalleryPaths> create() async {
    final paths = UiGalleryPaths._(
      await Directory.systemTemp.createTemp('shun-ui-gallery-'),
    );
    for (final path in [
      paths.documentsPath,
      paths.supportPath,
      paths.cachePath,
    ]) {
      await Directory(path).create();
    }
    return paths;
  }

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      switch (call.method) {
        case 'getApplicationDocumentsDirectory':
          documentsRequests++;
          return documentsPath;
        case 'getApplicationSupportDirectory':
          return supportPath;
        case 'getTemporaryDirectory':
        case 'getApplicationCacheDirectory':
          return cachePath;
        default:
          throw MissingPluginException('Unsupported gallery path request');
      }
    });
  }

  Future<void> dispose() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    await root.delete(recursive: true);
  }
}

/// 只供图库使用：地址均为保留示例域，没有凭据，不调用 connect。
final uiGalleryHosts = <HostProfile>[
  HostProfile({
    'id': 'gallery-web',
    'label': '示例 Web',
    'hostname': 'web.example.test',
    'username': 'demo',
    'protocol': 'ssh',
    'group': '开发',
    'pinned': true,
  }),
  HostProfile({
    'id': 'gallery-worker',
    'label': '后台任务',
    'hostname': 'worker.example.test',
    'username': 'demo',
    'protocol': 'ssh',
    'group': '开发',
  }),
  HostProfile({
    'id': 'gallery-storage',
    'label': '文件服务器',
    'hostname': 'files.example.test',
    'username': 'demo',
    'protocol': 'ssh',
    'group': '实验',
  }),
  HostProfile({
    'id': 'gallery-lab',
    'label': '测试环境',
    'hostname': 'lab.example.test',
    'username': 'demo',
    'protocol': 'ssh',
    'group': '实验',
  }),
];

/// R87 首页的 Tailscale 分节：两个来源里各有一台同名、同 IP、同设备 ID 的 nas（不能合并），
/// 「公司」是很久以前读的、最近一次读取失败，build 已经不在最新列表里。
/// 时间写死在 2026-11-01，图上的「几天前」只随日期变；地址用 100.64 保留段，不连。
List<CatalogCache> uiGalleryCatalogs() {
  final at = DateTime(2026, 11, 1, 8);
  Map<String, Object?> device(String id, String host, String ip, bool? on) => {
        'id': id,
        'name': '$host.tail0000.ts.net',
        'hostname': host,
        'addresses': [ip],
        'os': 'linux',
        if (on != null) 'connectedToControl': on,
      };
  CatalogCache source(String id, String label, List<Map<String, Object?>> d) =>
      CatalogCache(catalogId: id, tailnet: '-', label: label)
          .merge(TailscaleDeviceSnapshot.parse(jsonEncode({'devices': d})), at);
  final home = source('gallery-home', '家里', [
    device('1', 'nas', '100.64.0.1', true),
    device('2', 'laptop', '100.64.0.2', false),
  ]);
  final work = source('gallery-work', '公司', [
    device('1', 'nas', '100.64.0.1', false),
    device('4', 'build', '100.64.0.9', true),
  ]);
  return [
    home,
    work.copyWith(devices: {
      ...work.devices,
      '4': work.devices['4']!.markMissing(at),
    }).recordFailure('HTTP 500', at.add(const Duration(hours: 1))),
  ];
}

/// 绑定到 [uiGalleryCatalogs] 两个来源设备 1 的主机：别名、账号各不相同。
final uiGalleryCatalogHosts = <HostProfile>[
  for (final (id, label, catalog, user) in const [
    ('gallery-home-nas', '家里 NAS', 'gallery-home', 'admin'),
    ('gallery-work-nas', '公司 NAS', 'gallery-work', 'ops'),
  ])
    HostProfile({
      'id': id,
      'label': label,
      'hostname': '100.64.0.1',
      'username': user,
      'protocol': 'ssh',
      CatalogBinding.key: CatalogBinding(
        catalogId: catalog,
        deviceId: '1',
        appliedAddress: '100.64.0.1',
      ).toJson(),
    }),
];

/// 真 Ghostty 引擎接收固定 VT 字节；connected 仅是展示状态，没有 SSH/socket。
/// 隐藏光标避免闪烁相位改变截图，输出不包含时钟或用户资料。
SessionState uiGallerySessions() {
  ActiveTerminalSession session(
    String id,
    HostProfile host,
    String output, {
    bool connected = true,
  }) {
    final terminal = newTestTerminal()..feed(utf8.encode('\x1b[?25l$output'));
    return ActiveTerminalSession(
      id: id,
      host: host,
      terminal: terminal,
      verifyHostKey: (_, __, ___) async => false,
      keyboardInteractive: null,
    )..connected = connected;
  }

  return SessionState(sessions: [
    session(
      'gallery-shell',
      uiGalleryHosts[0],
      '\x1b[32mdemo@web\x1b[0m:~/workspace\$ ls\r\n'
      '\x1b[34msrc/  docs/  test/\x1b[0m\r\n'
      'README.md  shun.toml\r\n\r\n'
      '\x1b[32mdemo@web\x1b[0m:~/workspace\$ ./check\r\n'
      '\x1b[36m[1/3]\x1b[0m Reading configuration\r\n'
      '\x1b[36m[2/3]\x1b[0m Checking local files\r\n'
      '\x1b[36m[3/3]\x1b[0m Complete\r\n'
      '\x1b[32mAll checks passed.\x1b[0m\r\n\r\n'
      'UI gallery fixture / no remote connection\r\n'
      '\x1b[32mdemo@web\x1b[0m:~/workspace\$ ',
    ),
    session(
      'gallery-log',
      uiGalleryHosts[0],
      '\x1b[36mApplication log\x1b[0m\r\n'
      'INFO  configuration loaded\r\n'
      'INFO  worker ready\r\n'
      'INFO  request completed\r\n',
    ),
    session(
      'gallery-disconnected',
      uiGalleryHosts[1],
      'demo@worker:~\$ status\r\n'
      'worker is idle\r\n'
      'Connection closed.\r\n',
      connected: false,
    ),
  ]);
}

/// 沿用生产控制器的本地状态/切换/释放逻辑，不发起连接。
class UiGallerySessionController extends SessionController {
  UiGallerySessionController(
    VaultController vault,
    Ref ref,
    SessionState initial,
  ) : super(SshService(), vault, ref) {
    state = initial;
  }
}

/// 真实 SftpScreen 的本机目录来源；不触碰磁盘、SAF 或服务器。
/// 图库只导航和选择，任何读写操作显式失败，不能被当作传输测试。
class UiGalleryFiles extends MountableFileTransferService {
  static const _entries = <String, List<RemoteEntry>>{
    '/': [
      RemoteEntry(name: 'docs', path: '/docs', isDirectory: true, size: 0),
      RemoteEntry(
        name: 'downloads',
        path: '/downloads',
        isDirectory: true,
        size: 0,
      ),
      RemoteEntry(name: 'src', path: '/src', isDirectory: true, size: 0),
      RemoteEntry(
        name: 'README.md',
        path: '/README.md',
        isDirectory: false,
        size: 2480,
      ),
      RemoteEntry(
        name: 'application.log',
        path: '/application.log',
        isDirectory: false,
        size: 49152,
      ),
      RemoteEntry(
        name: 'shun.toml',
        path: '/shun.toml',
        isDirectory: false,
        size: 384,
      ),
    ],
    '/docs': [
      RemoteEntry(
        name: 'guide.md',
        path: '/docs/guide.md',
        isDirectory: false,
        size: 8192,
      ),
      RemoteEntry(
        name: 'notes.txt',
        path: '/docs/notes.txt',
        isDirectory: false,
        size: 128,
      ),
    ],
    '/downloads': [],
    '/src': [
      RemoteEntry(
        name: 'main.dart',
        path: '/src/main.dart',
        isDirectory: false,
        size: 1024,
      ),
    ],
  };

  @override
  String get id => 'local';
  @override
  String get displayName => '手机：示例文件';
  @override
  String get rootPath => '/';
  @override
  bool get isLocal => true;
  @override
  bool get isMounted => true;
  @override
  String get mountedDirectoryName => '示例文件';
  @override
  Future<bool> mount() async => false;

  @override
  String displayPath(String path) => path;
  @override
  String joinPath(String path, String name) =>
      path == '/' ? '/$name' : '$path/$name';
  @override
  String parentPath(String path) {
    final separator = path.lastIndexOf('/');
    return separator <= 0 ? '/' : path.substring(0, separator);
  }

  @override
  Future<List<RemoteEntry>> list(String path) async => List.of(
      _entries[path] ?? (throw StateError('Unknown fixture directory')));

  @override
  Future<int?> fileSize(String path) async {
    for (final entries in _entries.values) {
      for (final entry in entries) {
        if (entry.path == path && !entry.isDirectory) return entry.size;
      }
    }
    return null;
  }

  Never _readOnly() => throw UnsupportedError('UI gallery is read-only');

  @override
  Stream<Uint8List> readStream(
    String path, {
    int startOffset = 0,
    TransferProgressCallback? onProgress,
  }) =>
      _readOnly();

  @override
  Future<void> writeStream(
    String path,
    Stream<Uint8List> stream, {
    int startOffset = 0,
    bool truncate = true,
    TransferProgressCallback? onProgress,
  }) async =>
      _readOnly();

  @override
  Future<void> mkdir(String path) async => _readOnly();
  @override
  Future<void> ensureDirectory(String path) async => _readOnly();
  @override
  Future<void> rename(String from, String to) async => _readOnly();
  @override
  Future<void> delete(RemoteEntry entry) async => _readOnly();
}

/// R88 测试连接页：走完拨号、握手两步，按 [fail] 报成功或服务器拒绝登录（和真的一样带提示）。不碰网络。
class UiGalleryProbe extends SshService {
  UiGalleryProbe({this.fail = false});

  final bool fail;

  @override
  Future<ProbeOutcome> probe({
    required HostProfile host,
    List<HostProfile> hosts = const [],
    List<SshKeyProfile> keys = const [],
    List<Map<String, dynamic>> identities = const [],
    List<ProxyProfile> proxyProfiles = const [],
    RoutePlan? routePlan,
    required HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
    required ConnectionAttempt attempt,
  }) async {
    attempt.report(ConnectionStage(ConnectionStep.dial, label: host.label));
    attempt
        .report(ConnectionStage(ConnectionStep.handshake, label: host.label));
    if (fail) {
      throw RouteHopException(0, host.label, SSHAuthFailError('denied'));
    }
    return const ProbeOutcome(tty: '/dev/pts/3');
  }
}

/// R88 编辑已有主机：一台跳板，一台经它连、带标签、置顶、启动命令的主机。
final uiGalleryJumpHost = HostProfile({
  'id': 'gallery-jump',
  'label': '跳板',
  'hostname': 'jump.example.test',
  'username': 'demo',
  'protocol': 'ssh',
});

final uiGalleryEditedHost = HostProfile({
  'id': 'gallery-edit',
  'label': '示例 API',
  'hostname': 'api.example.test',
  'port': 2222,
  'username': 'demo',
  'protocol': 'ssh',
  'group': '开发',
  'tags': ['api', 'prod'],
  'pinned': true,
  'startupCommand': 'tmux ls',
  'hostChain': {
    'hostIds': ['gallery-jump'],
  },
});
