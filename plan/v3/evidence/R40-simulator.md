# R40 Android 模拟器：链式路线、代理管理和旧配置转换

日期：2026-10-12。应用基线 `7777b1c`，本轮起点 `8a5ef13`；新增设备测试、执行脚本与用户/开发文档提交 `4a8e1a2`。本轮没有修改 `lib/` 或路由规则。R40 仍 IN_PROGRESS：首跳自带路线的选择/展开尚未实现，UX06 全范围保持 NOT_RUN，本记录仅证明已实现部分。

## 环境与执行边界

- Android 15 / API 35、arm64、4 KiB 页专用 AVD `shun-a35-4k`，固定 `emulator-5580`。1080×2400、约 411.43dp 宽，真实系统软键盘；没有扩大测试 viewport、伪造键盘 inset 或替换安全存储。
- 测试直接打开正式 `HostEditor`、`CatalogImportPage`、`ProxyProfilesPage` / `ProxyProfileEditor`，使用真实 `VaultController` / `VaultRepository` / Android 加密存储。轻量导航宿主代替首页，不计为首页、设置入口或完整终端页面回归。
- 本地 `tool/fixture-environment` 五个 Docker 容器：四台 OpenSSH 与一个 dante SOCKS；自检 **8/8 PASS**。只转发专用模拟器的本地端口；21080 为认证 SOCKS，21081 为无认证 SOCKS，21082 是指向同一认证 SOCKS 的另一个 adb 入口。入口变化证明拨号使用更新后的端口，不冒充两台独立代理；独立入口与已有活跃 SSH 不变的前轮证据见 [R40-chain](R40-chain.md)。
- 每个成功连接核对所有 SSH 跳的 ed25519 指纹并在目标执行 `hostname`，结果必须为 `target`；首段 TCP 只允许 `127.0.0.1` 的测试端口。目录页使用两个合成设备，仅检查导入结果，不请求真实 Tailscale、不连接其文档保留地址。
- 无用户真实主机、AI 账号、VPN、真机或 iOS 测试。没有调整输入法、Wi-Fi、锁屏或全局系统设置。

## 设备矩阵

| 场景 | 实际断言与观察 |
|---|---|
| 旧内联代理转换 | 取消新建不产生代理；新建保存后保留原密码和未知配置字段，当前草稿选中引用；取消主机编辑后原内联主机不变，新建代理仍在；重新选择并保存主机后移除内联字段，保留主机未知字段 |
| 链式编辑 | 从代理直达逐步加至 1、2、3 跳，每次保存后真实 SSH 成功；三跳时没有第四跳入口；上移、下移、移除、重新添加后的顺序为 hop3→hop2→edge，保存后的真实指纹顺序一致 |
| 代理管理 | 端口 0 拒绝且原配置不变；带认证配置改到无认证入口被拒，只有一次该入口拨号，不退回直连；改为 21082 后两台引用主机下次连接均使用新入口并成功 |
| 批量导入 | 与主机页使用正式共用链，选择同一代理、添加三跳后重排和移除；两个导入主机均保存相同代理 ID 和 edge→hop2 顺序 |
| 原路由规则 | 跳板自身配置代理时仍显示草稿错误并拒绝保存；明确清空才变直连，保存后引用与跳板字段清除；再次选择代理可以正常保存 |
| 未知旧配置 | 内联类型 `desktop-unknown` 保持原值；转换表单不默选成 SOCKS5，取消后仍保留原配置，拒绝直接保存；冷启动再次确认未知类型保留 |
| 冷启动 | 两阶段之间 force-stop，第二阶段使用不同 App PID；真实加密存储恢复代理 ID、端口、密码、三跳顺序、主机/代理未知字段；两台主机真实 SSH 再次成功 |
| 删除影响 | 确认框列出 legacy、peer 和两台目录主机；取消不变，确认后代理删除、主机引用保留；正在编辑的路线立即显示找不到代理并拒绝保存；再次连接在 RoutePlan 阶段拒绝，拨号次数不增加；代理密码安全存储键已删除 |
| 窄屏与键盘 | 中文转换表单实际弹出 Android IME，保存按钮可点；英文管理页可新建 HTTP 类型并保存，截图无布局溢出；HTTP 此处只验表单存储，不计 HTTP 代理网络互通 |
| 明文扫描 | 两阶段各扫描该测试 App 的 shared_prefs/files 和专用模拟器 Flutter 日志；测试 SSH/代理密码均未以明文出现；APK 带有临时测试 define，不在此扫描范围，收尾卸载且使 fixture 凭据失效 |

