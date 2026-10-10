# Flutter移动终端二开计划 V3

**Netcatty-mobile优先 + libghostty/flterm + Tailscale目录 + ProxyJump/SOCKS5 + 可安装插件。**

日期：2026-09-29。独立新fork；Netcatty基座以接受GPL条件为前提，Conduit为替代。不从零写Kotlin应用，不创建VPN。此包只有研究、契约、任务和验收设计，不是App源码/APK。

## 这版包含什么

复用并加固现有SSH/SFTP/身份/会话；替换Flutter xterm2为Ghostty VT+Flutter flterm。增加目录导入、明确路由、轻量provider注册、独立Mosh APK及UU/RustDesk外部联动。Mosh只先支持Direct UDP；RustDesk内嵌桌面单列后续。不要把外部App拉起称为内嵌或已连接。

## 阅读入口

|文档|用途|
|---|---|
|[修订结论](docs/00-revision-overview.md)|覆盖旧方案的决策与边界|
|[基座与代码评审](docs/01-source-review.md)|选择Netcatty/Conduit的依据与待复验风险|
|[路线](docs/04-network-routes.md) / [Tailscale](docs/05-tailscale.md) / [Ghostty](docs/06-ghostty.md)|三个核心增量的契约|
|[插件研究](docs/14-plugin-research.md) / [插件架构](docs/15-plugin-architecture.md)|社区事实、运行模型、签名、IPC和权限|
|[Mosh](docs/16-mosh-plugin.md) / [远控](docs/17-remote-desktop-plugins.md)|真实插件与外部App接入边界|
|[作者SDK](docs/18-plugin-author-sdk.md)|作者交付、签名、样例和调试|
|[参考App](docs/20-reference-apps.md)|TermRover、LobiShell 实地看过的交互：学哪些、不学哪些，R39–R50 从这来|
|[任务](docs/08-implementation-tasks.md) / [验收](docs/09-verification.md)|65项任务（52主线/13后续），148项用例|
|[交接](docs/10-agent-handoff.md) / [里程碑](docs/19-revised-milestones.md)|其他模型的启动与持续实施|
|[来源](docs/13-sources.md)|63项公开原始资料及证据限制|

**实施进度、已做的改动和下一批只看 [STATUS.md](STATUS.md)**，本页不重复。规划检查结果不当App测试。

```bash
../../../.toolchain/pyenv/bin/python3 scripts/validate_plan.py   # 在 plan/v3 下跑
```

要用工具链里的 Python：系统自带的没有 jsonschema，结果会是 `"passed": false`、错误只有一条 `jsonschema missing`，看着像计划坏了，其实是 schema 检查没跑。

只检查文档、schema示例、依赖与ID。包内无APK、真实凭据、字体文件或用户照片。目标仓库与 applicationId 已由所有者指定；正式名称、签名与发布仍待定（见 STATUS.md）。
