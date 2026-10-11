import 'package:flutter_test/flutter_test.dart';
import 'package:shun/domain/terminal_paste.dart';

// R19 / SEC10、TER09：粘贴前整理和数风险。预览里看到的就是要发的。
void main() {
  test('一行普通命令：原样，不用预览', () {
    final review = PasteReview.of('ls -la "~/My Files"');
    expect(review.text, 'ls -la "~/My Files"');
    expect(review.lines, 1);
    expect(review.needsReview, isFalse);
  });

  test('从网页复制的命令带一个末尾换行：去掉，要预览（不然没开 2004 时粘贴即执行）', () {
    final review = PasteReview.of('sudo reboot\n');
    expect(review.text, 'sudo reboot');
    expect(review.trailingNewlines, 1);
    expect(review.multiline, isFalse);
    expect(review.needsReview, isTrue);
  });

  test('Windows 换行统一成 \\n，不会变成两个回车', () {
    final review = PasteReview.of('echo 1\r\necho 2\r\n');
    expect(review.text, 'echo 1\necho 2');
    expect(review.lines, 2);
    expect(review.trailingNewlines, 1);
  });

  test('控制字符去掉并按名字计数；换行、Tab 留着', () {
    final review = PasteReview.of('a\x1b[31mb\x03c\x10\td\x7f\u009b');
    expect(review.text, 'a[31mbc\td');
    expect(review.removedControls, {
      'Esc': 1,
      'Ctrl-C': 1,
      'Ctrl-P': 1,
      'Delete': 1,
      'C1 0x9B': 1,
    });
    expect(review.tabs, 1);
    expect(review.needsReview, isTrue);
  });

  test('看不见的排版字符（从右到左覆盖、零宽）要提醒，但不去掉', () {
    final review = PasteReview.of('echo safe\u202e#lmth.exe\u200b');
    expect(review.text, contains('\u202e'));
    expect(review.invisibleFormatting, 2);
    expect(review.needsReview, isTrue);
  });

  test('中文、emoji、组合字符原样保留', () {
    const text = 'echo 你好👍e\u0301';
    final review = PasteReview.of(text);
    expect(review.text, text);
    expect(review.needsReview, isFalse);
  });

  test('很长的一行也先预览', () {
    final review = PasteReview.of('x' * (PasteReview.longText + 1));
    expect(review.multiline, isFalse);
    expect(review.needsReview, isTrue);
  });

  test('只有换行或控制字符：整理后是空的', () {
    expect(PasteReview.of('\n\n').text, isEmpty);
    expect(PasteReview.of('\x03').text, isEmpty);
    expect(PasteReview.of('\x03').lines, 0);
  });
}
