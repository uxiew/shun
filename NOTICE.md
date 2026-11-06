# NOTICE

本程序 shun 是 Netcatty Mobile 的修改版。

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

## Prism UI（R82）

宿主使用 [chen08209/prism_ui](https://github.com/chen08209/prism_ui)，固定 Git 提交
`63450c0ac0e8e1b2c0f3ed4ad7926dc94e083185`（pubspec 版本 0.1.2）。
上游声明 GPL-3.0，全文见该提交的 [LICENSE](https://github.com/chen08209/prism_ui/blob/63450c0ac0e8e1b2c0f3ed4ad7926dc94e083185/LICENSE)；
此处不将其扩写为 “or later”。依赖及下列源码署名保持上游许可，不适用本仓库插件 SDK 的 Apache-2.0 声明。

上游 [NOTICE](https://github.com/chen08209/prism_ui/blob/63450c0ac0e8e1b2c0f3ed4ad7926dc94e083185/NOTICE) 列出的内嵌来源：

| 路径 / 来源 | 版权署名 | 许可证 |
|---|---|---|
| `lib/hct/` / material_color_utilities | Copyright 2021 Google LLC | Apache-2.0 |
| `lib/shapes/` / material_new_shapes | Copyright (c) 2025 Agbama Gifted | MIT |
| `lib/sliver_list/` / super_sliver_list | Copyright (c) 2024 Matej Knopp, Superlist and the contributors | MIT |
| `lib/navigator_resizable.dart` / navigator_resizable | Copyright (c) 2024 Daichi Fujita | MIT |
| `shaders/ink_sparkle.frag` / Flutter | Copyright 2013 The Flutter Authors | BSD-3-Clause |

本批新增传递依赖 `freezed_annotation 3.1.0` 为 MIT；原有 `collection 1.19.1`
为 BSD-3-Clause，`path_parsing 1.1.0` 为 MIT，均未升级。Dart 包许可证随 Flutter 构建收集；
正式分发时继续核对完整许可产物（R27/R29），本条不代表发布验收完成。

Flutter 不会自动读取依赖中的单数 `NOTICE`；五项署名和对应许可全文另保存在
`licenses/prism_ui-third-party.txt`，通过 `flutter.licenses` 纳入 App 的许可证产物。

视觉参照为 FlClash `be84736605527034689c95bf27828ff27d912c5e`，本批未复制其业务代码、品牌或资源。

## 编进 App 的 Android 第三方库

安全密钥（R59）和手机互传扫码（R62）带进来的。Dart 依赖的许可证由 Flutter 自己收集，这几个不走那条路，所以写在这里。

| 库 | 版本 | 许可证 |
|---|---|---|
| [yubikit-android](https://github.com/Yubico/yubikit-android)（`android`、`core`、`fido`） | 3.1.0 | Apache-2.0 |
| [Moshi](https://github.com/square/moshi) | 1.15.2 | Apache-2.0 |
| [SLF4J API](https://www.slf4j.org/) | 2.0.17 | MIT |
| [JSpecify](https://github.com/jspecify/jspecify) | 1.0.0 | Apache-2.0 |
| [zxing-android-embedded](https://github.com/journeyapps/zxing-android-embedded) | 4.3.0 | Apache-2.0 |
| [ZXing core](https://github.com/zxing/zxing) | 3.4.1 | Apache-2.0 |
