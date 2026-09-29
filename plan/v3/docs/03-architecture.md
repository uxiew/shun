# 03 架构与实际改动边界

## 不重写已有分层

继续沿用Netcatty的domain / application / infrastructure / presentation和Riverpod。替换边界围绕终端、路由、目录及本次明确要求的插件运行时。新增小型PluginRegistry/SessionKind与Android IPC桥；不建设插件商城或任意脚本VM，不引入全局Rust核心，也不把dartssh2全部改为原生通道。[S07](13-sources.md#s07) [S08](13-sources.md#s08)

```text
TailscaleCatalog ──导入/更新受管字段──> HostProfile + RouteProfile + IdentityRef
                                             │
                                     ConnectionCoordinator
                                     (attemptId/generation)
                                             │
                                      ResolvedRoutePlan
                  ┌──────────────────────────┼─────────────────────┐
             System TCP                 Existing SOCKS5      SSH jump channels
                  └──────────────────────────┴─────────────────────┘
                                             │
                                         dartssh2
                                     verified target client
                           ┌─────────────────┼────────────────┐
                          PTY              SFTP          控制exec/转发
                           │
                 raw bytes ⇄ TerminalSessionAdapter
                           │
                 libghostty + flterm TerminalView
```

## 修改落点

| 上游现有位置 | 本批最小修改 |
|---|---|
| lib/domain/models/host.dart | route引用/来源元数据；读旧字段但连接时统一解析；toString脱敏 |
| lib/infrastructure/ssh/ssh_service.dart | 提取物理dial与route编排，保留SSH通道实现；移除xterm2依赖与逐chunk解码 |
| lib/application/session_controller.dart | attempt/generation、Fresh/Restore、端口/SFTP借用资源失效 |
| lib/presentation/screens/terminal_screen.dart、terminal_screen_pane.dart | 仅通过终端adapter/view builder；输入映射不要复制两套 |
| lib/presentation/widgets/host_editor.dart | 三选一路由与高级组合、来源设备只读标识 |
| lib/infrastructure/storage/vault_repository.dart | 控制面secret独立存储、导出隔离、未知字段安全处理 |
| lib/infrastructure/ssh/sftp_service.dart、server_monitor_service.dart | 绑定已验证目标client；若独立重连必须走同一路由 |
| lib/infrastructure/ssh/connection_platform_service.dart、Android service | 服务状态与用户停止一致；保留平台适配不改成VPN |

路径来自上游结构和关键源码；实施时以冻结SHA重新定位。[S04](13-sources.md#s04) [S05](13-sources.md#s05) [S08](13-sources.md#s08)

建议新增 `domain/connection_route.dart`、`infrastructure/transport/`、`infrastructure/tailscale/`、`infrastructure/terminal/` 和对应application controller。不是强制文件名，不生成几十个package。

## 核心模型（本项目设计，不是SDK接口）

```text
RouteProfile { id, ingress: System | Socks5(proxyId), jumps: [HostRef] }
ResolvedRoutePlan { attemptId, routeRevision, ingressSnapshot,
                    orderedHops: [TargetIdentity], finalTarget }
TargetIdentity { configuredName, port, unixUser, trustKey, identityRef }
TerminalHandle { engine, feedBytes, inputActions, onBytes, resize, dispose }
CatalogConnection { id, canonicalTailnet?, authMode, secretRef, refreshedAt }
DeviceBinding { catalogId, deviceId, discoveredAddresses, discoveredName,
                sourceSnapshotAt, overrides, missingFromLatestSnapshot }
ConnectionLease { targetClient, generation, owner, dependentChannels }
```

用户编辑已有route只作用于下次连接。Host profile里的旧proxy/hostChain转换后若冲突不能静默选一套；执行前把有效路径显示出来。schema迁移必须带版本和回滚副本。新fork没有强制兼容整个桌面产品的义务，但读取过的既有用户数据不能暗丢；扩展字段先命名空间隔离。

## 所有权

一条终端连接可以拥有若干上游跳板client，关闭顺序从PTY/借用通道到最终client，再逆序跳板/入口socket。外部SOCKS服务不属于本App，关闭连接不停止该服务。暂不做全局跳板SSH连接池。

SFTP/监控/转发用同一已认证目标client时可以共享已有SSH运输层；它们不是共享单个SOCKS CONNECT后自行多路复用。代次失效后所有借用者明确报错，不能偷偷重建Direct连接。断开过程中未完成上传标为未知/中断，不自动覆盖重传。

TerminalView可以重建，controller与SSH资源不归页面随意销毁；每个flterm controller只附着一个view。切标签不得把同一controller同时放入预览与主视图。资源及协议回调约束见终端迁移文档。[S19](13-sources.md#s19)

## 状态

`Idle → ValidateRoute → DialIngress → ProxyHandshake → Hop[n]Trust/Auth → TargetTrust/Auth → AwaitingExternalCheck? → OpenPty → Active`。

取消/关闭使generation失效，关闭正在协商中的socket；迟到结果立即释放。网络通知只是提示，仍工作的流不强制重连。错误至少含stage、hopIndex、logicalTarget、retryable、safeCode，日志目标默认脱敏。

## V3：插件与会话分型

以docs/15为新增权威契约：TerminalSession、RemoteDesktopSession和ExternalLaunchAttempt不能合并为一个SSH active布尔值。TailscaleDeviceRef/RustDeskPeerRef/UuBindingRef分别属于各自provider；只经用户显式关联归到同一DeviceRecord，不按名称或IP自动合并。

真正独立安装APK只用于有独立运行时和独立发布价值的provider。UU/RustDesk外部调用适配器无需再套一个空APK。终端引擎是构建期适配器，不开放运行期下载.so。
