# 许可

下面是事实和现状，**不是法律意见**。对外分发你的插件之前，自己核对许可条件，拿不准就问懂行的人。

## 各部分是什么许可

| 部分 | 来源 | 许可 |
|---|---|---|
| 宿主 xwshun | [Netcatty Mobile](https://github.com/kmh1145/Netcatty-mobile)（作者 kmh1145）v1.4.7（`495f5d31`）的修改版，保留原作者版权 | GPL-3.0-or-later（仓库根目录 `LICENSE`、`NOTICE.md`） |
| 契约库 `plugins/provider-sdk`（AIDL + Java 工具类） | 本 fork 2026-09-29 之后新写的；上游基座里没有任何插件相关文件 | 目前**没有单独的许可声明**，跟着仓库按 GPL-3.0-or-later |
| `packages/plugin_api`（Dart 判定规则、自查命令） | 同上 | 同上 |
| 描述符 schema `plan/v3/contracts/` | 同上 | 同上 |
| 样例 `plugins/example` | X12 新写 | 同上；描述符里写的 `license` 是 `GPL-3.0-or-later`。`gradlew`、`gradle/wrapper/` 是 Gradle 9.1.0 自己生成的文件（Gradle 是 Apache-2.0） |
| Mosh 插件 `plugins/mosh` | 本 fork 的插件代码 + 静态链接的官方 mosh-client 1.4.0（GPL-3.0-or-later，带 OpenSSL 例外）、protobuf（BSD-3-Clause）、OpenSSL 3（Apache-2.0）、ncurses（MIT 类） | **整个插件按 GPL-3.0-or-later 分发**，对外发要能提供对应源码。明细见 `plugins/mosh/LICENSES.md` |
| 宿主里的 UU 远程、RustDesk 调用 | 宿主只按对方公开的链接格式拉起用户手机上装的 UU 远程、RustDesk，不含它们的代码 | 跟着宿主。RustDesk 本身是 AGPL-3.0，UU 远程是网易的商业软件，各按各的 |

怎么核对「SDK 全是本 fork 新写的」：`git blame` 这三个目录（`packages/plugin_api`、`plugins/provider-sdk`、`plan/v3/contracts`），
2026-10-07 时全部行的作者都是本 fork 的提交者；`git ls-tree -r 495f5d31` 里没有这些文件。

## 这对你意味着什么

- **现在样例和契约库是按 GPL-3.0-or-later 给你的。** 你照抄样例代码、把 `provider-sdk` 编进自己的插件，再对外分发这个插件，就要按 GPL 的条件来（比如提供对应源码）。
- 契约库和样例要不要改成更宽松的许可（比如 Apache-2.0）发给第三方作者，**由项目所有者决定，还没定**。定了之后这里和各文件的许可声明会一起改；没改之前以现在的为准。
- 只用接口约定、不抄代码（自己按 [contract.md](contract.md) 重写 AIDL 和认人逻辑），是另一种情况，同样不在这里下结论。
- **单独做成一个 APK、经 AIDL 和宿主通信，不会自动让你绕开 GPL 或 AGPL。** 进程分开、独立安装、走 Binder，本身都不能证明两个程序不构成一个组合作品；
  要看接口耦合程度、怎么分发、改了什么。宿主自己的 GPL 条件也不会因为插件化而消失。
- 你的插件用了别人的代码（比如 AGPL 的 RustDesk 核心），那部分的义务照旧，拆成独立 APK 不豁免。

## 参考过、但没拿来的

- **LobiShell** 的插件做法（独立 APK、AIDL 会话服务、会话和画面分开）是设计借鉴，没有用它的代码、界面素材或商标。
  它 README 里对「闭源宿主 + 独立 GPL/AGPL 插件」的许可解释是那个作者的说法，不是本项目的结论。
- OpenPGP API、Termux:API 的跨 App 接口经验同样只是借鉴。

## 你的插件描述符里写什么

`license` 写你的插件**实际**的许可（建议 SPDX 写法，比如 `GPL-3.0-or-later`、`Apache-2.0`），宿主详情页原样显示给用户。
有公开源码就写 `sourceUrl`（只许 `https://`）。不写不会被拒，但用户看不到你按什么条件提供它。
