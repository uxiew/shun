// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 xwfe

// X11 独立对抗：插件描述符是插件作者写的任意 JSON，这里只测 contract_test 没碰的写法。
import 'dart:convert';

import 'package:plugin_api/plugin_api.dart';
import 'package:test/test.dart';

Map<String, Object?> base() => {
  'schemaVersion': 1,
  'pluginId': 'example.attack',
  'displayName': 'Attack',
  'version': '0.1.0',
  'apiMajor': 1,
  'apiMinor': 0,
  'deployment': 'android-service',
  'capabilities': ['terminal-session'],
  'supportedRoutes': ['system-default'],
  'platforms': ['android'],
  'permissions': ['own-session-input-output'],
  'packageName': 'example.attack',
  'serviceClass': 'example.attack.S',
};

Matcher get rejected => throwsA(isA<DescriptorException>());

void main() {
  test('重复键：取最后一个，和界面、准入用的是同一份解析结果，不会一处看到前一个、一处用后一个', () {
    final text = jsonEncode(base()).replaceFirst(
      '"permissions":["own-session-input-output"]',
      '"permissions":["own-session-input-output"],'
          '"permissions":["own-session-input-output","own-session-ephemeral-secret"]',
    );
    final d = PluginDescriptor.parse(text);
    expect(d.permissions, contains(Permission.ownSessionEphemeralSecret));
  });

  test('深层嵌套的 JSON：只报描述符无效，不把解析者撑崩', () {
    // 16 KiB 以内能嵌套约 8000 层。递归下降的解析器在这里会栈溢出（StackOverflowError 不是 FormatException，
    // 接不住就是整个发现流程崩）。
    final deep = '${'[' * 8000}${']' * 8000}';
    final text = '{"license":$deep}';
    expect(utf8.encode(text).length, lessThan(maxDescriptorBytes));
    expect(() => PluginDescriptor.parse(text), rejected);
  });

  test('开头带 BOM、顶层不是对象、null：拒绝', () {
    expect(
      () => PluginDescriptor.parse('\uFEFF${jsonEncode(base())}'),
      rejected,
    );
    expect(() => PluginDescriptor.parse('[]'), rejected);
    expect(() => PluginDescriptor.parse('null'), rejected);
  });

  test('数字写成 1.0、"1"、true、超大数：拒绝，不强转', () {
    for (final v in [1.0, '1', true, 1e400]) {
      expect(
        () => PluginDescriptor.fromMap(base()..['apiMajor'] = v),
        rejected,
        reason: '$v',
      );
    }
    expect(
      () => PluginDescriptor.parse(
        jsonEncode(base()).replaceFirst('"apiMinor":0', '"apiMinor":1e400'),
      ),
      rejected,
    );
  });

  test('同形字、大写、全角的 pluginId：拒绝（不会和 shun.mosh 长得一样却算不同 ID）', () {
    for (final id in [
      'shun.mоsh', // 西里尔字母 о
      'Shun.Mosh',
      'ｓhun.mosh', // 全角 s
      'shun.mosh\u200B', // 零宽空格
      'builtin..ssh',
      'shun.mosh.',
    ]) {
      expect(
        () => PluginDescriptor.fromMap(base()..['pluginId'] = id),
        rejected,
        reason: id,
      );
    }
  });

  // 显示名出现在批准框第一行。双向控制符能让它看起来是另一串字，零宽字符让两个名字看着一样、实际不同。
  test('显示名里的双向控制符、零宽字符：拒绝', () {
    for (final name in [
      'shun \u202Ehsom', // RLO：显示成 "shun mosh"
      'shun\u2066 Mosh\u2069',
      'shun\u200B Mosh',
      'shun\u200F Mosh',
      'shun\uFEFF Mosh',
      'shun\u061C Mosh',
    ]) {
      expect(
        () => PluginDescriptor.fromMap(base()..['displayName'] = name),
        rejected,
        reason: name.runes.map((r) => r.toRadixString(16)).join(' '),
      );
    }
    expect(
      () => PluginDescriptor.fromMap(
        base()..['sourceUrl'] = 'https://evil.example/\u202Egro.buhtig//',
      ),
      rejected,
    );
    expect(
      () => PluginDescriptor.fromMap(base()..['license'] = 'MIT\u200B'),
      rejected,
    );
    // 正常的非拉丁文字照样可以用。
    expect(
      PluginDescriptor.fromMap(
        base()..['displayName'] = '移动终端 محطة',
      ).displayName,
      '移动终端 محطة',
    );
  });

  test('自称 bundled 或 external-app 的安装包、外部包申请 route：都进不了 Ready', () {
    final policy = AdmissionPolicy(builtinIds: {'builtin.ssh'});
    Admission evaluate(Map<String, Object?> m) => policy.evaluate(
      InstalledCandidate(
        descriptor: PluginDescriptor.fromMap(m),
        installedPackage: 'example.attack',
        actualSignerDigests: {'author'},
      ),
      alreadyRegistered: {},
      approvals: const [],
    );
    expect(evaluate(base()..['deployment'] = 'bundled'), isA<Rejected>());
    expect(
      () => PluginDescriptor.fromMap(
        base()..['capabilities'] = ['terminal-session', 'route'],
      ),
      rejected,
    );
    // external-app 的包不用服务类，但也得用户批准，不会因为「不是 android-service」就放行。
    expect(
      evaluate(
        base()
          ..['deployment'] = 'external-app'
          ..['capabilities'] = ['remote-desktop-external']
          ..['supportedRoutes'] = ['provider-managed'],
      ),
      isA<NeedsApproval>(),
    );
  });
}
