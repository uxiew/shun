# R56/R57 模块整理后的真实 SSH 与模拟器回归

日期：2026-10-12。验证基线 `d1ae4a4`，应用代码为 `8bbb460`。所有者明确授权启动本地测试环境、补齐真实 SSH 与模拟器回归。验证的是拆分后的身份和启动确认模块，不使用真实 AI 账号或用户主机。

## 环境与执行

- macOS arm64、仓库独立 Flutter 3.44.4 工具链；启动 OrbStack、本项目 OpenSSH/SOCKS/Jump fixture 与 tmux 2.4、2.7、3.0a、3.5a fixture。采用本次生成的密码/指纹和本机端口。
- Android 专用 `shun-a35-4k` / `emulator-5580` / API 35 / 4 KiB；真实主 App、Ghostty、SSH 与加密存储，远端采用无模型请求的模拟工具。其他模拟器、用户真实 SSH 主机、AI 账号、iOS 和真机均未操作。
- 真实启动回归 `test/ai_cli_launch_ssh_fixture_test.dart`：**7 通过**。Direct 与 SOCKS+Jump、目录/权限/工具变化、特殊字符字面值、不向已有 cat/vim 注入启动文字、失效原生 ID 不降级。普通启动经过新握手模块。
- `test/ai_cli_tmux_ssh_fixture_test.dart`：**5 通过**。四版本真实创建和精确附着、pane 进程替换拒绝。
- `test/ai_cli_fault_matrix_test.dart`：**44 通过**。创建/启动四个边界的断线/取消/超时 12 项；四版本目标身份、死窗格、窗口/窗格变化 28 项；附着握手期间目标变化 4 项。独立连接核查进程计数，无自动重放。
- R55 回归 `test/ai_cli_ssh_fixture_test.dart`：**7 通过、1 跳过**。未启动真实安装包发现容器，该项仍为本轮未执行；不把已有工具文件/帮助参数冒充登录对话结果。
- `flutter analyze --no-pub`：无问题。

## Android 模拟器

`bash tool/r56-ai-cli.sh` 整轮退出 0：

- seed 进程 PID **5249**：真实界面完成缺目录失败不留成功入口、普通 SSH 新开和返回、专属 tmux、断 SSH 后显式返回、后台/息屏/唤醒、凭据租期（仅测试缩短到 2 秒）、伪造标题不改变身份、私有加密存储无明文工作指针、保险库不导出工作指针。远端累计 2 次运行（普通一次、tmux 一次），没有重跑或输入回放。
- 在 `KILL_READY=seed` 后由宿主 force-stop，确认 PID 消失；这是在真实连接存活、测试 teardown 之前杀 App。seed 的 `did not complete` 为有意失去测试通道，不能记作 Flutter 测试通过；前置断言和宿主杀进程检查均通过。
- cold 进程 PID **5582**：**1 通过、0 失败**。没有活动终端或待连接项，只恢复最近入口；点击后返回完整身份匹配的原 tmux，累计运行仍是 2。切换 SSH 用户隔离入口、清除最近记录不杀远端 pane、删除主机隐藏入口均通过。
- `locked-power.txt` 确认 `mWakefulness=Asleep`；通知转储无 `resume=FAKE`、`READY`、输入哨兵。实际设备为 Android **15 / API 35 / 4096 字节页**。
- 测试完成已卸载 `top.xdwa.shun`、移除 22314 reverse、关闭 `emulator-5580`，释放本次专用锁。

## 全量与结论

`flutter test --no-pub -j 4 --exclude-tags ai-cli-ssh-fixture --reporter expanded`：**1200 通过、15 跳过、0 失败**；15 项为未启动的 Mosh fixture 13 项、Windows 专用 1 项、可选耗时基准 1 项。已补齐前轮因 SSH/tmux 环境未开而跳过的 86 项。专项 AI fixture 在全量之外单独执行，避免互相重启服务器或重置 socket。

没有发现需要修改应用代码的回归问题；代码保持 `8bbb460`，本轮仅同步复跑经验、用户手册的验证范围、计划与证据。测试完成后两套 fixture 使用各自 `down.sh` 关闭并删除临时凭据；不关闭 OrbStack 或其他项目容器。

## 环境故障处理

1. 初次启动 Docker 后磁盘再次接近满载，模拟器拒绝启动，Docker socket 随后不可用。清理本项目可重建 Gradle transforms 缓存，重置已卸载测试 App 的专用测试 AVD 数据后重新启动；释放出约 10 GiB。保留源码、SDK、测试证据及用户其他 AVD。专用 AVD 的 `hw.keyboard=no`、`hw.audioInput=no` 保持。
2. 清理缓存后，空闲 Gradle daemon 仍引用已删除的 transform JAR，首次模拟器构建失败，未执行 App 用例。确认该项目只有一个 IDLE daemon、没有在跑的 Gradle 构建后重启 daemon，重新构建。失败日志保留为 `seed-build-cache-failure.log`，不计为测试成功。

证据目录：仓库外 `../.toolchain/artifacts/r56-d1ae4a4/`。无真实原生对话验收，AIC06/AIC09 仍 NOT_RUN，R56/R57 仍 IN_PROGRESS；本轮不提升 G4/R30。前次因环境关闭未执行的记录保留在 [模块整理证据](R56-R57-modularity.md)，本文件补足本候选的运行证据。
