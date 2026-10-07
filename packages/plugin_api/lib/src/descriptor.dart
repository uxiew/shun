// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 xwfe

import 'dart:convert';

/// 宿主当前实现的插件 API 版本。major 变了就是不兼容；minor 只追加能力。
const hostApiMajor = 1;
const hostApiMinor = 0;

/// 描述符 JSON 的最大字节数。再大就不是"描述"了，直接拒绝（PLG01 超长描述符）。
const maxDescriptorBytes = 16 * 1024;

enum Deployment {
  bundled('bundled'),
  androidService('android-service'),
  externalApp('external-app');

  const Deployment(this.wire);
  final String wire;
}

/// 能力按"会话分型"划分；一个 provider 声明哪些，宿主就只允许调用哪些。
enum Capability {
  deviceCatalog('device-catalog', 0),
  terminalSession('terminal-session', 0),
  remoteDesktopExternal('remote-desktop-external', 0),
  remoteDesktopSurface('remote-desktop-surface', 0),

  /// 只有随包内置的 provider 能声明：路由（Direct/SOCKS/ProxyJump）决定流量走哪，
  /// 交给第三方就等于交出"代理或跳板失败时不偷偷直连"这条底线。
  route('route', 0);

  const Capability(this.wire, this.sinceMinor);
  final String wire;

  /// 从哪个 API minor 开始有。宿主 minor 更低时，这个能力不可调用。
  final int sinceMinor;
}

enum RouteSupport {
  systemDefault('system-default'),
  socks5Connect('socks5-connect'),
  proxyJump('proxy-jump'),
  socks5ProxyJump('socks5-proxy-jump'),

  /// 由提供方自己的网络和账号负责（外部 App）。不继承宿主的 SSH 路由。
  providerManaged('provider-managed');

  const RouteSupport(this.wire);
  final String wire;
}

enum Platform { android, ios }

/// 权限清单是封闭的：没有 exec、没有文件、没有 Vault、没有剪贴板。
/// 新增敏感能力必须改这里并补授权与测试，不能靠一个笼统的 storage/network 权限扩大。
enum Permission {
  ownSessionEphemeralSecret('own-session-ephemeral-secret'),
  ownSessionInputOutput('own-session-input-output'),
  userInitiatedExternalLaunch('user-initiated-external-launch'),
  ownProviderState('own-provider-state'),
  deviceCatalogRead('device-catalog-read');

  const Permission(this.wire);
  final String wire;
}

class DescriptorException implements Exception {
  const DescriptorException(this.message);
  final String message;
  @override
  String toString() => 'DescriptorException: $message';
}

/// 解析并严格校验过的描述符。只能通过 [PluginDescriptor.parse] 得到。
///
/// 描述符是"插件自称"的内容：这里的 packageName 不代表签名身份，
/// 信任只看系统读出的安装包证书（见 trust.dart）。
class PluginDescriptor {
  PluginDescriptor._({
    required this.pluginId,
    required this.displayName,
    required this.version,
    required this.apiMajor,
    required this.apiMinor,
    required this.deployment,
    required this.capabilities,
    required this.ignoredNewerCapabilities,
    required this.supportedRoutes,
    required this.platforms,
    required this.permissions,
    this.packageName,
    this.serviceClass,
    this.license,
    this.sourceUrl,
  });

  final String pluginId;
  final String displayName;
  final String version;
  final int apiMajor;
  final int apiMinor;
  final Deployment deployment;

  /// 宿主认识且可调用的能力。
  final Set<Capability> capabilities;

  /// 插件 minor 比宿主新时，宿主不认识的能力名。不可调用，只用于提示。
  final Set<String> ignoredNewerCapabilities;
  final Set<RouteSupport> supportedRoutes;
  final Set<Platform> platforms;
  final Set<Permission> permissions;
  final String? packageName;
  final String? serviceClass;
  final String? license;
  final String? sourceUrl;

  static const _allowedKeys = {
    'schemaVersion',
    'pluginId',
    'displayName',
    'version',
    'apiMajor',
    'apiMinor',
    'deployment',
    'capabilities',
    'supportedRoutes',
    'platforms',
    'permissions',
    'packageName',
    'serviceClass',
    'license',
    'sourceUrl',
  };
  static final _pluginId = RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$');
  static final _semver = RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+$');
  static final _control = RegExp(r'[\x00-\x1f\x7f]');

  /// 从 JSON 文本解析。任何不合规都抛 [DescriptorException]，不做"尽量修复"。
  static PluginDescriptor parse(String json) {
    if (utf8.encode(json).length > maxDescriptorBytes) {
      throw const DescriptorException('描述符超过 16 KiB');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      throw const DescriptorException('不是合法 JSON');
    }
    if (decoded is! Map<String, Object?>) {
      throw const DescriptorException('顶层必须是对象');
    }
    return fromMap(decoded);
  }

