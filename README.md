# xwshun

Android 上的 SSH 终端 + SFTP 文件管理，由 [Netcatty Mobile](https://github.com/kmh1145/Netcatty-mobile) v1.4.7 改造而来。
本机个人实验 fork：**不 push、不发布**。

**现状（2026-09-30）**：开发中。连接路线、凭据保管、Tailscale 设备目录、插件基础已改完，在 Android 模拟器上验证过；**还没上过真机**，没有安装包。
逐项进度看 [plan/v3/STATUS.md](plan/v3/STATUS.md)。

## 和原版的区别

| | 原版 Netcatty | xwshun |
|---|---|---|
| 代理配置无效或代理失败 | 有几种情况会悄悄直连 | 一律报错，写明哪台机器、哪一步 |
| 连接路径 | 代理、跳板分开配，跳板机上的代理会被隐式套用 | 直连 / 经代理 / 经跳板机三选一，保存前检查矛盾，实时显示路线，能「测试连接」 |
| 服务器指纹变了 | 点「确认更新」就能连 | 拦下，只能删除旧指纹后重新核对 |
| 导出保险库 | 明文，含密码和私钥 | 不含密码、私钥、代理口令 |
| AI、云同步、检查更新 | 开着 | 默认关，不联网 |
| Tailscale 设备目录 | 无 | 只读读取设备列表，批量导入为主机；导入不连接、不开 VPN |
| 导入保险库 | 直接整库替换，不提示 | 先说明会删什么，默认合并 |
| 独立插件 | 无 | Android 插件接口（实验），插件和 App 每次调用都互相核对签名 |
| 包名 | `app.netcatty.mobile` | `top.xdwa.xwshun`，能和原版装在同一台手机上 |

完整的用法和差异见 [使用手册](docs/user/README.md)。

## 快速开始

```bash
source ../.toolchain/env.sh    # 每个新终端都要先做，否则 flutter test 全部卡在 loading
flutter pub get
flutter test -j 4              # 真实 SSH 用例没起测试环境时自动跳过，不算失败
flutter run -d <设备ID>         # 设备 ID 用 flutter devices 查
```

工具链（Flutter 3.44.4 等）装在仓库外的 `../.toolchain/`，不用全局环境。模拟器、真实 SSH 测试环境、装真机、清理磁盘，都在 [本机手册](docs/xwshun/README.md)。

## 文档

| 想做什么 | 看这里 |
|---|---|
| 用这个 App | [docs/user/README.md](docs/user/README.md) |
| 在本机跑、测、装、清理 | [docs/xwshun/README.md](docs/xwshun/README.md) |
| 接着开发：规矩、进度、任务 | [plan/v3/AGENTS.md](plan/v3/AGENTS.md) → [STATUS.md](plan/v3/STATUS.md) → `plan/v3/tasks.json` |
| 插件契约、测试插件 | [plugins/README.md](plugins/README.md) |
| 真实 SSH / 代理 / 跳板测试环境 | [tool/fixture-environment/README.md](tool/fixture-environment/README.md) |
| 上游的功能介绍和截图 | [docs/UPSTREAM_README.md](docs/UPSTREAM_README.md) |
| 上游的架构、目录、安全约定 | [docs/README.md](docs/README.md) |

## 仓库里有什么

| 目录 | 内容 |
|---|---|
| `lib/` | App 本体（Flutter + Riverpod + dartssh2） |
| `android/` | Android 工程和原生代码：SSH 保活前台服务、画中画、手机目录授权、插件桥 |
| `packages/plugin_api/` | 插件契约 v1（Dart 端） |
| `plugins/` | 插件的 Android 契约与 SDK，加上只用于测试的插件 APK |
| `tool/` | 测试工具：真实 SSH / 代理 / 跳板的 Docker 测试环境、假 Tailscale API、凭据泄漏检查的写入入口 |
| `spikes/` | 终端引擎（Ghostty / flterm）的验证工程，不进 App |
| `plan/v3/` | 计划、任务、用例、每批的实测证据 |

## 三条硬规矩

- **不 push**：`upstream` 的 push 地址故意设成了 `NO_PUSH_see_plan_v3`，`git push` 报错是防手滑，不是配置坏了。
- **applicationId 不能改回 `app.netcatty.mobile`**：会覆盖手机上的原版 Netcatty 和它的数据。
- **没测就写没测**：没有真机或授权的用例记 NOT_RUN / BLOCKED；模拟器结果要标明是模拟器，不能当真机结果。

## 许可

GPL-3.0-or-later，沿用上游 Netcatty，保留原作者版权，见 [LICENSE](LICENSE)。
