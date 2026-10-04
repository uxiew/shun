import 'package:libghostty/libghostty.dart';

void main() {
  final encoder = MouseEncoder()
    ..setTrackingMode(.normal)
    ..setFormat(.sgr)
    ..setSize(
      const MouseEncoderSize(
        screenWidth: 640,
        screenHeight: 384,
        cellWidth: 8,
        cellHeight: 16,
      ),
    );

  final event = MouseEvent()
    ..action = .press
    ..button = .left
    ..setPosition(x: 100.0, y: 200.0);

  final press = encoder.encode(event);
  print('Press: $press');

  event.action = .release;
  final release = encoder.encode(event);
  print('Release: $release');

  event.dispose();
  encoder.dispose();
}
