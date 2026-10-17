# shun 本机手册

Netcatty-mobile 的实验 fork，叫 shun（分支 `shun/v3`，remote `origin` = `uxiew/shun`，所有者说推之前不 push）。这里只讲在这台 Mac 上怎么跑、怎么测、怎么装、怎么清理。
App 怎么用看 [使用手册](../user/README.md)；做什么、做到哪看 `plan/v3/STATUS.md`。命令都在仓库根目录执行。

## 1. mise 固定 Zig，再 source 环境

`mise.toml` 只为本项目固定 Zig 0.16.0。全局 Homebrew 的 Zig 0.17.0 保留，其他项目不受影响；不要修改 Ghostty 版本检查来兼容 0.17。Flutter 使用 3.47.7 / Dart 3.13.5，当前主锁文件只更新了新 Flutter 必需的 5 项依赖。

```bash
# 下载前可按本机配置执行 proxy；首次执行 mise install 只安装本项目缺少的工具。
mise install zig@0.16.0
export SHUN_ZIG_EXECUTABLE="$(mise which zig)"
# FLUTTER_SDK、ANDROID_HOME、JAVA_HOME 先按本机真实位置设置，见迁移说明。
source ../.toolchain/env.sh
# source 会把旧包装器放在最前；新 Flutter hooks 不传自定义变量，须用真实二进制路径。
export PATH="$(dirname "$SHUN_ZIG_EXECUTABLE"):$PATH"
flutter --version               # 3.47.7 / Dart 3.13.5
zig version                     # 0.16.0
```

以上只影响当前终端；不用 `mise use --global`，也不用卸载 Homebrew 的 Zig。仓库外 `../.toolchain/env.sh` 与旧 Zig 包装器未修改。若 native 下载报 HTTP 400，本机已复现为 Zig 与当前代理的组合问题：仅对构建命令移除六个代理变量再试，保留 localhost 的 NO_PROXY，不改 App 的 RoutePlan：

```bash
env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  flutter test --no-pub -j 1 test/remote_entry_migration_test.dart --reporter expanded
```

不做的后果：`flutter test` 全部在 loading 阶段报 `HttpException: Connection closed before full header was received`
（shell 设了 `http_proxy` 没设 `no_proxy`）；`emulator -list-avds` 看不到本项目的 AVD（它们在 `../.toolchain/avd`）。

## 2. 测试

R39 首批：`HostProfile.protocol` 用 `unknown` 表示明确但不支持的协议，只有缺省/null 继续按旧 SSH 处理；原始 JSON 不改。RoutePlan 在拨号前拒绝未知目标/跳板，列表和 `UnsupportedConnectionPage` 不把未知字段当 SSH 配置解析。`ConnectionEndpointFields` 负责地址/用户名/端口显示与校验，草稿、凭据、路由仍由 HostEditor 及现有 RoutePlan 管理；Telnet 不索要未使用的 SSH 用户名。SSH/Mosh 保存时保留 Mosh 端口范围，仅在 Mosh 表单校验和运行时使用。定向回归见 `test/host_route_editor_test.dart`、`test/vault_model_test.dart`、`test/route_fail_closed_test.dart`。

R39 独立远控：`domain/remote_entry.dart` 定义仅本机的条目元数据；`infrastructure/storage/remote_entry_store.dart` 负责一次性迁移和加密快照的写入/读回验证；两个 provider 的 typed store、controller 仍分别管理自己的秘密和调用。存储文件/钥匙串 namespace 不变，新增 `rustdesk.entries.v2` / `uuremote.entries.v2`，每个快照同时保存条目、绑定及 UU pending。v1 键仅保留作恢复副本；只要 v2 存在，读取损坏也不回退旧数据，避免复活已删除条目/已消费回调。恢复旧副本不是自动回滚，需先确认当前数据和待回调已失效，不能直接降级 App 复用旧 pending。

旧 owner ID 在各 provider namespace 内继续作为本地条目 ID，源 SSH ID 和目录引用另存为显式关联元数据；新建条目不关联任何 SSH 主机。`deviceLinksOf` 接收迁移后的条目元数据，不按名称/IP 合并，SSH 删除后仍能保留原有跨 provider 关联。迁入条目保留旧路由提示，发起时复核仍在的源主机路线；外部远控永不继承 SSH 路由。`ConnectionTypeScreen` 只选择类型/探测可用性，不连接、不授权；新建 SSH/Mosh 共用表单并可互换；编辑旧条目仍保留原协议转换入口，用于修复带残留路线的旧插件配置。首页远控列表和条目编辑操作已拆成共用 widgets，旧主机详情入口不再保留。

新增定向入口：`test/remote_entry_migration_test.dart`（完整迁移、读写中断、冷启动待回调、删除和设备关联），`test/connection_type_screen_test.dart`（类型入口/无 SSH 字段/客户端状态），并回归原 RustDesk、UU、HostEditor 和路由测试。设备脚本的环境、安全检查与四阶段流程见 [R39 Android 验收](r39-device-acceptance.md)。**本轮执行结果只看 `plan/v3/evidence/R39.md`，测试文件存在不代表已通过。**

R41 主机编辑页（分区、高级折叠、底部操作栏）的定向入口是 `test/host_editor_r41_test.dart`；Mosh 覆盖项和测试连接的只读 tmux 查询在 `test/mosh_fixture_test.dart` 的 R41 两组（要先 `tool/mosh-fixture/up.sh`，含 Debian 那台 moshalt）。键盘弹出时真实触摸点保存、真实返回键要确认，在模拟器上用 `SHUN_R39_AVD=shun-r39-a30 python3 tool/r41-device.py` 跑（用法、拦截哪些设备见脚本开头）。结果只看 `plan/v3/evidence/R41.md`。

R40 的 `lib/presentation/widgets/connection_route_editor.dart` 是共用链式编辑器，接收页面已有 `RoutePlan`，通过 `describeRoute` 显示已验证的节点；无有效计划时只显示草稿和错误。`connection_route_draft.dart` 管理选择及兼容字段，保留未修正的失效引用和旧内联配置；不读仓库、不执行网络请求。两页负责预览和提交，只有 `resolveRoutePlan` 决定路线规则。`domain/jump_route_choices.dart` 是 RoutePlan 库的一部分，集中做有界展开、首跳代理候选及确认复核；`jump_route_choice_dialog.dart` 只展示方案并返回明确选择。确认前、来源变化后和后续跳板自带代理时均拒绝执行。

R40 确认信息保存在原 `hostChain` 的 `shunRouteConfirmation` 扩展中：只有版本、顺序、来源的非秘密路线信息和入口选择，没有密码或私钥。`hostIds`、`proxyProfileId` / `proxyConfig` 仍是完整平面路线，不迁移或修改其他主机；缺失/损坏/失效确认一律拒绝。旧客户端的确认语义未实测，不以 JSON 字段兼容冒充跨端执行兼容。

