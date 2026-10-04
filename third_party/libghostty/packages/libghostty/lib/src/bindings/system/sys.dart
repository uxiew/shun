import '../../types/types.dart';

abstract interface class SystemBindings {
  void sysClearLogCallback();
  void sysClearPngDecoder();
  void sysClearRandomSecure();
  void sysSetLogCallback(SysLogCallback callback);
  void sysSetLogToStderr();
  void sysSetPngDecoder(PngDecoder decoder);
  void sysSetRandomSecure(SysRandomSecureCallback callback);
}
