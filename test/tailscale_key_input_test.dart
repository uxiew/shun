import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/application/tailscale_key_input.dart';
import 'package:shun/domain/models/server_stats.dart';
import 'package:shun/presentation/widgets/host_system_icon.dart';

// R26：Tailscale 设置页只有一个 key 框，按前缀认是什么；设备列表按 Tailscale 报的系统显示图标。
void main() {
  test('tskey-client：OAuth client，client ID 从 secret 里取，去掉空白和 ?参数', () {
    final input = parseTailscaleKey(
        ' tskey-client-kXGGbs6CNTRL-abcDEF123?ephemeral=true ');
    expect(input, isA<TailscaleOAuthClientKey>());
    final credential = (input as TailscaleOAuthClientKey).credential;
    expect(credential.clientId, 'kXGGbs6CNTRL');
    expect(credential.clientSecret, 'tskey-client-kXGGbs6CNTRL-abcDEF123');
    // 格式不对也照样交给服务器判断，ID 写 -（Tailscale 自己的工具也不看 ID）。
    expect(
        (parseTailscaleKey('tskey-client-x') as TailscaleOAuthClientKey)
            .credential
            .clientId,
        '-');
  });

  test('tskey-api 和没前缀的：访问令牌；auth key 和别的 tskey-：直接拒绝', () {
    expect(
        (parseTailscaleKey('tskey-api-k1-x') as TailscaleAccessTokenKey).token,
        'tskey-api-k1-x');
    expect(parseTailscaleKey('legacy-token'), isA<TailscaleAccessTokenKey>());
    expect(
        (parseTailscaleKey('tskey-auth-k1-x') as TailscaleKeyRejected).reason,
        contains('auth key'));
    expect(parseTailscaleKey('tskey-webhook-x'), isA<TailscaleKeyRejected>());
  });

  test('Tailscale 的 os 字段认得出手机和平板', () {
    expect(normalizeDistroId('android'), 'android');
    expect(normalizeDistroId('iOS'), 'ios');
    expect(normalizeDistroId('tvOS'), 'ios');
    expect(normalizeDistroId('macOS'), 'macos');
    expect(normalizeDistroId('windows'), 'windows');
    expect(normalizeDistroId('linux'), 'linux');
  });

  testWidgets('Android、iOS 用 Material 图标，别的照旧用 SVG', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Row(children: [
        SystemIcon(distro: 'android'),
        SystemIcon(distro: 'ios'),
      ]),
    ));
    expect(find.byIcon(Icons.android), findsOneWidget);
    expect(find.byIcon(Icons.apple), findsOneWidget);
  });
}
