# Flutter移动终端二开计划 V3

**Netcatty-mobile优先 + libghostty/flterm + Tailscale目录 + ProxyJump/SOCKS5 + 可安装插件。**

日期：2026-09-29。独立新fork；Netcatty基座以接受GPL条件为前提，Conduit为替代。不从零写Kotlin应用，不创建VPN。此包只有研究、契约、任务和验收设计，不是App源码/APK。

## 这版包含什么

复用并加固现有SSH/SFTP/身份/会话；替换Flutter xterm2为Ghostty VT+Flutter flterm。增加目录导入、明确路由、轻量provider注册、独立Mosh APK及UU/RustDesk外部联动。Mosh只先支持Direct UDP；RustDesk内嵌桌面单列后续。不要把外部App拉起称为内嵌或已连接。

## 阅读入口

**2026-11-14当前主线：** FlClash / prism_ui单一目标迁移，R81–R88及GU0、GU1已完成，下一项R89凭据、代理与Tailscale面板。设置与安全数据页、连接首页与目录列表、主机表单已迁移，其余业务页面尚未迁移；当前数量和结果统一看STATUS与对应JSON，不把下方初始研究描述当成未开始整个项目。

|文档|用途|
|---|---|
|[修订结论](docs/00-revision-overview.md)|覆盖旧方案的决策与边界|
|[基座与代码评审](docs/01-source-review.md)|选择Netcatty/Conduit的依据与待复验风险|
|[路线](docs/04-network-routes.md) / [Tailscale](docs/05-tailscale.md) / [Ghostty](docs/06-ghostty.md)|三个核心增量的契约|
|[插件研究](docs/14-plugin-research.md) / [插件架构](docs/15-plugin-architecture.md)|社区事实、运行模型、签名、IPC和权限|
|[Mosh](docs/16-mosh-plugin.md) / [远控](docs/17-remote-desktop-plugins.md)|真实插件与外部App接入边界|
|[作者SDK](docs/18-plugin-author-sdk.md)|作者交付、签名、样例和调试|
|[参考App](docs/20-reference-apps.md)|TermRover、LobiShell 实地观察；OSH、meshTerm、NovaScale、Dokodemo CLI、ShellDiver 官方资料；R39–R57 的取舍与证据边界|
|[安全密钥、同步导出、安全设置计划](docs/21-credentials-sync-plan.md)|R26 F25、F23、F22 的调研结论、所有者 10-31 的决定和分阶段方案|
|[交互复盘](docs/23-ux-reference-review.md)|F41/F42保留行为，新建连接和Tailscale流程|
|[UI迁移方案](docs/24-ui-migration.md) / [选型决策](../../docs/decisions/ui-system-decision.md)|唯一目标FlClash / prism_ui；六阶段R81–R98、门禁与模型执行边界|
|[未完成事项的优先级和计划](docs/22-priorities.md)|所有者 11-01 要的：每条的规模、难点、影响、先后|
|[AI CLI 启动与继续](docs/02-product-scope.md)|工具发现已验收（R55）；项目启动、最近工作和继续入口的无账号矩阵已验收，R56–R57 仍待真实原生对话验证|
|[任务](docs/08-implementation-tasks.md) / [验收](docs/09-verification.md)|全部当前任务、依赖与验收；数量/状态以JSON和STATUS为准|
|[交接](docs/10-agent-handoff.md) / [里程碑](docs/19-revised-milestones.md)|其他模型的启动与持续实施|
|[来源](docs/13-sources.md)|公开原始资料及证据限制，含固定FlClash/Prism来源S89–S102|

**实施进度、已做的改动和下一批只看 [STATUS.md](STATUS.md)**，本页不重复。规划检查结果不当App测试。

```bash
python3 scripts/validate_plan.py   # 在 plan/v3 下跑；要带 jsonschema 的 python3
```

报 `jsonschema missing` 是 Python 选错了，不是计划坏了，见 [开发手册第 5 节](../../docs/dev/README.md#5-改任务状态)。

只检查文档、schema示例、依赖与ID。包内无APK、真实凭据、字体文件或用户照片。目标仓库与 applicationId 已由所有者指定；正式名称、签名与发布仍待定（见 STATUS.md）。
