# 17 UU / RustDesk远控provider

## 1. 产品边界

首版是手机作为控制端，设备卡片提供远控入口；不让手机成为被控端。SSH与远控是并列能力。远控入口不进入Ghostty，不索要SSH凭据，不修改现有VPN。外部App管理账号、媒体与连接，宿主不能承诺接管其SOCKS路线或关闭其远端会话。

## 2. UU：官方跨App协议

本轮raw文档基准为客户端>=4.42.0，调用端Android/iOS、被控目标Windows/macOS；不支持把Linux、Android或TV设备作为本协议目标。正式包名观察为`com.netease.uuremote`。这是绑定/启动协议，不是可嵌入Flutter的远控SDK。[S42](13-sources.md#s42) [S43](13-sources.md#s43)

设计入口：设备卡片 → 添加UU绑定 → 显式启动官方设备授权页 → 校验回调 → 用户确认关联。保存`UuBindingRef`及加密opaque标识，不能尝试解密其内部格式或用IP推算ID。失败/账号变化只将该绑定标为失效，不删SSH或Tailscale记录。

协议形态（字段使用前再次比对冻结的官方版本）：

```text
uuremote://external/device/authorize?callback=<encoded>&nonce=<random>
uuremote://external/device/control?anonymous_device_id=<encoded>&window_type=0|1[&callback=<encoded>]
```

当前raw：全屏不回调；小窗有传有效callback才回调。绑定成功返回匿名ID/nonce，控制小窗返回status/reason。不要套用搜索缓存中旧版全屏回调规则。[S42](13-sources.md#s42)

### 本产品的安全实现

用URI builder编码参数，不手拼可信scheme后追加任意外部URL。按官方scheme检测能力，再限制Intent到已验证包/签名；不能把未验证的resolveActivity结果当官方客户端。平台签名摘要来自可信发行制品，不在计划里猜值。

callback为本产品固定接收点，`nonce`或callback中保留的`state`使用随机、一次性、有限期值，绑定pending request + device record + action + expected provider。校验参数数目、长度、重复字段、成功与失败互斥；未知结果按保守状态显示。onCreate与onNewIntent走同一验证器。

自定义scheme可能被别的App接管；state仅防无关联/重放，不能视为UU签名回调或防恶意已安装应用的完整保证。能使用自有已验证App Link时优先评估；无域名时保留风险说明，接收绑定后必须由用户确认，不能回调即自动远控。[S58](13-sources.md#s58)

匿名ID在本产品按敏感opaque引用保护，禁止日志、普通导出和剪贴板自动复制。存储按provider/account context隔离；更换账号造成失效时要求重新绑定，不索要UU密码或读取UU私有数据库。

### 状态不能虚报

全屏launch成功只显示“已交给UU远程”，没有连接成功回调不能标Active。PiP回调成功显示“UU已报告小窗就绪（时间）”，不是持续在线证明。用户回到本App、Activity启动成功或桌面出现图标都不能更新为Connected。

一次只允许一个UU请求；并发串行/明确取消，迟到回调不覆盖新请求。用户确认弹窗可能延迟回调，本地等待结束仅标“结果未确认”，不伪造远端失败、不自动重试。PiP不支持时提供用户手动改全屏，不能自动切换后标成功。

## 3. RustDesk：两级交付

### RDX-external：首版

通过验证过的RustDesk客户端scheme请求连接指定peer。当前代码支持连接URI；优先使用简单ID连接，不开放任意URI粘贴透传，不传密码，不调用config/password修改入口。Android manifest及URI处理应按安装版本复验。[S44](13-sources.md#s44) [S45](13-sources.md#s45)

用户先在RustDesk中配置自建ID/relay服务和认证；主App仅保存provider peer引用与显示名。包名、签名和自定义构建互相关联，用户选择自建客户端时建立新的可信provider配置，不能允许任意同scheme App抢占。

未获得真实状态回调的版本，只显示已发起，不能承诺连接/结束或撤销成功。失败不自动开启SSH或改远控服务器。主App的SSH SOCKS不自动作用于RustDesk；用户要求强制该路由时，本版拒绝外部调用或请用户明确另设远控网络策略。

### RDX-embedded：R38后续

若真正需要同一标签里显示桌面，可研究LobiShell RustDesk插件的AIDL + Surface模式。主App提供Android SurfaceView/PlatformView生命周期，插件持有native连接与画面；输入使用受限事件，不能用Dart逐帧Base64传整个视频。[S39](13-sources.md#s39) [S41](13-sources.md#s41)

先做单会话视频/输入PoC；选择、缩放、方向变化、鼠标键盘、IME、多显示器、音频等按实际能力逐步加。剪贴板、文件传输默认禁用，分别授权与测试。不继承整套RustDesk被控端/后台权限。

RustDesk核心及参考插件涉及AGPL，正式复用前审查来源、submodule、native依赖、修改源码提供、NOTICE及通信组合关系；拆APK不能自动豁免。LobiShell插件并不承诺兼容本产品，应实现本产品契约或合法fork后适配，不能伪装LobiShell包名调用它。[S39](13-sources.md#s39) [S56](13-sources.md#s56)

## 4. 设备聚合

`DeviceRecord`仅是用户组织对象：可关联一个或多个SSH HostRef、TailscaleDeviceRef、UuBindingRef、RustDeskPeerRef。相同hostname不证明同设备；跨provider不自动复制身份、密码、地址或在线状态。UU Windows限制应在入口上清楚显示；Linux设备可以继续SSH或另行实测RustDesk能力，不借UU绑定接口伪造兼容。