  static PluginDescriptor fromMap(Map<String, Object?> m) {
    final unknown = m.keys.toSet().difference(_allowedKeys);
    if (unknown.isNotEmpty) {
      // 不认识的字段一律拒绝：exec、intent、url 回调之类只能从这里混进来。
      throw DescriptorException('不允许的字段：${unknown.join(', ')}');
    }
    if (m['schemaVersion'] != 1) {
      throw const DescriptorException('schemaVersion 必须是 1');
    }
    final apiMajor = _int(m, 'apiMajor');
    if (apiMajor != hostApiMajor) {
      throw DescriptorException('API major $apiMajor 不兼容（宿主 $hostApiMajor）');
    }
    final apiMinor = _int(m, 'apiMinor');
    if (apiMinor < 0 || apiMinor > 999) {
      throw const DescriptorException('apiMinor 超出 0–999');
    }
    final pluginId = _string(m, 'pluginId', max: 128);
    if (!_pluginId.hasMatch(pluginId)) {
      throw DescriptorException('pluginId 格式无效：$pluginId');
    }
    final displayName = _string(m, 'displayName', max: 80);
    if (displayName.isEmpty || _control.hasMatch(displayName)) {
      throw const DescriptorException('displayName 为空或含控制字符');
    }
    final version = _string(m, 'version', max: 32);
    if (!_semver.hasMatch(version)) {
      throw DescriptorException('version 必须是 x.y.z：$version');
    }
    final deployment = _enum(m, 'deployment', Deployment.values, (d) => d.wire);

    final capabilities = <Capability>{};
    final ignored = <String>{};
    for (final name in _stringList(m, 'capabilities', min: 1)) {
      final known = Capability.values.where((c) => c.wire == name).firstOrNull;
      if (known != null && known.sinceMinor <= hostApiMinor) {
        capabilities.add(known);
      } else if (apiMinor > hostApiMinor) {
        ignored.add(name); // 插件比宿主新：认不出的能力不可调用，但不否定整个插件
      } else {
        throw DescriptorException('未知能力：$name');
      }
    }
    final routes = _enumSet(
      m,
      'supportedRoutes',
      RouteSupport.values,
      (r) => r.wire,
      min: 1,
    );
    final platforms = _enumSet(
      m,
      'platforms',
      Platform.values,
      (p) => p.name,
      min: 1,
    );
    // 权限不做"新版本忽略"：宿主给不了的权限，插件就不能按它的预期工作，直接拒绝。
    final permissions = _enumSet(
      m,
      'permissions',
      Permission.values,
      (p) => p.wire,
      min: 0,
      max: 8,
    );

    final packageName = _optionalString(m, 'packageName', max: 180);
    final serviceClass = _optionalString(m, 'serviceClass', max: 220);
    final license = _optionalString(m, 'license', max: 100);
    final sourceUrl = _optionalString(m, 'sourceUrl', max: 1024);
    if (sourceUrl != null && !sourceUrl.startsWith('https://')) {
      throw const DescriptorException('sourceUrl 必须是 https');
    }

    if (deployment == Deployment.androidService) {
      if (packageName == null || serviceClass == null) {
        throw const DescriptorException(
          'android-service 必须有 packageName 和 serviceClass',
        );
      }
      if (platforms.length != 1 || platforms.single != Platform.android) {
        throw const DescriptorException('android-service 只能声明 android 平台');
      }
    }
    if (capabilities.contains(Capability.route) &&
        deployment != Deployment.bundled) {
      throw const DescriptorException('route 能力只允许随包内置的 provider 声明');
    }
    if (deployment == Deployment.externalApp &&
        (routes.length != 1 || routes.single != RouteSupport.providerManaged)) {
      throw const DescriptorException(
        'external-app 只能声明 provider-managed：外部 App 走自己的网络，不继承 SSH 路由',
      );
    }

    return PluginDescriptor._(
      pluginId: pluginId,
      displayName: displayName,
      version: version,
      apiMajor: apiMajor,
      apiMinor: apiMinor,
      deployment: deployment,
      capabilities: Set.unmodifiable(capabilities),
      ignoredNewerCapabilities: Set.unmodifiable(ignored),
      supportedRoutes: Set.unmodifiable(routes),
      platforms: Set.unmodifiable(platforms),
      permissions: Set.unmodifiable(permissions),
      packageName: packageName,
      serviceClass: serviceClass,
      license: license,
      sourceUrl: sourceUrl,
    );
  }

  static int _int(Map<String, Object?> m, String key) {
    final value = m[key];
    if (value is! int) throw DescriptorException('$key 必须是整数');
    return value;
  }

  static String _string(
    Map<String, Object?> m,
    String key, {
    required int max,
  }) {
    final value = m[key];
    if (value is! String) throw DescriptorException('$key 必须是字符串');
    if (value.length > max) throw DescriptorException('$key 超过 $max 字符');
    return value;
  }

  static String? _optionalString(
    Map<String, Object?> m,
    String key, {
    required int max,
  }) => m.containsKey(key) ? _string(m, key, max: max) : null;

  static List<String> _stringList(
    Map<String, Object?> m,
    String key, {
    int min = 0,
    int max = 64,
  }) {
    final value = m[key];
    if (value is! List || value.any((e) => e is! String)) {
      throw DescriptorException('$key 必须是字符串数组');
    }
    final list = value.cast<String>();
    if (list.length < min || list.length > max) {
      throw DescriptorException('$key 数量必须在 $min–$max 之间');
    }
    if (list.toSet().length != list.length) {
      throw DescriptorException('$key 有重复项');
    }
    return list;
  }

  static T _enum<T>(
    Map<String, Object?> m,
    String key,
    List<T> values,
    String Function(T) wire,
  ) {
    final name = _string(m, key, max: 64);
    return values.where((v) => wire(v) == name).firstOrNull ??
        (throw DescriptorException('$key 取值无效：$name'));
  }

  static Set<T> _enumSet<T>(
    Map<String, Object?> m,
    String key,
    List<T> values,
    String Function(T) wire, {
    required int min,
    int max = 64,
  }) {
    return {
      for (final name in _stringList(m, key, min: min, max: max))
        values.where((v) => wire(v) == name).firstOrNull ??
            (throw DescriptorException('$key 取值无效：$name')),
    };
  }
}
