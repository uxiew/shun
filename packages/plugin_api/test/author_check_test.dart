// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 xwfe

import 'dart:convert';
import 'dart:io';

import 'package:plugin_api/plugin_api.dart' hide Platform;
import 'package:test/test.dart';

// X12 作者自查（bin/check_descriptor.dart）。和宿主用同一套判定，所以这里核对的是「说法和宿主一致」，
// 以及样例 plugins/example 的描述符本身能过——样例改坏了这里先挂，不用等装到设备上才发现。
void main() {
  const sample =
      '../../plugins/example/app/src/main/res/raw/shun_plugin.json';
  Map<String, Object?> sampleMap() =>
      jsonDecode(File(sample).readAsStringSync()) as Map<String, Object?>;
  AuthorCheck check(
    Map<String, Object?> m, {
    String? package,
    String? service,
  }) => AuthorCheck.run(
    jsonEncode(m),
    packageName: package,
    serviceClass: service,
  );

  test('样例的描述符：通过，没有提醒，包名和服务类与样例工程一致', () {
    final r = AuthorCheck.run(
      File(sample).readAsStringSync(),
      packageName: 'example.shun.hello',
      serviceClass: 'example.shun.hello.HelloProviderService',
    );
    expect(r.errors, isEmpty);
    expect(r.warnings, isEmpty);
    expect(r.descriptor!.pluginId, 'example.hello_terminal');
  });

  test('描述符本身不合规：报 DescriptorException 的原话', () {
    final m = sampleMap()..['exec'] = 'sh -c id';
    final r = check(m);
    expect(r.ok, isFalse);
    expect(r.descriptor, isNull);
    expect(r.errors.single, '不允许的字段：exec');
  });

  test('API major 不是 1：和宿主一样判不兼容', () {
    final r = check(sampleMap()..['apiMajor'] = 2);
    expect(r.errors.single, 'API major 2 不兼容（宿主 1）');
  });

  test('单独安装的包自称 bundled 或 external-app：不通过', () {
    final bundled = check(sampleMap()..['deployment'] = 'bundled');
    expect(
      bundled.errors,
      contains(startsWith('单独安装的插件 deployment 要写 android-service')),
    );
    expect(bundled.errors, contains(contains('自称随包内置')));
    final external = check(
      sampleMap()
        ..['deployment'] = 'external-app'
        ..['supportedRoutes'] = ['provider-managed'],
    );
    expect(external.errors.single, contains('android-service'));
  });

  test('builtin. 前缀是宿主保留的', () {
    final r = check(sampleMap()..['pluginId'] = 'builtin.hello');
    expect(r.errors.single, 'builtin.hello 是内置 provider 保留 ID，外部包不能占用');
  });

  test('给了 --package / --service 就核对：和宿主拿实际安装包核对时同一句话', () {
    final r = check(
      sampleMap(),
      package: 'com.example.renamed',
      service: 'com.example.renamed.MyService',
    );
    expect(r.errors, [
      '描述符声称的包名与实际安装包不一致',
      startsWith('描述符自称的服务类与实际声明插件 action 的服务不一致'),
    ]);
  });

  test('提醒：minor 比宿主新、终端会话没申请输入输出权限、没写许可证', () {
    final m = sampleMap()
      ..['apiMinor'] = hostApiMinor + 1
      ..['capabilities'] = ['terminal-session', 'future-thing']
      ..['permissions'] = <String>[]
      ..remove('license');
    final r = check(m);
    expect(r.ok, isTrue);
    expect(r.warnings, hasLength(4));
    expect(r.descriptor!.ignoredNewerCapabilities, {'future-thing'});
  });

  test('提醒：只声明宿主不会调用的能力、申请只给 Mosh 的临时凭据权限（sdk01 复验提出）', () {
    final m = sampleMap()
      ..['capabilities'] = ['device-catalog']
      ..['permissions'] = [
        'device-catalog-read',
        'own-session-ephemeral-secret',
      ];
    final r = check(m);
    expect(r.ok, isTrue);
    expect(
      r.warnings,
      contains(startsWith('没有声明 terminal-session：装上能批准，但宿主不会调用')),
    );
    expect(
      r.warnings,
      contains(startsWith('宿主现在只会用第三方插件的 terminal-session；device-catalog')),
    );
    expect(
      r.warnings,
      contains(startsWith('own-session-ephemeral-secret 只给 Mosh 插件')),
    );
  });

  test('命令行：通过退出 0，不通过退出 1，用法不对退出 2', () async {
    Future<ProcessResult> cli(List<String> args) => Process.run(
      Platform.resolvedExecutable,
      ['run', 'bin/check_descriptor.dart', ...args],
    );
    final good = await cli([sample, '--package', 'example.shun.hello']);
    expect(good.exitCode, 0, reason: '${good.stdout}${good.stderr}');
    expect(good.stdout, contains('通过'));

    final bad = File(
      '${Directory.systemTemp.createTempSync('x12').path}/d.json',
    )..writeAsStringSync(jsonEncode(sampleMap()..['apiMajor'] = 2));
    final refused = await cli([bad.path]);
    expect(refused.exitCode, 1);
    expect(refused.stdout, contains('不通过：API major 2 不兼容（宿主 1）'));

    expect((await cli([])).exitCode, 2);
  });
}
