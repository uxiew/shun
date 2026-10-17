import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// 主 App 清单里只声明用得到的。声明了却没代码处理的入口和权限，不帮任何人，只给别人多一条路。
void main() {
  final manifest =
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

  test('权限只有这几项：加一项要先想清楚谁用、不加会怎样', () {
    final permissions = RegExp(r'<uses-permission\s+android:name="([^"]+)"')
        .allMatches(manifest)
        .map((match) => match.group(1))
        .toSet();
    expect(permissions, {
      'android.permission.INTERNET',
      'android.permission.ACCESS_NETWORK_STATE',
      'android.permission.POST_NOTIFICATIONS',
      'android.permission.FOREGROUND_SERVICE',
      'android.permission.FOREGROUND_SERVICE_SPECIAL_USE',
    });
  });

  test('MainActivity 不接外部链接（没有 ssh:// 这类 VIEW 入口）', () {
    final start = manifest.indexOf('android:name=".MainActivity"');
    final end = manifest.indexOf('</activity>', start);
    expect(start, isNonNegative);
    final mainActivity = manifest.substring(start, end);
    expect(mainActivity, isNot(contains('android.intent.action.VIEW')));
    expect(mainActivity, isNot(contains('android:scheme')));
  });
}
