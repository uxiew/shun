import 'package:libghostty/libghostty.dart';

void main() {
  final info = LibGhosttyBuildInfo.instance;
  print('Version: ${info.versionString}');
  print('Optimize: ${info.optimizeMode}');
  print('SIMD: ${info.simd}');
  print('Kitty graphics: ${info.kittyGraphics}');
  print('Tmux control mode: ${info.tmuxControlMode}');
}