## 测试与复现

执行入口和环境启动/清理命令见 [开发手册](../../../docs/dev/README.md#r40-路线编辑设备回归)。核心命令：

```bash
source ../.toolchain/env.sh
bash tool/r40-route-editor.sh
flutter test --no-pub test/connection_route_editor_test.dart test/host_route_editor_test.dart \
  test/proxy_profiles_test.dart test/proxy_profiles_page_test.dart test/route_plan_test.dart \
  test/route_fail_closed_test.dart test/localization_coverage_test.dart --reporter expanded
flutter analyze --no-pub
```

- 七个定向文件 **74 PASS、0 FAIL**，含路线规则、失败不直连、代理存储/并发及中英文案。静态检查无问题；新增 Dart 文件格式、Shell 语法及 `git diff --check` 通过。
- 首次完整设备运行：seed **1 PASS**（PID 4021），cold **1 PASS**（PID 4261）；成功 SSH 查询共 **9 次**（seed 7、cold 2），另含一次预期认证失败及一次删除后拨号前拒绝；两次扫描分别检查 7、10 个私有文件及 Flutter 日志。
- 最终提交 `4a8e1a2` 完整复核：seed **1 PASS**（PID **4561**，约 69 秒）、cold **1 PASS**（PID **4777**，约 18 秒），均不含构建时间；同样 **9 次 SSH 成功**，两项预期拒绝、两次明文扫描通过。两阶段均由 `--no-uninstall` 保留真实 App 数据并经 force-stop 进入另一进程，没有存储 mock。
- 本轮未重跑整个 Flutter 套件；应用实现没有变化，前轮全量 1190/47 的结果不冒充本轮执行。

## 本轮修正与限制

设备测试初稿误选了文本框内部的 Scrollable，改为页面滚动区；主机编辑器是关闭按钮，不能用只识别返回箭头的 `pageBack`，已按实际 UI 操作。最初把带认证配置直接换到无认证入口作为成功用例，被应用正确拒绝，现改为显式故障断言，成功更新使用保留认证的第二入口。未放宽认证或路由规则。

测试脚本核对专用 AVD、使用受限临时 define 文件、以截图请求/回执同步取证、检查两次进程 ID，退出时只清理自己的端口转发和 define，并终止仍存活的本轮测试子进程。含凭据的配置断言只输出布尔结果，避免断言失败时打印整个配置。首次定向命令误写不存在的 `connection_route_test.dart`，已改为正确七个文件后全部通过。磁盘不足前清理了本项目可重建缓存，先停本轮空闲 Gradle daemon 再删 transforms，没有清其他项目。

前期日志与截图在 `../.toolchain/artifacts/r40-simulator-8a5ef13/`（含失败初稿与 attempt4 完整通过记录）；最终提交证据在 `../.toolchain/artifacts/r40-simulator-4a8e1a2/`。不将截图单独当成功证明，以测试断言、SSH 查询和扫描结果共同判定。

## 状态与收尾

用户手册补充取消转换后的复用方法及重启后保留路线；开发手册补充完整复现、受测边界与清理命令。R40 / UX06 仅追加局部证据，状态不提升。测试 App 已卸载，专用模拟器已关闭；本轮五个容器、两张测试网络、`.run` 临时凭据及 define 已删除，端口转发已撤销。已停本轮空闲 Gradle daemon，清理含测试 define 的可重建 APK/Flutter build 缓存及 transforms；保留历史证据、SDK/AVD 和原生构建缓存。用户的 `emulator-5554` 及七个其他项目容器保持运行，未停止 OrbStack。


最终目录有六张截图：`chain-three.png`、`proxy-manager.png`、`catalog-chain.png`、`delete-impact.png`、`missing-proxy.png`、`english-manager.png`，已检查链节点操作、删除影响列表、错误提示和英文页面显示。`seed.log` / `cold.log` / `run.log` 为设备断言与进程记录，`seed-secrets.txt` / `cold-secrets.txt` 为明文扫描摘要；定向、分析与 fixture 自检日志也归集到最终目录，`manifest.json` 记录文件大小与 SHA256。

后续：首跳代理显式选择、嵌套展开及再次设备回归见 [R40-choices](R40-choices.md)；本文保留当时的范围与状态。