代理 UI 分为 `proxy_profiles_page.dart`（列表、选择、删除确认）和 `proxy_profile_editor.dart`（表单、旧内联配置另存）。`domain/proxy_profiles.dart` 校验配置和确认范围；`VaultController.saveProxyProfile/deleteProxyProfile` 复用主机写入队列并复核旧配置、删除引用，调用现有仓库加密保存。未知桌面字段保留，删除不改主机引用；钥匙串/同步原有的直接 `replace` 路径并未因本轮改成统一事务队列。定向入口：

```bash
flutter test --no-pub test/connection_route_editor_test.dart test/host_route_editor_test.dart test/proxy_profiles_test.dart test/proxy_profiles_page_test.dart test/route_plan_test.dart test/route_fail_closed_test.dart test/localization_coverage_test.dart
```

两页对照测试覆盖直连、代理、1–3 跳和组合路线；管理测试覆盖引用更新/删除、过期确认拒绝、凭据与未知字段保留、内联转换及窄屏键盘布局。真实 SSH 路由回归仍用下文的隔离主环境，未启动的环境测试不计通过。

```bash
flutter test -j 4     # 全量约 1130 条（R20 时三套测试环境都开着：1130 过、2 跳过——1 条只在 Windows 跑、1 条是默认不跑的耗时基准），约 3 分钟；没起测试环境时真实 SSH 的用例自动跳过。刚关模拟器、内存紧时不加 -j 4 可能被系统杀掉
flutter analyze       # 应为 No issues found（连 spikes/、packages/ 一起查）
```

