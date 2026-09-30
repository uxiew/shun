import 'package:plugin_api/plugin_api.dart';

/// 随主 App 一起发布的 provider（docs/15 §1 的 bundled）。
///
/// 这些 ID 和整个 `builtin.` 前缀只属于宿主：外部安装包声称它们会在准入时被拒（PLG01），
/// 所以第三方插件永远遮蔽不了内置 SSH。
///
/// 描述符里的 version 是内置 provider 的契约版本，不是 App 版本号；
/// 内置能力的行为变了（比如新增一种路由）才改它。
abstract final class BuiltinPlugins {
  /// SSH 和 Telnet 终端，以及保险库里的主机列表。
  ///
  /// Telnet 也算在这里：它和 SSH 走同一个 SshService、存在同一个主机列表里，
  /// 协议只是主机的一个字段。拆成两个 provider 的话，用户改一下协议，设备引用就换了主人。
  static const ssh = 'builtin.ssh';

  /// 直连 / SOCKS5 / 跳板路由。只能内置：交给第三方就等于交出「失败不偷偷直连」这条底线。
  static const route = 'builtin.route';

  /// Tailscale 设备目录（R11–R13 的实现，X05 接进插件体系）。只列设备、不负责连通和登录，
  /// 所以不为它单独出一个 APK（docs/15 §1）。
  static const tailscale = 'builtin.tailscale';

  /// 网易 UU 远程的调用适配器（X06）。远控本身在 UU 远程这个外部 App 里，这里只按官方 URL Scheme
  /// 发起绑定和远控、校验回调，所以随 App 发布，不另出 APK（docs/15 §1）。
  static const uuremote = 'builtin.uuremote';

  /// RustDesk 的调用适配器（X07）。远控在手机上装的 RustDesk 客户端里，这里只在用户点了之后发一条连接链接，
  /// 不含 RustDesk 的任何代码，所以随 App 发布，不另出 APK。内嵌画面是另一回事（R38）。
  static const rustdesk = 'builtin.rustdesk';

  static const ids = {ssh, route, tailscale, uuremote, rustdesk};

  static final List<PluginDescriptor> descriptors = [
    PluginDescriptor.fromMap({
      'schemaVersion': 1,
      'pluginId': ssh,
      'displayName': 'SSH / Telnet（内置）',
      'version': '1.0.0',
      'apiMajor': hostApiMajor,
      'apiMinor': hostApiMinor,
      'deployment': Deployment.bundled.wire,
      'capabilities': [Capability.terminalSession.wire],
      'supportedRoutes': [
        for (final route in [
          RouteSupport.systemDefault,
          RouteSupport.socks5Connect,
          RouteSupport.proxyJump,
          RouteSupport.socks5ProxyJump,
        ])
          route.wire,
      ],
      'platforms': [Platform.android.name, Platform.ios.name],
      'permissions': <String>[],
      'license': 'GPL-3.0-or-later',
    }),
    PluginDescriptor.fromMap({
      'schemaVersion': 1,
      'pluginId': route,
      'displayName': '连接路径（内置）',
      'version': '1.0.0',
      'apiMajor': hostApiMajor,
      'apiMinor': hostApiMinor,
      'deployment': Deployment.bundled.wire,
      'capabilities': [Capability.route.wire],
      'supportedRoutes': [
        for (final route in [
          RouteSupport.systemDefault,
          RouteSupport.socks5Connect,
          RouteSupport.proxyJump,
          RouteSupport.socks5ProxyJump,
        ])
          route.wire,
      ],
      'platforms': [Platform.android.name, Platform.ios.name],
      'permissions': <String>[],
      'license': 'GPL-3.0-or-later',
    }),
    PluginDescriptor.fromMap({
      'schemaVersion': 1,
      'pluginId': tailscale,
      'displayName': 'Tailscale 设备目录（内置）',
      'version': '1.0.0',
      'apiMajor': hostApiMajor,
      'apiMinor': hostApiMinor,
      'deployment': Deployment.bundled.wire,
      'capabilities': [Capability.deviceCatalog.wire],
      // 只走系统网络：控制面 API 不借任何 SSH 主机的代理或跳板（docs/05「网络与 API 边界」）。
      // 设备连不连得上是导入之后那台主机自己的路线，和这里无关。
      'supportedRoutes': [RouteSupport.systemDefault.wire],
      'platforms': [Platform.android.name, Platform.ios.name],
      // 自己的缓存和自己来源的控制面凭据。没有读保险库、没有读别的来源凭据的权限。
      'permissions': [Permission.ownProviderState.wire],
      'license': 'GPL-3.0-or-later',
    }),
    PluginDescriptor.fromMap({
      'schemaVersion': 1,
      'pluginId': uuremote,
      'displayName': 'UU 远程调用（内置）',
      'version': '1.0.0',
      'apiMajor': hostApiMajor,
      'apiMinor': hostApiMinor,
      'deployment': Deployment.bundled.wire,
      'capabilities': [Capability.remoteDesktopExternal.wire],
      // UU 远程用它自己的网络和账号，不经过任何主机配置的代理或跳板（UUR08）。
      'supportedRoutes': [RouteSupport.providerManaged.wire],
      'platforms': [Platform.android.name],
      // 只在用户点了之后拉起 UU；自己保存的绑定（加密设备标识）也只属于这里。
      'permissions': [
        Permission.userInitiatedExternalLaunch.wire,
        Permission.ownProviderState.wire,
      ],
      'license': 'GPL-3.0-or-later',
    }),
    PluginDescriptor.fromMap({
      'schemaVersion': 1,
      'pluginId': rustdesk,
      'displayName': 'RustDesk 调用（内置）',
      'version': '1.0.0',
      'apiMajor': hostApiMajor,
      'apiMinor': hostApiMinor,
      'deployment': Deployment.bundled.wire,
      'capabilities': [Capability.remoteDesktopExternal.wire],
      // RustDesk 用它自己配置的 ID 服务器和中继，不经过任何主机配置的代理或跳板（RDX04）。
      'supportedRoutes': [RouteSupport.providerManaged.wire],
      'platforms': [Platform.android.name],
      // 只在用户点了之后拉起 RustDesk；自己保存的只有每台主机对应的 RustDesk ID 和用户信任的客户端。
      'permissions': [
        Permission.userInitiatedExternalLaunch.wire,
        Permission.ownProviderState.wire,
      ],
      // 这是本 App 里适配器代码的许可。RustDesk 客户端本身是 AGPL，不在本 App 里。
      'license': 'GPL-3.0-or-later',
    }),
  ];
}
