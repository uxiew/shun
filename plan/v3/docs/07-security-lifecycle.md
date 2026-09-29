# 07 安全、继承功能与移动生命周期

## 认证边界

每一跳与目标按逻辑host+port或显式trust alias校验，不使用127.0.0.1代理地址作为known_hosts键。不因deviceId、100.x地址、成功列目录、同名设备而自动信任。首次人工核对，变更阻断；认证和外部check只在信任完成后继续。

SSH身份、SOCKS密码、Tailscale目录token、OAuth client secret分开存储和展示。现有Vault优先复用，但检查实际metadata/secret分离；HostProfile raw map/toString、错误对象、导出、云同步、crash、通知和终端内容都不是secret存储区。导入SSH私钥使用时可能进入Dart内存，secure_storage不等于所有签名都在硬件内完成。

控制面secret只进独立本地namespace；加密备份若未来包含它，必须独立授权，本版一律排除。仅清UI入口不算禁用AI或同步，需测试初始化、deep link、后台恢复和导出路径无非授权外连。

## 重连不是重新执行

定义ConnectionPurpose：FreshInteractive / RestoreInteractive / ReadOnlyProbe / ExplicitManagedAction。startup默认关闭；用户显式配置后只能在Fresh、明确确认作用域下执行。Restore、Probe不能执行。ManagedAction不是可重复重试的终端启动脚本。

SSH写成功不保证远端副作用已完成；断线后只报告结果未知。禁止重新发送历史键、Enter、粘贴或SFTP写操作。tmux恢复使用host/user/socket/server代次/session ID组成目标；缺失不新建，同名不认为同一会话，关标签不kill/Ctrl-C。

会话的旧terminal画面可以保留为“已断开历史”，但不能把旧VT状态与新普通shell直接拼接当成恢复。重新附着时初始化显示状态，清除待发送协议回应和修饰键，不能将旧输出再次feed导致再次响应远端查询。

## 生命周期

用户主动连接才启动相应前台服务，通知可停止；按真实用途审核类型与权限，不以media等伪装保活。Flutter、Dart isolate、Android service和进程死亡分别测试。FGS不保证永不断线；不使用永久wakelock或绕过force-stop。[S33](13-sources.md#s33)

停止时先失效generation再释放所有资源；后台回调不能复活。暂停UI不要求立即断线；设备锁定时新secret解密必须满足安全策略。自动重试只用于同一路由可恢复网络错误，总窗口建议120s；指纹、凭据、权限和未知外部check必须人工处理。

## 继承功能回归

SFTP、监控、tmux管理、转发、连接测试必须使用同一RoutePlan/最终已验证client。UI正常不代表这些后台辅助连接没有绕过代理。借用client被关闭后给出明确失效，不递归建Direct。保留上传取消/覆盖确认；远端管理动作默认不触发、不把诊断变成sudo管理。

端口转发若继续暴露本地TCP，说明同机应用可访问；默认回环不等于应用级隔离。禁止默认开放所有网卡；端口需用户启用，有清晰所有者/停止行为；不得作为无认证访问Tailscale SSH身份的自动桥。

## 远端输出是非信任数据

OSC剪贴板读取拒绝；写入需明确允许或首版全部禁用。标题/目录/超链接只用作受限显示；file/intent/javascript不执行。native解析器也需要长度/图像内存预算。新增外部链接check单独allowlist和用户动作；不能用终端WebView的桥打开网页（本方案终端本身没有WebView）。

## 发布与数据

新的applicationId与签名，不能覆盖原Netcatty安装和数据。先更名自有品牌，再保留作者版权与NOTICE。没有正式签名或分发授权不得发布。已有数据转换先导出安全副本并做roundtrip测试；未知字段不会因新功能被暗中丢弃，未知secret字段必须隔离而非透传进日志。

## V3跨应用信任补充

插件授权不是给整个Vault的授权。Mosh插件只得到本会话的临时key和必要地址；UU/RustDesk外部App不收到SSH或Tailscale凭据。逐次IPC验证真实caller UID与签名、session所有者及generation。普通包名不构成签名证明。

独立APK拥有自己的权限，主App无法仅凭manifest约束恶意插件的独立外连；签名/授权是信任选择，不是全能网络沙箱。撤销只保证主App停止调用、关闭自有通道和不再释放能力；无法保证外部App删除已复制的数据或停止远端会话。

插件崩溃只影响归属会话；重装/更新/签名变化需要重核验。native .so随各自APK构建，禁止将外部插件代码载入宿主UID以“省IPC”。用户停止与Android FGS合规须跨主App/插件共同验证。