R55 的 AI CLI 检测有两组本机测试。普通单元/widget 测试随全量执行；真实 SSH 路由测试连接同一套 Docker 主环境，须与会重启 sshd、统计连接数的 `integration_ssh_fixture_test.dart` 分开跑。全量命令用 `flutter test -j 4 --exclude-tags ai-cli-ssh-fixture`；主环境启动后单独执行 `flutter test test/ai_cli_ssh_fixture_test.dart`。这组验证 Direct、SOCKS、Jump、组合路线、拒绝未知指纹与错误代理口令、活动终端零探测输入；若同时启动 `tool/ai-cli-fixture`，还会只读检查本机隔离容器中真实安装的 Claude Code/Codex 文件和相邻 package.json，不登录或运行工具。检测范围、操作入口和版本含义见[使用手册](../user/README.md#20-发现启动与继续-ai-命令行工具)。

AI CLI 的身份规则在 `lib/domain/ai_cli_identity.dart` / `host_identity.dart`，首页、启动与返回共用，存储模块只负责读写。`lib/infrastructure/ssh/ai_cli_launch_handshake.dart` 负责启动确认的分包、长度限制与失败状态；`ssh_service.dart` 负责连接、15 秒期限、取消和释放资源。调整协议时先跑 `test/ai_cli_launch_handshake_test.dart` 和 `test/ai_cli_identity_test.dart`，再跑原有启动/存储/返回测试。身份序列化影响已保存入口，不能随重构修改；普通 SSH 原始字节流和 tmux 协议保持各自处理。

启动 fixture 前先确认 Docker daemon 已运行（本机为 OrbStack），再运行各环境的 `up.sh`；先前环境未启动而跳过的测试不能算复验通过。`up.sh` 构建时报 `failed to fetch anonymous token: Get "https://auth.docker.io/token?...": ... i/o timeout`，是 Docker 直连 Docker Hub 连不上：先 `python3 tool/docker-pull-via-proxy.py <Dockerfile 里 FROM 的镜像>` 经本机代理把基础镜像拉下来（不改 OrbStack 全局设置，用法和校验见脚本开头），再重跑 `up.sh`。2026-10-16 本机拉 `alpine:3.22` + `debian:trixie-slim` 用了约 11 分钟。模拟器要有足够空闲磁盘；清理本项目 Gradle transforms 缓存前，确认没有正在进行的构建并停止空闲 daemon，避免它保留已删除 JAR 的引用。历史测试日志/截图不作为构建缓存删除，其他项目的容器与 AVD 不清理。

R56/R57 无账号故障矩阵复跑（先启动主 SSH 环境和 `tool/tmux-fixture/up.sh`，不要与全量测试同时运行）：

```bash
flutter test --no-pub test/ai_cli_launch_ssh_fixture_test.dart
flutter test --no-pub test/ai_cli_tmux_ssh_fixture_test.dart
flutter test --no-pub test/ai_cli_fault_matrix_test.dart
```

Android 用专用 `shun-a35-4k`（仅 `emulator-5580`），启动方式见下文；执行 `bash tool/r56-ai-cli.sh`。脚本会清空该模拟器上的本项目测试数据、安装测试包、转发 22314、授权通知，运行真实界面/SSH/加密存储；后台按 HOME、息屏再唤醒。第一阶段完成断言后，在 SSH 仍连接时强制结束 App，因此 seed 日志的 `did not complete` 是有意中断；只有出现 `KILL_READY`、确认进程消失且第二进程 cold 全部通过，整轮才算成功。使用 `--no-uninstall` 保留两阶段之间的数据，不要拆成默认卸载的两次测试。日志和截图在 `../.toolchain/artifacts/r56-<基线提交>/`。凭据租期仅测试时缩短到 2 秒，不等于生产 10 分钟长时验收；不改 PIN、输入法或 Wi-Fi，不使用真实 AI 账号。测完卸载本项目包、移除 22314 reverse、关闭专用模拟器，两套 fixture 各用自己的 `down.sh` 关闭。结果范围见[故障矩阵证据](../../plan/v3/evidence/R56-R57-fault-matrix.md)。

真实 SSH/SOCKS/跳板的集成测试要先起 Docker 测试环境：

```bash
(cd tool/fixture-environment && ./up.sh && ./selfcheck.sh)   # selfcheck 8 项全 PASS
flutter test test/integration_ssh_fixture_test.dart
(cd tool/fixture-environment && ./down.sh)                   # 用完关掉，删除临时凭据
```

- 只用 `down.sh` 收尾，**别 `orb stop`**：OrbStack 里还跑着你别的项目。
- 测试环境的镜像里有 vim、less、htop、tmux（终端引擎的全屏程序用例要用），改了 `Dockerfile` 后 `up.sh` 会重新构建。
- 第一次跑测试会用 Zig 编 Ghostty 的原生库，多一分钟左右；`zig version` 不是 0.16 就会编译失败，见第 1 节。
- Ghostty 在设备上的验证（R17，`integration_test/ghostty_engine_test.dart`）：起好上面的测试环境，再
  `adb -s <设备> reverse tcp:22201 tcp:22201`，然后
  `flutter test integration_test/ghostty_engine_test.dart -d <设备> --dart-define=R17_SSH="$(python3 tool/fixture-environment/r17_config.py)"`。
  每次 `up.sh` 都换密码，参数要重新取。
- 测试环境细节见 `tool/fixture-environment/README.md`，终端引擎验证工程见 `spikes/terminal_spike/README.md`。
- 键盘和输入法的设备测试（R18，前三份只在模拟器上跑，第四份要真人在真机上，都要上面的测试环境）：
  - 横竖屏 + 真软键盘下终端不被挡、远端尺寸对（`integration_test/r18_keyboard_test.dart`）：跑法同上一条（`adb reverse` + `R17_SSH`），
    另开一个终端先预授权通知，不然一连上就弹「允许通知」挡住键盘：
    `until adb -s emulator-5580 shell pm grant top.xdwa.shun android.permission.POST_NOTIFICATIONS 2>/dev/null; do sleep 0.3; done`
  - 输入法回放（`integration_test/r18_ime_replay_test.dart`）：先 `(cd plugins && ./build-fixtures.sh)`，再 `tool/ime-replay.sh emulator-5580`。
    脚本装回放输入法、临时设成默认、预授权通知、跑完换回原输入法并卸载，见 `plugins/README.md`「R18 回放输入法」。
  - 硬件键和快捷键栏修饰键（`integration_test/r18_keys_test.dart`）：要模拟器有硬件键盘设备。关掉模拟器，把
    `../.toolchain/avd/shun-a35-4k.avd/config.ini` 的 `hw.keyboard = no` 改成 `yes`，重新起，再
    `tool/ime-replay.sh emulator-5580 "" integration_test/r18_keys_test.dart`；**测完改回 `no` 再重起**，
    不然软键盘默认不弹，别的设备测试会等不到键盘。
  - 真人在真机上用自己的输入法打拼音、说话（`integration_test/r18_voice_device_test.dart`，TER02）：要所有者当次同意、本人拿着手机。
    `tool/r18-real-device.sh xdwmbp /opt/homebrew/share/android-commandlinetools/platform-tools/adb 47131FDAP0040E`，
    约 4 分钟（构建安装 1 分多钟，6 项每项半分钟）。手机上出现「点一下这里叫出键盘」后照屏幕说明做，每项按一次回车。
    脚本不碰手机的输入法设置，开始结束各记一次默认输入法；测完 App 被卸掉。
- 粘贴、滑动、选字、链接、远端效果的设备测试（R19，`integration_test/r19_terminal_test.dart`，只在模拟器上跑过）：跑法同 R17 那条
  （测试环境 + `adb reverse` + `R17_SSH`），另开终端预授权通知（同下面 R18 那条）。
  `--plain-name "Ghostty：TER07"` 只跑一项。四项全跑约 1.5 分钟（不算构建）。会往模拟器剪贴板里写测试文字；打开链接换成了假的，不开浏览器。
  用到测试环境镜像里的 bash 和 tmux（R19 起镜像带 bash，改 Dockerfile 后 `up.sh` 自己重建）。
  真 bash 上的粘贴行为（bracketed paste 开关、断线不补发）在本机就能测：`test/integration_ssh_fixture_test.dart` 的「R19 粘贴到真 bash」。
- 终端输入面板的设备测试（R25，`integration_test/r25_input_panel_test.dart`，只在模拟器上跑过）：要上面的测试环境和回放输入法，经脚本跑
  `tool/ime-replay.sh emulator-5580 "" integration_test/r25_input_panel_test.dart`（脚本负责装回放输入法、转发 22201、预授权通知、跑完复原）。
  约 2 分钟（不算构建）。按键面板的键、回放输入法打进大输入框的字（微信语音、拼音）、发到真 bash 的效果都在远端逐字节核对；
  面板切换时远端收到几次窗口变化，用前台一个只数 SIGWINCH 的 bash 记到 `/tmp/r25-winch` 里，另开 exec 通道读。会把屏幕转成横屏再转回来。
  经 Mosh 的那一段在 `integration_test/mosh_session_test.dart` 的 `panel` 场景（跑法见下面 Mosh 那条，`X09_SCENARIO=panel`）。
- R20 终端门禁（模拟器和真机都跑过）：
  - 同素材两引擎对比（本机，不要 Docker）：`flutter test test/terminal_vt_corpus_test.dart`，约 3 秒；素材怎么重录见 `tool/vt-corpus/README.md`。
  - 设备上的门禁：`tool/r20-gate.sh emulator-5580 tui|resources|ai-cli`（脚本转发端口、预授权通知、截图到 `../.toolchain/artifacts/r20-shots-<提交>/`）。
    `tui` 约 1 分钟：App 里用 Ghostty 跑 vim/less/htop/tmux，远端同时起一个同尺寸的后台 tmux 跑同一个脚本、按同样的键，逐行比屏幕；
    `resources`：4 个标签吃输出、开关 500 次，量 RSS/PSS/fd/线程和回显延迟（真机上 23 分钟）；
    `ai-cli` 要先 `(cd tool/ai-cli-fixture && ./up.sh)`（第一次要下 npm 包，几分钟），用完 `./down.sh`。
  - 关掉的标签有没有被拿着（查泄漏用）：`tool/r20-gate.sh emulator-5580 leak`，开关 10 次后强制 GC，还活着的会话打出从 GC 根到它的引用链
    （R20 就是这样查到文件页拿着关掉的会话）。脚本先试 `adb root`，能 root（模拟器）就读 App 的 `/proc/<pid>/net/tcp` 数连 SSH 的连接；
    root 不了（真机 user 版）就改在电脑侧数连 `127.0.0.1:22201` 的连接，这时别让别的东西同时连这个测试环境。
  - 发布包冒烟（REL03）：`tool/build-release.sh` 之后 `tool/release-smoke.sh emulator-5580`，脚本装包、用 uiautomator 点「设置 → 终端引擎 → 检查」，
    界面上是「正常，这次运行建过的终端：1」才算这个包的原生库在这台设备上能用；测完卸掉。Android 7.0 没有 `getconf`，页大小那项写「读不到」。
    真机上它不用 monkey 启动、每次点之前查前台是本 App 且没锁屏，手机上已装着同名 App 就不跑（卸掉会清所有者的数据）。
  - 引擎起不来（TER12）：`tool/r20-engine-failure.sh emulator-5580`，脚本编测试 APK、删掉里面的 libghostty.so、重新签名、用 `flutter drive` 装这个包跑，
    跑完卸掉。会先卸掉模拟器上的 App（签名不同装不上），里面的测试数据随之清掉。
  - 在真机上跑这几条：先 `tool/remote-device/up.sh`（见那里的 README）、`source /tmp/shun-remote-device/env`，把上面的 `emulator-5580` 换成手机序列号。
    要所有者当次同意、本人解锁手机；一串跑下来一个多小时，手机 30 分钟会熄屏，熄了测试就失败，所以 G3 复核时临时开了 `adb shell svc power stayon ac`，测完 `svc power stayon false` 改回。
    用完 `down.sh` 后，`android/local.properties` 的 `sdk.dir` 还指着已删的假 SDK，怎么改回见 `tool/remote-device/README.md`「撞墙时」。
- 连接生命周期（R22，`integration_test/r22_lifecycle_test.dart`，**只在模拟器上跑**）：起好上面的测试环境，`tool/r22-lifecycle.sh emulator-5580 <场景>`。
  脚本 adb root、转发 22201/21080、预授权通知，再按测试打出的 `R22 ACTION=…` 去按 HOME、点通知、开关 Wi-Fi、锁屏、停代理容器，做完用 `run-as` 在 App 私有目录放个文件告诉测试。
  | 场景 | 测什么 | 时长 |
  |---|---|---|
  | `notify` / `svcstop` | 通知上「全部断开」/ `am stopservice` 停服务，再切网：不复活、不登录；回前台有状态条 | 各约 1.5 分钟 |
  | `network` | 一个标签走 adb、一个走模拟器网络（10.0.2.2，只有蜂窝通），Wi-Fi 开关 20 次（10 次短、10 次长） | 约 16 分钟 |
  | `lock` | 后台锁屏（临时设 PIN 1234）时服务器断开：不登录；解锁回 App 才恢复 | 约 2 分钟 |
  | `saver` | 后台、息屏时打开省电模式 60 秒：连接不被掐、App 不乱断乱连 | 约 2 分钟 |
  | `proxy` | 经 SOCKS 到 target：代理容器停了再起、target 重启 | 约 3 分钟 |
  | `activity` | 首页返回键、「不保留活动」、从最近任务划掉：会话对象和 SSH 连接不变 | 约 2 分钟 |
  | `engine` | 只建/销毁 Ghostty 终端各 400 次（挂视图、不挂视图），每 100 次抓 meminfo | 约 5 分钟 |
  | `restore` | 进程被「停止」、强行停止后放回标签：先 `flutter drive` 跑 seed，再装正式 debug 包用 uiautomator 点「重新连接」 | 约 5 分钟 |

  日志、截图、meminfo 在 `../.toolchain/artifacts/r22-<提交>/`。脚本会改模拟器设置（Wi-Fi、锁屏 PIN、「不保留活动」），正常结束会复原；
  中途停掉的话手动复原：`adb shell 'settings put global always_finish_activities 0; locksettings clear --old 1234; svc wifi enable'`。会改手机设置，**别在真机上跑**。
  撞过的墙：截图全黑——测试在等脚本回执时不出帧（集成测试只在 `pump` 时画），要看画面用测试请求的 `shot-…` 截图；
  uiautomator 找不到「全部断开」——通知在「静音」区折叠着，要先点它右边的展开箭头（脚本已处理）；
  脚本悄悄退出、测试卡在等回执——别给这类脚本开 `pipefail`，`adb … | grep -m1` 会让 adb 收到 SIGPIPE。
- 连接长测（LIFE07，同一个测试文件的 `soak` 场景，**真机**，要所有者当次同意、本人在场）：接好 `tool/remote-device/`，
  `tool/r22-soak.sh 47131FDAP0040E default 30`（不加省电豁免），`… exempt 30`（临时加，结束减掉）。一轮约 65 分钟。
  前台 30 分钟（脚本临时开「插电不灭屏」）；然后所有者按 `OWNER:` 提示**先拔 USB 线、再按电源键**锁屏，30 分钟后插回线、解锁回到 App。
  三条标签：一条走 USB（adb reverse 22201，拔线就断，解锁后该自己恢复），两条走手机 Wi-Fi 到接手机那台电脑上的临时转发
  （`tool/remote-device/tcp-relay.py`，只放行手机的 IP，脚本退出就关），其中一条远端每 5 分钟打一行 `tick-N`。
  每个检查点在 App 说「连着」的标签上真跑一条命令（`NOREPLY` 就是嘴上连着）；「连上次数 ≤ 1 + 断开次数」才算没重复登录。
  日志：电脑这头 `soak-<模式>-<时间>.log`，手机里那份 `…-device.log`，摘要 `…-summary.txt`。撞过的墙：
  - 插着 USB 线手机 CPU 不睡（锁屏 187 秒、睡了 0 秒），锁屏测出来的「没断」不算数，所以要拔线。拔了线 flutter 就连不上手机：
    脚本拔线前 `kill -9` 掉它（不然它可能按测试失败收尾、插回线时去卸 App），测试把同样的日志写到 App 私有目录 `files/r22/log.txt`，插回后读。
  - 插着电按电源键进的是屏保（`mWakefulness=Dreaming`，手机开了「充电时显示屏保」），拔了线屏保也可能不退、手机照样醒着，所以先拔线再锁屏。
  - 测试 App 被锁屏或屏保盖住时出不了帧，`tester.pump` 会一直等：`soak` 只在 App 在最前时 pump，开跑前手机要解锁（脚本会提示）。
    **别图省事改成 `framePolicy = fullyLive`**：flutter_test 的 live binding 在那种模式下画完一帧立刻排下一帧，debug 包 120 帧/秒一直重画、占满一个核，
    第一轮正式跑到 25 分钟时一条命令 10 秒才回，Native Heap 涨到 78 MB（模拟器上换成普通 `Text` 一直出帧也一样涨，见 evidence/R22.md）。
  - 解锁后测试包黑屏几十秒：测试包只在 pump 时出帧，要等脚本确认 App 回到最前、测试画一帧才有画面。不是 App 的问题，正式包不这样。
  - 测试主机要先存进保险库再打开：后台满 10 分钟会清掉标签里的凭据副本，恢复时回保险库重取；不在保险库里的临时主机恢复不了，会停在「这台主机已经从保险库里删掉了」。
  - 解锁时手机 USB 重新握手，adb 断 2–3 秒、反向转发跟着没了：脚本重建转发、给测试回话失败会重试。
  - 手机开着 Google VPN，发往本机所在 192.168.2.x 的流量进了隧道、连不到，所以 Wi-Fi 那条路走接手机的那台电脑（和手机同网段）。
- tmux 的测试（R21，`test/tmux_fixture_test.dart`）用另一套环境：四个真实 tmux 版本（2.4、2.7、3.0a、3.5a）加「没有 tmux」「假 tmux」两台，
  `(cd tool/tmux-fixture && ./up.sh)` 起、`./down.sh` 关，和上面那套互不影响、可以同时开；没起时整组跳过。细节见 `tool/tmux-fixture/README.md`。
- Tailscale SSH 的测试（`test/tailscale_ssh_login_test.dart`）要 Go：会自己构建、起停仿制服务器，没装 Go 时整组跳过。仿制服务器和「Headscale + 真 tailscaled」环境的用法见 `tool/tailscale-ssh-fixture/README.md`。
- 目录设备经四条路线连接的设备测试（R15，`integration_test/catalog_route_matrix_test.dart`）只在模拟器/真机上跑：`./up.sh routes` 后用同目录的 `route-matrix.sh`，见上面那份 README 的「R15」一节。
- Mosh（X08、X09）有自己独立的测试环境 `tool/mosh-fixture`（compose 项目 `shun-mosh`，SSH 22301、UDP 60101–60108，
  另有一台没装 mosh 的 22302），和上面那套互不影响。Mosh 插件 APK 怎么编见 `plugins/mosh/README.md`。
  - 桌面上（不要模拟器）：`(cd tool/mosh-fixture && ./up.sh)` 后 `flutter test test/mosh_fixture_test.dart`，13 条，约 10 秒。
    真实 OpenSSH + mosh-server 上的引导、指纹、密码错、缺 mosh-server、五种路线拒绝，计数来自测试环境的记账（`counts.sh`）。没起环境时整组跳过。
  - 模拟器上（X09，用户点「连接」的那条路 + 真插件）：先**关掉模拟器的 Wi-Fi**（原因见第 3 节「别用 10.0.2.2 连 TCP」那段），装插件，再跑：
    ```bash
    adb -s emulator-5580 shell svc wifi disable
    adb -s emulator-5580 install -r plugins/mosh/build/outputs/apk/release/mosh-release.apk
    flutter test integration_test/mosh_session_test.dart -d emulator-5580 \
      --dart-define=X09_MOSH="$(python3 tool/mosh-fixture/x08_config.py)" --dart-define=X09_SCENARIO=all
    adb -s emulator-5580 shell svc wifi enable      # 测完开回来
    ```
    `all` 约 45 秒（不算构建）；另有 `cycles`、`kill`（打出 `X09 kill.READY` 后在电脑上强杀插件）、`ime`（经 `tool/ime-replay.sh`，
    额外参数放 `IME_REPLAY_DEFINES`，写法见脚本开头）。
    多行的报告（阶段、屏幕）只有第一行带 `X09 ` 前缀，grep 时带上 `-A`。
  - **Mosh 插件换签名（包括以后换正式签名、删了 `plugin-keys` 重新生成）必须同步改宿主的 `lib/domain/plugins/official_plugins.dart`**：
    宿主只认那里登记的证书，别的证书签的包自称 `shun.mosh` 一律「已拒绝」、不给批准，真 Mosh 插件也一样被拒。
    新证书从安装包读：`$ANDROID_HOME/build-tools/36.0.0/apksigner verify --print-certs plugins/mosh/build/outputs/apk/release/mosh-release.apk`。
  - 插件已有会话时进出连接测试、会话测试不断开它（X12，`integration_test/x12_plugin_reuse_test.dart`）：同上关 Wi-Fi、装 Mosh 插件，
    另装 `plugins/out/echo-author.apk`，`--dart-define=X09_MOSH=…` 照上面取，约 25 秒（不算构建）。测试不 pkill、只看前后差值，
    别人开着的 mosh-server 不受影响。报告行以 `X12 ` 开头。

### R40 路线编辑设备回归

`integration_test/r40_route_editor_test.dart` 在真实手机尺寸、系统键盘和加密保险库上测试两页共用链、三跳排序/移除、代理管理及旧内联代理转换；核对本地 OpenSSH 每跳指纹，并在目标执行 `hostname`。第二次启动使用另一 App 进程，重读代理引用、跳板顺序与密码，再验证删除代理后拒绝连接。还覆盖递归三跳展开、首跳沿用代理/明确直连、取消、循环拒绝、确认跨进程保留和来源变化后零拨号。目录批量导入用合成目录，不请求真实 Tailscale，也不拨目录里的地址。

```bash
source ../.toolchain/env.sh
# 先确认没有其他本项目测试占用此环境；up.sh 会更换测试凭据。
bash tool/fixture-environment/up.sh
bash tool/fixture-environment/selfcheck.sh
emulator -avd shun-a35-4k -port 5580 -no-window -no-snapshot -gpu host &
adb -s emulator-5580 wait-for-device
adb -s emulator-5580 shell getprop sys.boot_completed  # 等到 1
bash tool/r40-route-editor.sh
# 完成后清理本轮环境（其他项目/容器保持运行）：
adb -s emulator-5580 uninstall top.xdwa.shun
adb -s emulator-5580 emu kill
bash tool/fixture-environment/down.sh
```

脚本先用 `flutter build apk` 构建一次，再由 `flutter drive --keep-app-running` 运行两阶段，阶段间 force-stop 保留真实数据。仅复用本轮相同源码和 fixture 凭据构建的 APK 时，可设 `R40_APK` 跳过构建；不能复用 `flutter test` 生成的协议引导 APK。

脚本只接受 `emulator-5580` 上的 `shun-a35-4k`，**会清空该模拟器的 shun 测试数据**。使用临时 define 文件传入 fixture 凭据，不把密码拼进命令或证据；截图、两阶段日志和明文凭据扫描摘要默认在 `../.toolchain/artifacts/r40-simulator-<提交>/`，可用 `R40_OUT` 指定新目录。21082 是 21080 认证 SOCKS 的第二个 adb 入口；首跳显式直连走 22201。脚本结束会撤销本轮端口转发、删除 define 文件；App 保留供检查，由以上命令卸载。真实设备/iOS 不在这条脚本范围内。

## 3. 模拟器

现在只留一台 `shun-a35-4k`（Android 15，4 KiB 页，自带 Gboard），用的是你原有的 API 35 镜像。

```bash
flutter emulators --launch shun-a35-4k    # 带窗口启动；首次启动会重建空系统
flutter run -d emulator-5554                # 设备 ID 以 flutter devices 为准
adb -s emulator-5554 logcat -s flutter      # 看 Dart 日志
adb -s emulator-5554 emu kill               # 关机
```

在模拟器里连本机的测试环境：先 `adb reverse tcp:22201 tcp:22201`（SOCKS 再加 21080、21081），App 里地址填 `127.0.0.1`。
别用 `10.0.2.2` 连 TCP：模拟器的默认网络是虚拟 Wi-Fi，经它连 `10.0.2.2` 的 TCP 能建上但收不到数据（Mac 上一个普通的 Python HTTP 服务也一样，
不是 OrbStack 的问题，X09 查实），App 会报「对方在登录前断开」，看着像配置错。UDP 经 `10.0.2.2` 是通的。
**Mosh 例外**：UDP 必须发往 SSH 实际连上的那个 IP，SSH 走 adb reverse 就成了 127.0.0.1，UDP 会发到模拟器自己身上。
这时 `adb shell svc wifi disable` 关掉 Wi-Fi，默认网络换成模拟器的蜂窝那张网卡，经 `10.0.2.2` 的 TCP 就正常了；测完 `svc wifi enable`。

**别在模拟器或本机上直连 `100.x`。** 这台 Mac 自己在真实 tailnet 上（`utun4`，`100.64/10` 走它），模拟器发出的连接也是 Mac 发的，
直连 100.x 等于往你的真实 tailnet 里拨号（R13 曾这样连过 `100.64.0.10`，那里恰好没有设备）。测试用的 tailnet 只经 SOCKS 或跳板去连，见 `tool/tailscale-ssh-fixture/README.md`。

其他版本测完已删（省磁盘）。要复测某个版本，按需重建、用完再删：

```bash
V="system-images;android-24;google_apis;arm64-v8a"      # 换成要测的版本，见下表
S=$ANDROID_HOME/cmdline-tools/latest/bin
$S/sdkmanager --install "$V"
echo no | $S/avdmanager create avd -n shun-tmp -k "$V" -d pixel_7
# 启动前在 ../.toolchain/avd/shun-tmp.avd/config.ini 里设 hw.audioInput=no（不让模拟器用 Mac 麦克风）
emulator -avd shun-tmp -no-window -no-snapshot -gpu host &
# 用完：
adb emu kill; $S/avdmanager delete avd -n shun-tmp; $S/sdkmanager --uninstall "$V"
```

| 用途 | 镜像 |
|---|---|
| 最低版本 Android 7.0–8.1 | `android-24`～`android-27`，tag `google_apis` |
| libghostty 构建目标以下 | `android-28;google_apis` |
| 16 KiB 页（新手机，native 库没对齐会加载失败） | `android-36;google_apis_ps16k` |

每台测出了什么见 `plan/v3/evidence/R04.md`。模拟器结果只算部分证据，不能代替真机。

## 4. 装到真机

手机开 USB 调试 → `adb devices` 显示 `device` 后，二选一：

```bash
flutter run -d <设备ID>                    # 调试着用，改代码能热重载
tool/build-release.sh && adb install -r build/app/outputs/flutter-apk/app-release.apk   # 只装不调试；没配正式签名时用 debug 证书签
```

- 发布用的包一律走 `tool/build-release.sh`，别直接 `flutter build apk --release`：直接打会沿用缓存里的终端原生库，
  缓存被改了也照样打进包（实测翻一个字节，构建照常成功）。脚本先丢掉缓存、从核对过 SHA256 的源码重编，
  再查每个 `.so` 都是 16 KiB 对齐。要联网，比平时慢一两分钟。
- 包里只有 arm64-v8a：只有它在设备上测过，别的 ABI 在 `android/app/build.gradle.kts` 里排除了。

- 包名 `top.xdwa.shun`，和原版 Netcatty（`app.netcatty.mobile`）并存、数据互不影响。**别把 applicationId 改成上游的值**，会覆盖原版。
  2026-10-11 前包名是 `top.xdwa.xwshun`：手机上还装着它的，新包会装成另一个 App，数据怎么搬见 [使用手册第 1 节](../user/README.md#1-安装与搬数据)。
- 包用 `~/.android/debug.keystore` 签名；换台电脑构建的包签名不同，`adb install` 报 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`，要先卸载（会清掉 App 数据）才能装。
- AI、云同步、检查更新默认关闭且不显示，开关在 `lib/application/fork_features.dart`。

手机接在另一台电脑上（现在的真机 Pixel 9 Pro 只接在 xdwmbp 上）：用 `tool/remote-device/`，见那里的 README。

装好之后怎么用，看 [使用手册](../user/README.md)。测试插件怎么构建、插件会话怎么在设备上验证，看 `plugins/README.md`。

## 5. 改任务状态

```bash
P=../.toolchain/pyenv/bin/python
$P plan/v3/scripts/set_status.py case <用例ID> <PASS|FAIL|...> --evidence evidence/<任务ID>.md
$P plan/v3/scripts/sync_docs.py       # 同步到 docs/08、09；别手改那两张表
$P plan/v3/scripts/validate_plan.py   # 只查计划本身，不测 App
```

## 6. 磁盘与清理

这台 Mac 常年只剩 5–15 GB。能删的（都在 `../.toolchain/`，删了可重建）：

| 目标 | 大小 | 删了会怎样 |
|---|---|---|
| `gradle-home/caches/9.1.0/transforms` | 1–3.5 GB | 下次构建在本机重建（spike release 17 秒→45 秒），构建一次又长回来。先 `(cd android && ./gradlew --stop)` |
| `gradle-home/` 整个 | 2.5–6 GB | 下次构建要联网重新下依赖 |
| `avd/<名字>.avd/*.img`、`*.qcow2` | 1–3 GB/台 | 关机后删；下次启动是空系统，装过的 App、Gboard 拼音设置都没了 |
| `avd/<名字>.avd/snapshots/` | 约 2.5 GB/台 | 快速启动的快照。我们都用 `-no-snapshot` 冷启动，删了没影响，装过的 App 和设置都在 |
| `baseline-495f5d31/` | 0.1 GB | 原版代码的 worktree，2026-09-29 已删。要重新构建原版时：`git worktree add ../.toolchain/baseline-495f5d31 495f5d3`，再 `chmod +x android/gradlew`（上游仓库里它没有可执行位，不加会报 Permission denied）。删用 `git worktree remove --force`，直接 rm 会留下失效记录 |
| `artifacts/` | 0.25 GB | 原版 debug APK（sha256 `339f4932…`，测原版共存、插件页「看不到这个包」诊断要用）；Tailscale 官方 OpenAPI 原件 `tailscale-openapi-b416d98e.yaml`（244 KB，删了就没法离线核对官方规范变没变，见 `plan/v3/docs/05`）；UU 远程的官方接入文档和官方 4.42.0 APK（`uuremote-*`，27 MB，App 里固定的官方证书就是从这个 APK 读的，删了没法复核，见 `plan/v3/docs/17`）；RustDesk 1.4.9 的清单、链接处理源码和 GitHub 发行版 APK（`rustdesk-*`，27 MB，固定的发行证书从这个 APK 读，同上） |
| `zig-cache/` | 0.1 GB 起 | Zig 编 Ghostty 的缓存，每多编一个平台涨一些。删了下次编要重新下 Zig 依赖 |
| `plugin-keys/` | 12 KB | 测试插件的两把签名密钥（`fixture-author`、`fixture-impostor`）和 X12 样例的作者密钥（`example-author`）。删了下次 `plugins/build-fixtures.sh` 会生成新的，设备上已批准的测试插件随之变「已拒绝（换签）」，在插件页撤销旧批准重新核对即可。**Mosh 插件也用 `fixture-author` 签，宿主把 `shun.mosh` 绑在这张证书上**（`lib/domain/plugins/official_plugins.dart`）：删了它、Mosh 插件换了证书，宿主就当它是冒充者直接拒，得同步改那个文件 |
| `mosh-build/` | 0.25–0.65 GB | X08 Mosh 运行时的源码包（60 MB，带 SHA256 核对）、交叉编译目录、装好的静态库（`prefix-arm64-v8a/`）和本机 protoc/tic（`host/`）。`build/` 下的编译目录随时可删（约 0.4 GB），只要 `prefix-*`、`host/` 在，`plugins/mosh/native/build-mosh-client.sh` 只重编 mosh 本身；整个删了要联网重下源码、从零编约 2 分钟 |
| 整个 `.toolchain/` | — | 回到安装前，只剩下面 SDK 里的东西 |

仓库里能删的（都在 `.gitignore` 里）：`build/`（约 1 GB）、`.dart_tool/flutter_build`（2–3 GB），下次构建重新生成；
`.dart_tool/hooks_runner`（约 0.5 GB）是终端原生库的构建缓存，删了下次构建要用 Zig 重编，多一两分钟。

- `flutter_build` 越跑越大：每次 `--dart-define` 的值不同（比如 `up.sh` 换了测试密码后再跑集成测试）就多一个约 120 MB 的子目录，
  10-06 攒到 24 个共 2.8 GB。只留最新的一个、其余删掉就行，正在构建时别删。
- 新开 worktree 时用 `cp -cR <主仓库>/.dart_tool/hooks_runner <worktree>/.dart_tool/` 带过去：`-c` 是 APFS 克隆，不占额外空间，也省得再用 Zig 重编。
- 空闲空间掉得比文件长得快时，看一眼 `sysctl vm.swapusage`：系统 swap 和数据盘共用同一块空间（10-06 用到 5.5 GB），
  模拟器、Gradle、Flutter 同时开着内存一紧，磁盘就跟着掉。

共享 Android SDK 里为本项目装的：

```bash
S=$ANDROID_HOME/cmdline-tools/latest/bin     # sdkmanager 不在 env.sh 的 PATH 里，直接敲会 command not found
$S/sdkmanager --uninstall "ndk;28.2.13676358" "platforms;android-36" "build-tools;36.0.0" \
  "platforms;android-34" "cmake;3.22.1"      # 后两个是首次构建时 Gradle 自动装的
```

API 35 镜像是你原有的，`lizhi` 模拟器在用，**不要卸**。

迁移前机器在 2026-10-04 用 brew 安装过 `zig@0.16`、`llvm@21`、`lld@21`，这不是当前机器的安装清单。当前（2026-10-14）项目 Zig 0.16.0 由 mise 管理；Homebrew 的 Zig 0.17.0 / LLVM 22 / LLD 22 保留作全局工具。不要照旧清单卸载软件；删除 mise 中的版本前先核对其他项目是否也依赖它，移除项目 `mise.toml` 不会自动卸载全局工具。

## 7. 撞墙时

- **`git push` 报 `Repository not found`**：`uxiew/shun` 在 GitHub 上还没建（或还没从 `uxiew/xwshun` 改名过去），或者这把 SSH 钥匙没有写权限。推送等所有者说，见 `docs/decisions/base-decision.md`。
- **zsh 里把命令存进变量再执行，报 `command not found: adb -s ...`**：zsh 不按空格拆变量，改用 `bash -c '...'` 或函数。`export ANDROID_SERIAL=emulator-5580` 后 adb 默认就打到那台，最省事。
- **`adb shell input text` 打字，分号后面的东西在模拟器上被当成命令执行了**：参数是交给模拟器的 shell 解释的，`;`、`$` 都会生效。整段用单引号包起来再传（`adb shell input text "'echo%s\$HOME'"`，`%s` 是空格），或者一次只打一条不带分号的命令。
- **新 AVD 起不来，日志 `FATAL | Not enough space to create userdata partition ... need 7372.80 MB`**：
  首次启动要建 6 GB 数据盘，需要空闲 ≥ 7.2 GB（分区的 1.2 倍）；改 `config.ini` 的分区大小没用，会被改回。按第 6 节腾空间。
- **`flutter emulators --launch` 报 `Running multiple emulators with the same AVD`**：这台已在后台无窗口运行，先 `adb -s <ID> emu kill`。
- **`adb devices` 显示 `offline`**：还没启动完，等 `adb shell getprop sys.boot_completed` 输出 `1`（实测 18 秒到 2 分钟）。
- **adb 断开（`waiting for device`）又连上后，`emulator-5554` 可能已经不是本项目的模拟器了**：
  X06 时本项目的模拟器在 Mac 内存只剩几十 MB 时被关掉，同一个端口随即出现的是你自己无窗口启动的 `lizhi`，
  后面几条命令就打到了它上面（一次界面导出、一次点在桌面空白处，已删掉导出文件、确认桌面原样）。
  每次重连后先 `adb -s emulator-5554 emu avd name`，是 `shun-a35-4k` 才继续；两台同时开时内存也更紧。
  `lizhi` 开着的时候，本项目的模拟器用固定的另一个端口起，之后每条 adb 都带 `-s emulator-5580`，就不会串：
  `emulator -avd shun-a35-4k -port 5580 -no-window -no-snapshot -gpu host &`（X06 后半段这样跑的，构建时空闲内存 36%–47%，没再被关）。
- **跑过 `flutter test integration_test/...` 之后再 `adb install build/app/outputs/flutter-apk/app-debug.apk`，App 一打开就「isn't responding」**：
  集成测试会用测试入口重新构建并覆盖同一个 `app-debug.apk`，装的其实是测试包；而且测试跑完会把 App 卸掉（数据清空）。先重新 `flutter build apk --debug --target-platform android-arm64` 再装。
- **用 adb 注入按键（`input keyevent` / `input text`）之后，微信输入法的软键盘不出来了，只剩底部「收起」和「切换输入法」**：
  微信输入法收到注入的键就当接了实体键盘，切进实体键盘模式，重开 App、回桌面都不恢复，换到别的 App 打字也一样。
  在它的中文模式下，注入的字母还会先进拼音组字区：一行最多剩 60 字节，`_` 变成「——」，回车被拿去提交组字，Esc 被它吃掉。
  所以装着中文输入法的真机上，别用 adb 注入按键测终端（`spikes/terminal_spike/tool/adb_key_check.sh` 只适合 Gboard 或没弹键盘时）。
  恢复要用**一条**命令：`adb shell 'am force-stop com.tencent.wetype; ime set com.tencent.wetype/.plugin.hld.WxHldService'`。
  只 force-stop 的话，系统会把默认输入法换成 Gboard（R04 时发生过一次，马上改回了）。改之前后各跑一次
  `settings get secure default_input_method`（还有 `selected_input_method_subtype`、`enabled_input_methods`）对比，确认没变。
- **模拟器里按电脑的 Esc，App 退回上一页**：模拟器键位表把 Esc 映射成了返回键，真机蓝牙键盘不会这样。用终端快捷键栏的 Esc。
  用 sendevent 写扫描码也一样：`qwerty2.kl` 里扫描码 1 是 BACK，没有任何扫描码映射到 ESCAPE，模拟器上测不了硬件 Esc。
- **集成测试里等软键盘超时（「等待软键盘弹出超时」），截图上是「Allow shun to send you notifications?」**：
  每次 `flutter test` 都重装 App，一连上 SSH 就为前台保活服务申请通知权限，系统框挡在 App 前面，键盘出不来。按第 2 节预授权。
- **跑着跑着 `adb reverse` 没了，App 报连不上 127.0.0.1:22201**：`adb root` 会重启 adbd，端口转发跟着清掉。先 root 再 reverse
  （`tool/ime-replay.sh` 就是这个顺序）。
- **别用 `pkill -f flutter_tester` 收拾卡住的测试**：它会把别的 worktree、别的代理正在跑的测试一起杀掉（R18/R21 并行时撞过，
  对方的测试重跑四次都被中途杀掉）。只杀自己那条：`pgrep -f "flutter_tools.snapshot test <你的测试文件>"`。
- **几个代理共用一台模拟器时，锁被占着却没人在用**（10-07 撞了两次：锁占了 1.5 小时，设备上什么都没装）：
  后台等锁的循环自己 `mkdir` 抢到了锁，但等锁的代理没被叫醒，以为还在排队。排队的循环**只盯锁、不替你抢**，锁空了先叫醒代理，
  由代理自己拿锁；看到锁占着，先 `cat ../.toolchain/locks/emulator/owner` 看是谁，再看设备上 `pm list packages` 有没有它的 App，
  都没有动静就去问那个代理，别直接删别人的锁。另外两条：
  - **Gradle daemon 是共用的**（都在 `../.toolchain/gradle-home`），别人可能正在构建时别 `./gradlew --stop`，会把对方的构建停掉；
    收尾停 daemon 交给最后走的人。
  - 测试环境谁起谁关：`tool/fixture-environment`、`tool/mosh-fixture` 的 `up.sh` 每次都换密码和主机密钥，正在用它的人会全部连不上。
    别人起着的环境只读它的 `.run/` 配置借用，不 up、不 down、不 pkill，用完告诉起它的人。
- **widget 测试在 `tester.pump(时长)` 里卡死、CPU 100%**：flterm 在终端闲 250ms 后排一个「空闲优先级」任务压缩滚动区；
  这时如果还有动画在跑（比如刚点过按钮的水波纹），调度器推迟它、用零延时计时器反复重试，假时钟里一次 pump 不出帧，就成了死循环
  （真机上帧照常出，动画结束就放行，不会卡）。只用 `pump()` 不推进时间的测试碰不上；要推进时间的，在测试里设
  `tester.binding.schedulingStrategy = ({required priority, required scheduler}) => true`（`test/terminal_input_routing_test.dart` 有）。
  查这种卡死：`flutter test --start-paused`，用 vm_service 的 `getStack` 看卡在哪（R18 就是这么找到的）。
- **设备测试里远端逐字节收（`captureRemote`）读回来的字节缺一截、或者夹着不该有的字节**（R19 撞上的两种）：
  一是收之前切到了备用屏（测全屏程序），结果打在备用屏上，备用屏没有滚动区，比屏幕长的开头被挤掉——用 `postlude` 在打结果前切回来；
  二是从屏幕上抄回来的十六进制会混进旧行的残字（R19 时 xterm2 上撞的，同一次收的，exec 通道读文件是干净的）。
  要准确的字节，收完另开 exec 通道读 `/tmp/r18.bin`（`integration_test/r19_terminal_test.dart` 的 `capture`）。
- **两个测试文件都连 `tool/fixture-environment` 时，`-j 4` 全量跑互相搅乱**：`integration_ssh_fixture_test` 会数 ssh-edge 上的连接数、
  读 sshd 日志、pkill 全部会话，别的文件同时开会话就让它随机失败（R19 时 JMP01/JMP02、R10 两条）。连这个环境的测试都放进那一个文件。
- **模拟器里连 `10.0.2.2` 的 SSH 报 `Connection closed before authentication`，测试环境的 sshd 日志里却根本没有这条连接**：
  模拟器的虚拟 Wi-Fi 吃掉了发往 `10.0.2.2` 的 TCP（`toybox nc` 偶尔能收到一行版本号，换成真的 SSH 握手就断）。
  X09 先以为是 OrbStack，在 Mac 上垫了一个 TCP 中继、又起了个 Python HTTP 服务，都一样收不到；`adb shell svc wifi disable` 之后立刻正常。
  刚开机、Wi-Fi 还没接管默认网络的那十几秒里是通的，所以第一次试可能骗过你。见第 3 节。
- **关了 Wi-Fi 反而连不上 `10.0.2.2`，报 `Network is unreachable`（errno 101）**（R25 撞上的）：这次开机模拟器的蜂窝网络没注册上，
  `adb shell dumpsys telephony.registry | grep mDataRegState` 是 `OUT_OF_SERVICE`，关了 Wi-Fi 就一条网都没有。
  `adb emu gsm data home`、开关飞行模式、`svc data enable` 都没用；`emu kill` 后冷启动一次就是 `IN_SERVICE` 了。
  跑 Mosh 测试前先看一眼这一项，别把它当成 App 或测试环境的问题。
- **设备测试里点按键面板的键，结果切到了「文件」页**（R25 撞上的）：键被挡在看得见的范围外（面板太矮、后两行被剪掉），
  `tester.tap` 只给一句警告、照样在那个坐标点下去，点中的是底下的导航栏。R25 的设备测试打开了
  `WidgetController.hitTestWarningShouldBeFatal`，点不中就直接失败；新写设备测试也建议这样。
- **回放输入法的键盘只有 200dp，还盖住了底部导航栏**：终端页只被压掉一百来 dp。照「键盘压掉多少」开按键面板就太矮了，
  所以面板有最低高度（竖屏 256dp、横屏 156dp），见 `lib/presentation/screens/terminal_screen_input.dart`。
- **想数远端收到几次窗口变化，在交互 shell 里 `trap ... WINCH` 数不到**：断线恢复后的新 shell 是测试环境的 busybox sh，
  它的 WINCH trap 不记数（R25 第一次跑全是 0）。在前台跑一个只数 SIGWINCH 的 bash 往文件里记（`r25_input_panel_test.dart` 第 4 段）。
- **页面测试结束时报 `A Timer is still pending`，挂在 `_sendSize` 的 100ms 定时器上**：面板换回系统键盘后要给键盘空 700ms 的位置，
  到点终端变高、再发一次尺寸、再起一个 100ms 的合并定时器。测试里每步之后至少等 1.2 秒（`terminal_input_panel_test.dart` 的 `settle`）。
- **Android 8.1 及更早的模拟器上 `adb logcat -c` 清不掉日志**（8.0 直接报 `failed to clear the 'main' log`）：
  按日志核对结果时别依赖清空，按"操作前已有几行"截取（`spikes/terminal_spike/tool/adb_key_check.sh` 就是这么做的）。

## 8. 仓库里有什么

| 目录 | 内容 |
|---|---|
| `lib/` | App 本体（Flutter + Riverpod + dartssh2）。终端引擎只经 `lib/infrastructure/terminal/` 的适配层接入 |
| `android/` | Android 工程和原生代码：SSH 保活前台服务、画中画、手机目录授权、插件桥、拉起 UU 和 RustDesk 的桥 |
| `packages/plugin_api/` | 插件契约 v1（Dart 端） |
| `plugins/` | 插件的 Android 契约与 SDK（`provider-sdk/`）、插件样例（`example/`）、真实的 Mosh 插件（`mosh/`），加上只用于测试的插件 APK |
| `third_party/` | 自己维护的上游 fork（现在是 libghostty / flterm），说明见 `third_party/README.md` |
| `tool/` | 发布构建脚本（`build-release.sh`）；App 图标的源图和生成脚本（`brand/`，怎么改看 `render_icons.py` 开头）；测试工具：真实 SSH / 代理 / 跳板的 Docker 环境、多版本 tmux 环境（`tmux-fixture/`）、Tailscale 测试环境、假 Tailscale API、远程真机（`remote-device/`） |
| `spikes/` | 终端引擎验证工程（R04，现在用来在 Android 上验 fork），不进 App |
| `plan/v3/` | 计划、任务、用例、每批的实测证据 |
| `docs/` | 只有 shun 自己写的文档，地图在 `docs/README.md`：使用手册和 Mosh 使用指南（`user/`）、本机手册和架构、安全（`dev/`）、插件作者文档（`plugin-authors/`）、决策记录（`decisions/`） |
