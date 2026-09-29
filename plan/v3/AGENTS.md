# V3实施契约

当前唯一计划：2026-09-29 V3 Flutter二开。旧Kotlin/SSHJ Txx退役，V2草稿由V3覆盖。先读README、STATUS、docs/00/01/03/04/05/06/07/15/19及tasks.json。

只操作用户明确指定的新fork；保留dirty、版权与许可证。Netcatty优先/GPL条件明确；Conduit替代要记录ADR，不复制GPL后改名许可。不覆盖上游applicationId或签名，不猜历史仓库。

主App沿用Flutter/Riverpod/dartssh2；目标libghostty/flterm，旧xterm2仅迁移基线。Kotlin只负责必要Android桥/服务；Mosh运行时在独立插件中，不引入全局Rust/Compose/SSHJ重写。不做VPN。

网络：RoutePlan唯一，代理/跳板失败不直连；目标解析交正确端点；每跳host key先于认证；SSH/SFTP/监控统一路由。恢复不重放用户输入或startup，不暗建/暗杀tmux。终端原始字节、有界资源、单view/单输入所有者。

插件：bundled/独立APK/external adapter分开；外部代码不载入宿主、不下载后执行native。逐Binder事务校验UID+签名+授权+owner+generation。薄typed API，不给任意exec或Vault读取。停止、撤销、更新及死亡不得影响其他会话。独立签名作者无需私钥共享。

Mosh首版仅显式Direct UDP，SOCKS/Jump预先拒绝；SSH+TailSocks不等于Mosh。UU/RustDesk外部App不继承SSH路由、启动不等于已连接；UU当前协议目标Windows/macOS，不能假称Linux支持。任何敏感URL或callback均有固定结构/目标和一次性关联；不传远控密码URL。

默认关闭继承AI/云同步/自动管理的非本次功能路径，凭据不进日志/普通导出/备份。生产账号、测试主机、安装、VPN配置、签名、额度、push/发布需明确授权；不擅自改变用户系统。

未有设备/授权写NOT_RUN/BLOCKED，继续独立任务；禁止拿Echo、参考App或计划校验当真实成功。完整范围含X00–X13，Ghostty成为实际默认且同候选全门禁通过才FULL_READY；CORE_READY不是完整V3完成。

粒度commit、同步任务/状态/证据/文档。文档接口是设计，不可臆造第三方API。额外功能只按P6授权后进入，不建设插件商城或任意脚本VM。
