import 'package:libghostty/libghostty.dart';

void main() {
  final mode2048 = SizeReportStyle.mode2048.encode(
    rows: 24,
    columns: 80,
    cellWidth: 9,
    cellHeight: 18,
  );
  print('Mode 2048: ${mode2048.codeUnits}');

  final csi18t = SizeReportStyle.csi18T.encode(
    rows: 24,
    columns: 80,
    cellWidth: 9,
    cellHeight: 18,
  );
  print('CSI 18 t:  ${csi18t.codeUnits}');
}
