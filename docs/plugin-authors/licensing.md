# 许可

下面是事实和现状，**不是法律意见**。对外分发你的插件之前，自己核对许可条件，拿不准就问懂行的人。

## 各部分是什么许可

| 部分 | 来源 | 许可 |
|---|---|---|
| 契约库 `plugins/provider-sdk`（AIDL + Java 工具类） | 本 fork 2026-09-29 之后新写的 | **Apache-2.0**（目录里的 `LICENSE`，文件头 `SPDX-License-Identifier: Apache-2.0`） |
| `packages/plugin_api`（Dart 判定规则、自查命令） | 同上 | **Apache-2.0** |
| 描述符 schema `plan/v3/contracts/` | 同上 | **Apache-2.0** |
| 样例 `plugins/example` | X12 新写 | **Apache-2.0**；描述符里的 `license` 也是 `Apache-2.0`。`gradlew`、`gradle/wrapper/` 是 Gradle 9.1.0 生成的文件，按 Gradle 自己的 Apache-2.0 |
| 宿主 xwshun | [Netcatty Mobile](https://github.com/kmh1145/Netcatty-mobile)（作者 kmh1145）v1.4.7（`495f5d31`）的修改版，保留原作者版权 | GPL-3.0-or-later（仓库根目录 `LICENSE`、`NOTICE.md`） |
| Mosh 插件 `plugins/mosh` | 本 fork 的插件代码 + 静态链接的官方 mosh-client 1.4.0（GPL-3.0-or-later，带 OpenSSL 例外）、protobuf（BSD-3-Clause）、OpenSSL 3（Apache-2.0）、ncurses（MIT 类） | **整个插件按 GPL-3.0-or-later 分发**，对外发要能提供对应源码。明细见 `plugins/mosh/LICENSES.md` |
| 测试插件 `plugins/fixture-*` | 本 fork 写的测试用 App | GPL-3.0-or-later（跟着仓库） |
| 宿主里的 UU 远程、RustDesk 调用 | 宿主只按对方公开的链接格式拉起用户手机上装的 UU 远程、RustDesk，不含它们的代码 | 跟着宿主。RustDesk 本身是 AGPL-3.0，UU 远程是网易的商业软件，各按各的 |

上面四个 Apache-2.0 的目录全是本 fork 新写的：上游基座 `495f5d31` 里没有插件相关的文件，逐行比对也只重合通用的样板行（`import 'dart:convert';`、Gradle 配置这类）。

**宿主里也编进了同样的代码**：宿主把 `plugins/provider-sdk`、`packages/plugin_api` 作为子工程和依赖编进去，Mosh 插件也编进了 `provider-sdk`。
这些文件在宿主和 Mosh 插件里仍是 Apache-2.0；Apache-2.0 能和 GPLv3 合用，宿主和 Mosh 插件整体仍按 GPL-3.0-or-later 分发。

## 这对你意味着什么

- **你的插件可以按你自己选的许可发布**，包括闭源。照抄样例、把 `provider-sdk` 编进去都可以，按 Apache-2.0 的条件办：
  保留它们的版权和许可声明（`LICENSE` 和文件头），改过的文件写明改了。
- **你的插件里链接了 GPL 的代码，就要按 GPL 办。** 比如像 Mosh 插件那样静态链接 mosh-client：整个插件就得按 GPL-3.0-or-later 分发、提供对应源码。
  用了 AGPL 的代码（比如 RustDesk 核心）同理，按 AGPL 办。
- **宿主仍是 GPL-3.0-or-later**，SDK 改成 Apache-2.0 不改变这一点。
- **这里不给「插件是独立 APK、只经 AIDL 和宿主通信，所以不受宿主 GPL 影响」这类结论。** 进程分开、独立安装、走 Binder，本身都不能证明两个程序不构成一个组合作品；
  要看接口耦合程度、怎么分发、改了什么。SDK 是 Apache-2.0，说的是 SDK 这几份文件本身的条件，不是对你的插件和宿主之间关系的法律判断。

## 参考过、但没拿来的

- **LobiShell** 的插件做法（独立 APK、AIDL 会话服务、会话和画面分开）是设计借鉴，没有用它的代码、界面素材或商标。
  它 README 里对「闭源宿主 + 独立 GPL/AGPL 插件」的许可解释是那个作者的说法，不是本项目的结论。
- OpenPGP API、Termux:API 的跨 App 接口经验同样只是借鉴。

## 你的插件描述符里写什么

`license` 写你的插件**实际**的许可（建议 SPDX 写法，比如 `Apache-2.0`、`GPL-3.0-or-later`、`LicenseRef-Proprietary`），宿主详情页原样显示给用户。
有公开源码就写 `sourceUrl`（只许 `https://`）。不写不会被拒，但用户看不到你按什么条件提供它。
