import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shun/infrastructure/ssh/sftp_service.dart';
import 'package:shun/presentation/widgets/sftp_permissions_dialog.dart';
import 'package:shun/presentation/widgets/sftp_transfer_dialogs.dart';

import 'support/prism_test_host.dart';

class _PartialFile extends Fake implements FileTransferService {
  _PartialFile(this.size);
  final int? size;

  @override
  Future<int?> fileSize(String path) async => size;
}

Future<BuildContext> _host(WidgetTester tester) async {
  const key = ValueKey('host');
  await tester.pumpWidget(const MaterialApp(
    localizationsDelegates: prismTestDelegates,
    builder: prismTestBuilder,
    home: SizedBox(key: key),
  ));
  return tester.element(find.byKey(key));
}

Future<int?> _permissions(BuildContext context) => showDialog<int>(
      context: context,
      builder: (_) =>
          const SftpPermissionsDialog(name: 'report.txt', initialMode: '644'),
    );

Future<void> _tapAction(WidgetTester tester, String key, String label) async {
  final button = find.byKey(ValueKey(key));
  final node = tester.getSemantics(button);
  expect(node.label, label);
  expect(node.getSemanticsData().flagsCollection.isButton, isTrue);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> _tapBarrier(WidgetTester tester) async {
  await tester.tapAt(const Offset(4, 4));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('权限：非八进制留在弹层，四位模式按八进制返回', (tester) async {
    final result = _permissions(await _host(tester));
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('sftp-permissions-input'));
    expect(tester.getSemantics(input).value, '644');
    expect(find.byKey(const ValueKey('sftp-permissions-help')), findsOneWidget);

    await tester.enterText(input, '888');
    await _tapAction(tester, 'sftp-permissions-apply', '应用');
    expect(find.text('请输入 3 或 4 位八进制权限（0-7）'), findsOneWidget);

    await tester.enterText(input, '4755');
    await _tapAction(tester, 'sftp-permissions-apply', '应用');
    expect(input, findsNothing);
    expect(await result, int.parse('4755', radix: 8));
  });

  testWidgets('权限：取消或点遮罩都不应用输入', (tester) async {
    final context = await _host(tester);
    for (final barrier in [false, true]) {
      final result = _permissions(context);
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('sftp-permissions-input')), '777');
      if (barrier) {
        await _tapBarrier(tester);
      } else {
        await _tapAction(tester, 'sftp-permissions-cancel', '取消');
      }
      expect(
          find.byKey(const ValueKey('sftp-permissions-input')), findsNothing);
      expect(await result, isNull);
    }
  });

  testWidgets('同名文件：只有明确点替换才同意覆盖', (tester) async {
    final context = await _host(tester);
    for (final (key, label, expected) in [
      ('sftp-replace-cancel', '取消', false),
      ('sftp-replace-confirm', '替换', true),
      (null, null, false),
    ]) {
      final result = confirmReplaceDialog(
          context, 'report.txt', const FileStamp(2048, null));
      await tester.pumpAndSettle();
      expect(find.textContaining('report.txt\n2.0 KB'), findsOneWidget);
      if (key == null) {
        await _tapBarrier(tester);
      } else {
        await _tapAction(tester, key, label!);
      }
      expect(find.byKey(const ValueKey('sftp-replace-confirm')), findsNothing);
      expect(await result, expected);
    }
  });

  testWidgets('续传：续传、从头传、取消和点遮罩分别返回原来的选择', (tester) async {
    final context = await _host(tester);
    for (final (key, label, expected) in [
      ('sftp-resume-continue', '续传', true),
      ('sftp-resume-restart', '从头传', false),
      ('sftp-resume-cancel', '取消', null),
      (null, null, null),
    ]) {
      final result = askResumeDialog(
          context, _PartialFile(4), '/report.part', 'report', 10);
      await tester.pumpAndSettle();
      expect(find.textContaining('report\n4 B / 10 B'), findsOneWidget);
      if (key == null) {
        await _tapBarrier(tester);
      } else {
        await _tapAction(tester, key, label!);
      }
      expect(find.byKey(const ValueKey('sftp-resume-continue')), findsNothing);
      expect(await result, expected);
    }
  });

  testWidgets('续传：没有临时文件、空文件或过大的文件都不弹询问', (tester) async {
    final context = await _host(tester);
    for (final size in [null, 0, 11]) {
      final result = askResumeDialog(
          context, _PartialFile(size), '/report.part', 'report', 10);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sftp-resume-restart')), findsNothing);
      expect(await result, isFalse);
    }
  });
}
