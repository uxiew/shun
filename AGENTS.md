# 本 fork 的实施入口

这是 shun 的实施入口。shun 是 Netcatty-mobile 的**本地个人隔离实验 fork**（GPL-3.0-or-later，保留原作者版权），
按 V3 计划改造成 Flutter 移动终端。文档地图在 `docs/README.md`；架构看 `docs/dev/architecture.md`，安全约定看 `docs/dev/security.md`。
`docs/` 只放 shun 自己写的文档：Netcatty 的旧文档和截图 2026-10-17 已删（所有者要求），别从上游搬回来；
代码来源和许可写在 `NOTICE.md`，那份要留。
用户看得到的行为改了，同步改使用手册 `docs/user/README.md`（Mosh 相关的改 `docs/user/mosh.md`）。

开始干活前先读 `plan/v3/AGENTS.md`（实施契约），再读 `plan/v3/STATUS.md`（当前进度）。
任务定义在 `plan/v3/tasks.json`，每批证据写在 `plan/v3/evidence/`。

硬规矩（详见 plan/v3/AGENTS.md）：

- 不 push、不发布，除非所有者开口。remote 只有 `origin` = `uxiew/shun`（原项目的 upstream 已清掉，基座 SHA 见 `docs/decisions/base-decision.md`）。
- applicationId 是 `top.xdwa.shun`（所有者 2026-10-11 从 `top.xdwa.xwshun` 改来）。不得改成上游的 `app.netcatty.mobile`，否则会覆盖手机上的原版 Netcatty 及其数据；
  也别再随手改：换了值手机就当成另一个 App，旧 App 的保险库、密钥不会跟过来。
- 没真机/没授权的用例写 NOT_RUN 或 BLOCKED，不许拿 mock、参考 App 或计划校验冒充通过。

Zig 由仓库 `mise.toml` 固定为 0.16.0，不跟随全局版本；其余工具链按 `docs/dev/README.md` 配置。
每个终端先用 `mise which zig` 设置 `SHUN_ZIG_EXECUTABLE`，再 `source ../.toolchain/env.sh`，最后把真实 Zig 所在目录放到 PATH 最前（避免 hooks 丢失自定义变量后命中旧包装器）。
只加 Flutter 的 PATH 不够：少了 `NO_PROXY`，`flutter test` 会全部在 loading 阶段失败。
怎么跑测试、模拟器、真机，以及怎么清理，都写在 `docs/dev/README.md`。
