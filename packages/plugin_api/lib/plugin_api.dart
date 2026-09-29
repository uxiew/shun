/// 插件契约 v1（X00 草案）：描述符校验、注册准入、路由判定、会话分型、设备关联。
///
/// 只有类型和纯逻辑。Binder 逐事务的 UID/签名核对在 plugins/provider-sdk 的 CallerVerifier（X02），
/// owner/generation 校验随 X03 的会话接口实现，
/// 这里的规则是它必须遵守的判定口径。
library;

export 'src/admission.dart';
export 'src/descriptor.dart';
export 'src/devices.dart';
export 'src/routes.dart';
export 'src/sessions.dart';
