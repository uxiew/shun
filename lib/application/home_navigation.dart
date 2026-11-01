import 'package:flutter_riverpod/flutter_riverpod.dart';

final homeTabProvider = StateProvider<int>((ref) => 0);

/// 加一就打开会话总览（F35）。平时在终端页两指上滑；另一个入口是快捷栏「更多」，读屏时要用。
final sessionOverviewRequestProvider = StateProvider<int>((ref) => 0);

final sftpNavigationRequestProvider =
    StateProvider<SftpNavigationRequest?>((ref) => null);

class SftpNavigationRequest {
  const SftpNavigationRequest({
    required this.sessionId,
    this.filePath,
  });

  final String sessionId;

  /// 要定位到的远端文件；null 只把左栏切到这条 SSH（主机菜单里的「文件」，R43）。
  final String? filePath;
}
