# NOTICE

本程序是 Netcatty Mobile 的修改版。

- 原作品：Netcatty Mobile，作者 kmh1145，<https://github.com/kmh1145/Netcatty-mobile>
- 原作品又参考并兼容 binaricat/Netcatty 桌面版：<https://github.com/binaricat/Netcatty>
- 许可证：GNU General Public License v3.0 or later，见 `LICENSE`。本修改版沿用同一许可证（下面「Apache-2.0 的部分」列出的目录除外）。

## 修改声明

自 2026-09-29 起，基于上游提交 `495f5d3174d6b3825fc9edefa7ebe345f3399734`（v1.4.7）修改。
修改内容按提交记录（`git log upstream/main..HEAD`）逐条可查，范围见 `plan/v3/`。

当前为个人隔离实验，未对外分发。

## Apache-2.0 的部分

下面四个目录是本修改版新写的插件 SDK 和样例，所有者 2026-10-07 决定以 Apache License 2.0 发布，每个目录里有 Apache-2.0 全文 `LICENSE`，
源码文件头有 `SPDX-License-Identifier: Apache-2.0`：

| 目录 | 是什么 |
|---|---|
| `packages/plugin_api/` | 插件契约的 Dart 类型、判定规则、描述符自查命令 |
| `plugins/provider-sdk/` | 宿主与插件共用的 AIDL 接口和认人工具（Java） |
| `plan/v3/contracts/` | 插件描述符的 JSON Schema、示例和负例 |
| `plugins/example/` | 插件样例 Hello 终端 |

- 来源：这四个目录的代码都是 2026-09-29 以后在本修改版里新写的。上游基座 `495f5d31` 里没有任何插件相关文件；
  逐行和基座比对，重合的只有 `import 'dart:convert';`、Gradle/清单的样板行这类通用写法，签名核对、Binder 校验、AIDL 在基座里一处都没有。
  `plugins/example/gradlew*`、`gradle/wrapper/` 是 Gradle 9.1.0 生成的文件，按 Gradle 自己的 Apache-2.0。
- 宿主（本程序，GPL-3.0-or-later）把 `packages/plugin_api`、`plugins/provider-sdk` 编进自己；Mosh 插件（`plugins/mosh`，GPL-3.0-or-later）也编进了 `plugins/provider-sdk`。
  这些文件在宿主和 Mosh 插件里仍是 Apache-2.0，Apache-2.0 能和 GPLv3 合用；宿主和 Mosh 插件整体仍按 GPL-3.0-or-later 分发。
- 除上表以外，仓库其余部分（包括测试插件 `plugins/fixture-*`、Mosh 插件 `plugins/mosh`）仍是 GPL-3.0-or-later。

