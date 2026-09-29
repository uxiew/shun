# 11 Conduit替代路线

## 触发条件

所有者明确不接受Netcatty的GPL分发约束，或R00/R01证明基座成本与风险不可接受时，切换Conduit。不能两边并行维护完整App；不能先复制GPL代码再声称新Apache分支没有GPL影响。用户未定公开分发时不强迫立即公开个人实验。[S02](13-sources.md#s02) [S10](13-sources.md#s10) [S34](13-sources.md#s34)

## 具体差异

Conduit当前读取的SshClientFactory使用TcpSshSocket.connect；RoutingTerminalRepository只是SSH/Mosh/local协议选择。因而必须新建显式TransportDialer+RouteResolver，并将terminal/SFTP/测试等所有SSH创建入口汇总，不只修改某一个页面。[S11](13-sources.md#s11) [S13](13-sources.md#s13)

| Netcatty主线模块 | Conduit相应落点/处理 |
|---|---|
| HostProfile与route扩展 | features/hosts/domain/saved_host.dart及主机存储/编辑 |
| ssh_service.dart路由 | features/terminal/data/ssh_client_factory.dart提取socket创建；复用其trust与hardware signer |
| TerminalSessionAdapter | features/terminal/domain/ssh_terminal_session.dart已暴露字节；替换presentation中的conduit_vt |
| SFTP共享路径 | features/sftp/data/dart_ssh_sftp_repository.dart及工厂调用者统一接route |
| session controller | terminal_workspace_controller及tmux恢复状态，按实际SHA定位 |
| Tailscale目录 | 独立features/tailscale，输出现有SavedHost，不耦合组网 |

继续使用Conduit自己的状态管理，**不为和主线文档一致强行迁入Riverpod**。保留其硬件键/外部认证优势，确认与当前fork dartssh2 API兼容；不直接换成pub最新版破坏签名能力。conduit_vt与dartssh2_conduit的Git pin独立冻结。[S12](13-sources.md#s12)

## 范围调整

本地Arch/proot不是本需求：首版构建变体可以明确排除相关入口、二进制、下载器和高权限；保留则按真实依赖单独履行许可与测试。Mosh虽已有实现，不能因此宣布SOCKS CONNECT支持其UDP。SFTP/tmux/主题照旧回归。[S10](13-sources.md#s10)

## 任务映射

R00–R04改为Conduit基线和加路由可行性，A01–A07只是Netcatty观察不适用；不能记“已修复”来混充结果。R05–R10由加固变成新增RoutePlan/SOCKS/ProxyJump；R11–R31的产品合同、Tailscale目录、Ghostty与验收继续有效。所有源码落点和基线指标重新记录，不复用另一基座的PASS。

切换需更新tasks.json中的base_repository、observed-baselines.json、源代码映射和STATUS，保留本次选择理由；不改变无直连/host trust/无重放等硬约束。

## V3插件适配

切换Conduit不取消X00–X13，仅将registry/bridge落在其既有分层。已有Mosh使用dart_mosh（Dart组件，不是native客户端）。可作为X08优先试验候选，但要统一受控bootstrap、route和独立APK契约；不要既保留一套隐式直连Mosh又增加另一套插件。原Apache许可不免除Mosh/RustDesk子组件许可，用户自定闭源分发前必须独立复核。
