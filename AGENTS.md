# 本 fork 的实施入口

这是 shun 的实施入口。shun 是 Netcatty-mobile 的**本地个人隔离实验 fork**（GPL-3.0-or-later，保留原作者版权），
按 V3 计划改造成 Flutter 移动终端。上游的功能说明在 `docs/UPSTREAM_README.md`，架构、目录、安全约定在 `docs/`。
用户看得到的行为改了，同步改使用手册 `docs/user/README.md`。

开始干活前先读 `plan/v3/AGENTS.md`（实施契约），再读 `plan/v3/STATUS.md`（当前进度）。
任务定义在 `plan/v3/tasks.json`，每批证据写在 `plan/v3/evidence/`。

硬规矩（详见 plan/v3/AGENTS.md）：

- 不 push、不发布，除非所有者开口。remote 只有 `origin` = `uxiew/shun`（原项目的 upstream 已清掉，基座 SHA 见 `docs/architecture/base-decision.md`）。
- applicationId 是 `top.xdwa.shun`（所有者 2026-10-11 从 `top.xdwa.xwshun` 改来）。不得改成上游的 `app.netcatty.mobile`，否则会覆盖手机上的原版 Netcatty 及其数据；
  也别再随手改：换了值手机就当成另一个 App，旧 App 的保险库、密钥不会跟过来。
- 没真机/没授权的用例写 NOT_RUN 或 BLOCKED，不许拿 mock、参考 App 或计划校验冒充通过。

工具链装在仓库外的 `../.toolchain/`，不依赖全局环境。每个终端先执行 `source ../.toolchain/env.sh`。
只加 Flutter 的 PATH 不够：少了 `NO_PROXY`，`flutter test` 会全部在 loading 阶段失败。
怎么跑测试、模拟器、真机，以及怎么清理，都写在 `docs/shun/README.md`。
